//
// HubBotService.swift
// bitchat
//
// The offline hub peer for the disaster mesh (BLUEPRINT_1.md "Ask"). When
// this peer is configured as the hub, every private message addressed to it
// is treated as a question:
//
//   1. It immediately replies privately with "Received. Working on an
//      answer." (reusing the normal send-private-message machinery).
//   2. It forwards the question text (plus the optional `loc: lat,lon`
//      line) to the hub responder on the local hub machine over HTTP —
//      POST to HUB_RESPONDER_URL (default http://127.0.0.1:8090/ask) with
//      JSON {sender, question, loc?, callback_url?}. The responder acks
//      immediately and later POSTs the final answer back to our local
//      callback endpoint. No question ever goes to a cloud model API; the
//      only network calls in this file are the responder POST and the
//      local callback listener.
//   3. On callback it sends the answer as a second private message to the
//      original sender, appending the AI disclaimer if it is missing.
//   4. If the responder is unreachable or no callback arrives within the
//      configured timeout, it replies "Hub not reachable. Please retry.".
//
// How a peer becomes the hub (picked mechanism, documented): the Info.plist
// flag `BitchatHubPeerEnabled` (shipped as `false`; the demo Mac hub build
// sets it to `true`) or, without rebuilding, the environment variable
// `BITCHAT_HUB_PEER=1`. Everything else is env-configurable:
//
//   HUB_RESPONDER_URL    responder endpoint   (default http://127.0.0.1:8090/ask)
//   HUB_CALLBACK_PORT    local callback port  (default 8091)
//   HUB_CALLBACK_URL     full callback URL override, e.g. when the responder
//                        reaches this Mac on another interface
//   HUB_TIMEOUT_SECONDS  answer timeout before "Hub not reachable" (default 120)
//   HUB_MAX_ANSWER_CHARS max answer length sent over the mesh (default 1000)
//

import BitFoundation
import BitLogger
import Foundation
import Network

@MainActor
final class HubBotService {

    struct Config {
        let enabled: Bool
        let responderURL: URL
        let callbackPort: UInt16
        let callbackURLOverride: String?
        let timeout: TimeInterval
        let maxAnswerChars: Int

        static let defaultResponderURL = URL(string: "http://127.0.0.1:8090/ask")!

        init(environment: [String: String] = ProcessInfo.processInfo.environment,
             infoPlist: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
            // Hub mode is opt-in: Info.plist flag (set on the hub Mac build)
            // or the BITCHAT_HUB_PEER=1 environment override.
            let plistEnabled = infoPlist["BitchatHubPeerEnabled"] as? Bool ?? false
            self.enabled = plistEnabled || environment["BITCHAT_HUB_PEER"] == "1"
            self.responderURL = environment["HUB_RESPONDER_URL"].flatMap { URL(string: $0) }
                ?? Self.defaultResponderURL
            self.callbackPort = environment["HUB_CALLBACK_PORT"].flatMap { Int($0) }.flatMap { UInt16(exactly: $0) }
                ?? 8091
            self.callbackURLOverride = environment["HUB_CALLBACK_URL"]
            self.timeout = environment["HUB_TIMEOUT_SECONDS"].flatMap { Double($0) } ?? 120
            self.maxAnswerChars = environment["HUB_MAX_ANSWER_CHARS"].flatMap { Int($0) } ?? 1000
        }
    }

    let config: Config

    private struct PendingQuestion {
        let requestID: String
        let senderPeerID: PeerID
        let createdAt: Date
        var timeoutTask: Task<Void, Never>?
        /// Sends one private reply to the original asker over the mesh.
        let deliver: @MainActor (String) -> Void
    }

    /// In-flight questions keyed by request ID. Touched on the main actor only.
    private var pending: [String: PendingQuestion] = [:]
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "bitchat.hubbot.callback")

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// Starts the local callback HTTP listener. No-op unless this peer is
    /// configured as the hub.
    func start() {
        guard config.enabled, listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.callbackPort))
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.serverQueue ?? .global())
                self?.handleCallbackConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    SecureLogger.error("HubBot: callback listener failed: \(error.localizedDescription)", category: .session)
                }
            }
            listener.start(queue: serverQueue)
            self.listener = listener
            SecureLogger.info("HubBot: hub peer active, answering DMs, callback at \(callbackURLString())", category: .session)
        } catch {
            SecureLogger.error("HubBot: could not start callback listener on port \(config.callbackPort): \(error.localizedDescription)", category: .session)
        }
    }

    // MARK: - Inbound mesh questions

    /// Offers a freshly received, non-duplicate private message (addressed to
    /// us) to the hub. `sendPrivate` is BitChat's normal private-message send
    /// path, used for all replies.
    func handleIncomingPrivateMessage(
        from peerID: PeerID,
        content: String,
        sendPrivate: @MainActor @escaping (String, PeerID) -> Void
    ) {
        guard config.enabled else { return }
        guard !peerID.isGroup else { return }

        // (a) Immediate private ack so the asker knows the question arrived.
        sendPrivate(HubBotMessageFormat.ackText, peerID)

        let (question, loc) = HubBotMessageFormat.splitQuestionAndLoc(content)
        guard !question.isEmpty else { return }

        let requestID = UUID().uuidString
        let deliver: @MainActor (String) -> Void = { text in sendPrivate(text, peerID) }
        pending[requestID] = PendingQuestion(
            requestID: requestID,
            senderPeerID: peerID,
            createdAt: Date(),
            deliver: deliver
        )

        // (d) One deadline per question: responder unreachable or no callback
        // within the configured timeout both end in the not-reachable reply.
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.config.timeout ?? 120) * 1_000_000_000))
            guard let self else { return }
            if let question = pending.removeValue(forKey: requestID) {
                SecureLogger.warning("HubBot: no answer for \(requestID.prefix(8))… within \(config.timeout)s, telling sender the hub is not reachable", category: .session)
                question.deliver(HubBotMessageFormat.unreachableText)
            }
        }
        pending[requestID]?.timeoutTask = timeoutTask

        // (b) Forward the question to the hub responder over the local link.
        Task { [weak self] in
            await self?.postToResponder(requestID: requestID, sender: peerID, question: question, loc: loc)
        }
    }

    private func postToResponder(requestID: String, sender: PeerID, question: String, loc: String?) async {
        var payload: [String: Any] = [
            "sender": sender.id,
            "question": question,
            "callback_url": callbackURLString()
        ]
        if let loc {
            payload["loc"] = loc
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: config.responderURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = max(config.timeout, 10)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                SecureLogger.warning("HubBot: responder at \(config.responderURL) did not ack (request \(requestID.prefix(8))…)", category: .session)
                return // the deadline task sends the not-reachable reply
            }
            SecureLogger.info("HubBot: question \(requestID.prefix(8))… forwarded to \(config.responderURL) from \(sender.id.prefix(8))…", category: .session)
        } catch {
            SecureLogger.warning("HubBot: responder unreachable at \(config.responderURL): \(error.localizedDescription)", category: .session)
            // The deadline task sends the not-reachable reply after the timeout.
        }
    }

    // MARK: - Callback endpoint

    /// The URL advertised to the responder. Overridable for setups where the
    /// responder reaches this Mac on a different interface.
    func callbackURLString() -> String {
        if let override = config.callbackURLOverride {
            return override
        }
        let host = Self.localIPv4Address() ?? "127.0.0.1"
        return "http://\(host):\(config.callbackPort)/hub-callback"
    }

    /// First non-loopback IPv4 address (prefers en0) so the responder on the
    /// local link can call us back.
    nonisolated static func localIPv4Address() -> String? {
        var ifaddrs: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrs) == 0, let ifaddrs else { return nil }
        defer { freeifaddrs(ifaddrs) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = ifaddrs
        while let entry = pointer {
            pointer = entry.pointee.ifa_next
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == AF_INET else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            guard ip != "127.0.0.1" else { continue }
            if name == "en0" {
                return ip
            }
            fallback = fallback ?? ip
        }
        return fallback
    }

    nonisolated private func handleCallbackConnection(_ connection: NWConnection) {
        let state = CallbackConnectionState(connection: connection) { [weak self] body in
            Task { @MainActor in
                self?.handleCallback(body: body)
            }
        }
        state.start()
    }

    @MainActor
    private func handleCallback(body: Data) {
        struct CallbackPayload: Decodable {
            let sender: String?
            let answer: String?
            let result: String?
        }
        guard let payload = try? JSONDecoder().decode(CallbackPayload.self, from: body),
              let sender = payload.sender?.lowercased(),
              let answer = payload.answer ?? payload.result
        else {
            SecureLogger.warning("HubBot: ignoring undecodable callback payload", category: .session)
            return
        }

        // The responder echoes `sender` (the asker's peer ID hex). Match the
        // oldest in-flight question from that sender.
        guard let match = pending.values
            .filter({ $0.senderPeerID.id.lowercased() == sender })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first
        else {
            SecureLogger.warning("HubBot: callback for unknown sender \(sender.prefix(8))…", category: .session)
            return
        }

        pending.removeValue(forKey: match.requestID)
        match.timeoutTask?.cancel()

        // (c) Second private message with the answer, disclaimer appended if
        // missing, kept short for the mesh.
        let text = HubBotMessageFormat.appendDisclaimerIfMissing(answer, maxLength: config.maxAnswerChars)
        SecureLogger.info("HubBot: answer for \(match.requestID.prefix(8))… from \(sender.prefix(8))… (\(text.count) chars)", category: .session)
        match.deliver(text)
    }
}

// MARK: - Minimal HTTP/1.1 callback connection

/// One accepted callback connection. All access is serialized on the
/// listener's queue; the parsed body is handed to the main actor.
private final class CallbackConnectionState: @unchecked Sendable {
    private let connection: NWConnection
    private let onBody: @Sendable (Data) -> Void
    private var buffer = Data()

    init(connection: NWConnection, onBody: @escaping @Sendable (Data) -> Void) {
        self.connection = connection
        self.onBody = onBody
    }

    func start() {
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                buffer.append(data)
            }
            if let body = Self.extractBody(from: buffer) {
                onBody(body)
                respond(status: "200 OK", body: Data("{\"ok\":true}".utf8))
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    /// Returns the request body once the full HTTP request (headers +
    /// Content-Length bytes of body) has arrived, else nil.
    private static func extractBody(from data: Data) -> Data? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var contentLength = 0
        for line in header.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        return data[bodyStart..<(data.index(bodyStart, offsetBy: contentLength))]
    }

    private func respond(status: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }
}
