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
//      JSON {request_id, sender, question, loc?, callback_url?}. Each
//      question gets its own request_id; the responder echoes it in the
//      callback payload so answers correlate to the right question even
//      when several are in flight for one sender (OLLAMA_NUM_PARALLEL=4).
//      The responder acks immediately and later POSTs the final answer back
//      to our local callback endpoint. No question ever goes to a cloud
//      model API; the only network calls in this file are the responder POST
//      and the local callback listener.
//   3. On callback it sends the answer as a second private message to the
//      original sender, appending the AI disclaimer if it is missing and
//      always keeping the message within the mesh short-text cap.
//   4. If the responder is unreachable, the question is empty, or no
//      callback arrives within the configured timeout, it replies with a
//      short second message ("No question received…" / "Hub not reachable.
//      Please retry.") so the asker never hangs after the ack.
//
// How a peer becomes the hub (picked mechanism, documented): the Info.plist
// flag `BitchatHubPeerEnabled` (shipped as `false`; the demo Mac hub build
// sets it to `true`) or, without rebuilding, the environment variable
// `BITCHAT_HUB_PEER=1`. Everything else is env-configurable:
//
//   HUB_RESPONDER_URL     responder endpoint   (default http://127.0.0.1:8090/ask)
//   HUB_CALLBACK_PORT     local callback port  (default 8091)
//   HUB_CALLBACK_URL      full callback URL override, e.g. when the responder
//                         reaches this Mac on another interface
//   HUB_TIMEOUT_SECONDS   answer timeout before "Hub not reachable" (default 120, clamped 1...3600)
//   HUB_MAX_ANSWER_CHARS  max answer length sent over the mesh (default 1000)
//   HUB_MAX_QUESTION_CHARS max question length forwarded to the responder (default 4096)
//
// In hub mode the peer also stays fully offline on the internet side:
// `NetworkActivationService` refuses to start Tor or connect Nostr relays
// while `isHubPeer()` is true.
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
        let maxQuestionChars: Int

        static let defaultResponderURL = URL(string: "http://127.0.0.1:8090/ask")!
        /// Bounds for HUB_TIMEOUT_SECONDS: a negative, NaN or infinite env
        /// value must never reach `UInt64(timeout * 1e9)` (that conversion
        /// traps), so the raw value is clamped here.
        static let minTimeout: TimeInterval = 1
        static let maxTimeout: TimeInterval = 3600
        static let defaultTimeout: TimeInterval = 120

        init(environment: [String: String] = ProcessInfo.processInfo.environment,
             infoPlist: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
            // Hub mode is opt-in: Info.plist flag (set on the hub Mac build)
            // or the BITCHAT_HUB_PEER=1 environment override.
            self.enabled = HubBotService.isHubPeer(environment: environment, infoPlist: infoPlist)
            self.responderURL = environment["HUB_RESPONDER_URL"].flatMap { URL(string: $0) }
                ?? Self.defaultResponderURL
            self.callbackPort = environment["HUB_CALLBACK_PORT"].flatMap { Int($0) }.flatMap { UInt16(exactly: $0) }
                ?? 8091
            self.callbackURLOverride = environment["HUB_CALLBACK_URL"]
            if let raw = environment["HUB_TIMEOUT_SECONDS"].flatMap({ Double($0) }), raw.isFinite {
                self.timeout = min(max(raw, Self.minTimeout), Self.maxTimeout)
            } else {
                self.timeout = Self.defaultTimeout
            }
            self.maxAnswerChars = environment["HUB_MAX_ANSWER_CHARS"].flatMap { Int($0) }.map { max($0, 1) } ?? 1000
            self.maxQuestionChars = environment["HUB_MAX_QUESTION_CHARS"].flatMap { Int($0) }.map { max($0, 1) } ?? 4096
        }
    }

    let config: Config
    /// Responder HTTP session. Injectable so tests can record the POSTs
    /// instead of hitting the network.
    let session: URLSession

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

    init(config: Config = Config(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// True when this peer is configured as the offline hub: the Info.plist
    /// flag `BitchatHubPeerEnabled` (hub build) or `BITCHAT_HUB_PEER=1`.
    /// Also read by `NetworkActivationService` to keep Tor/Nostr off while
    /// the peer is the hub (the hub's no-internet posture).
    nonisolated static func isHubPeer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoPlist: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Bool {
        (infoPlist["BitchatHubPeerEnabled"] as? Bool ?? false) || environment["BITCHAT_HUB_PEER"] == "1"
    }

    // MARK: - Lifecycle

    /// Starts the local callback HTTP listener. No-op unless this peer is
    /// configured as the hub.
    func start() {
        guard config.enabled, listener == nil else { return }
        // Bind the listener to the exact host the callback URL advertises —
        // loopback or the local-link address, never all interfaces — so the
        // callback endpoint is not reachable from other networks.
        let host = callbackHost()
        let port = NWEndpoint.Port(integerLiteral: config.callbackPort)
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: port
            )
            let listener = try NWListener(using: parameters, on: port)
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
            SecureLogger.error("HubBot: could not start callback listener on \(host):\(config.callbackPort): \(error.localizedDescription)", category: .session)
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
        guard !question.isEmpty else {
            // Empty or loc-only DM: still send the second message of the
            // two-message protocol instead of leaving the asker hanging.
            sendPrivate(HubBotMessageFormat.emptyQuestionText, peerID)
            return
        }

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
            // config.timeout is clamped to 1...3600; max(0, …) keeps the
            // UInt64 conversion trap-free even for a NaN/negative value.
            let seconds = max(0, self?.config.timeout ?? Config.defaultTimeout)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            if let question = pending.removeValue(forKey: requestID) {
                SecureLogger.warning("HubBot: no answer for \(requestID.prefix(8))… within \(config.timeout)s, telling sender the hub is not reachable", category: .session)
                question.deliver(HubBotMessageFormat.unreachableText)
            }
        }
        pending[requestID]?.timeoutTask = timeoutTask

        // (b) Forward the question to the hub responder over the local link,
        // capped so an oversized DM cannot push an oversized body at it.
        let cappedQuestion = String(question.prefix(config.maxQuestionChars))
        Task { [weak self] in
            await self?.postToResponder(requestID: requestID, sender: peerID, question: cappedQuestion, loc: loc)
        }
    }

    /// The JSON body POSTed to the responder. `request_id` is unique per
    /// question; the responder echoes it in the callback payload so the
    /// answer correlates to the right question (with OLLAMA_NUM_PARALLEL=4,
    /// two questions from one phone can otherwise complete out of order).
    static func responderPayload(
        requestID: String,
        sender: PeerID,
        question: String,
        loc: String?,
        callbackURL: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "request_id": requestID,
            "sender": sender.id,
            "question": question,
            "callback_url": callbackURL
        ]
        if let loc {
            payload["loc"] = loc
        }
        return payload
    }

    private func postToResponder(requestID: String, sender: PeerID, question: String, loc: String?) async {
        let payload = Self.responderPayload(
            requestID: requestID,
            sender: sender,
            question: question,
            loc: loc,
            callbackURL: callbackURLString()
        )
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: config.responderURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = max(config.timeout, 10)

        do {
            let (_, response) = try await session.data(for: request)
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

    /// The host the callback listener binds to and the advertised URL uses:
    /// the override's host when `HUB_CALLBACK_URL` is set, else this
    /// machine's local-link IPv4, else loopback.
    private func callbackHost() -> String {
        if let override = config.callbackURLOverride,
           let url = URL(string: override),
           let host = url.host {
            return host
        }
        return Self.localIPv4Address() ?? "127.0.0.1"
    }

    /// The URL advertised to the responder. Overridable for setups where the
    /// responder reaches this Mac on a different interface.
    func callbackURLString() -> String {
        if let override = config.callbackURLOverride {
            return override
        }
        return "http://\(callbackHost()):\(config.callbackPort)/hub-callback"
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

    /// Handles one callback POST body. Internal (not private) so tests can
    /// drive the correlation directly.
    @MainActor
    func handleCallback(body: Data) {
        struct CallbackPayload: Decodable {
            let request_id: String?
            let sender: String?
            let answer: String?
            let result: String?
            /// The answer as "(i/n) " parts of at most 255 UTF-8 bytes with the
            /// AI label last (protocol/README.md). BitChat rejects private
            /// message content over 255 bytes (Protocols/Packets.swift:251-265),
            /// so each part goes out as its own private message, in order.
            let messages: [String]?
        }
        guard let payload = try? JSONDecoder().decode(CallbackPayload.self, from: body),
              payload.messages?.isEmpty == false || (payload.answer ?? payload.result) != nil
        else {
            SecureLogger.warning("HubBot: ignoring undecodable callback payload", category: .session)
            return
        }

        // Correlate on request_id when the responder echoes it (preferred; the
        // responder contract in hub/responder.py echoes it). A legacy
        // responder that omits it falls back to the oldest in-flight question
        // from the echoed sender.
        var match: PendingQuestion?
        if let requestID = payload.request_id, !requestID.isEmpty {
            guard let found = pending[requestID] else {
                SecureLogger.warning("HubBot: callback for unknown request_id \(requestID.prefix(8))…", category: .session)
                return
            }
            if let sender = payload.sender, !sender.isEmpty,
               found.senderPeerID.id.lowercased() != sender.lowercased() {
                // request_id is authoritative; sender is a consistency check only.
                SecureLogger.warning("HubBot: request \(requestID.prefix(8))… sender mismatch (\(sender.prefix(8))… vs \(found.senderPeerID.id.prefix(8))…)", category: .session)
            }
            match = found
        } else if let sender = payload.sender?.lowercased(), !sender.isEmpty {
            match = pending.values
                .filter({ $0.senderPeerID.id.lowercased() == sender })
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first
        }
        guard let match else {
            SecureLogger.warning("HubBot: callback with no matching in-flight question", category: .session)
            return
        }

        pending.removeValue(forKey: match.requestID)
        match.timeoutTask?.cancel()

        // (c) The answer parts, one private message each, in order.
        if let messages = payload.messages, !messages.isEmpty {
            SecureLogger.info("HubBot: answer for \(match.requestID.prefix(8))… (\(messages.count) parts)", category: .session)
            messages.forEach { match.deliver($0) }
            return
        }

        // A responder without `messages`: one message, disclaimer appended if
        // missing, kept within the short-text cap.
        let answer = payload.answer ?? payload.result ?? ""
        let text = HubBotMessageFormat.appendDisclaimerIfMissing(answer, maxLength: config.maxAnswerChars)
        SecureLogger.info("HubBot: answer for \(match.requestID.prefix(8))… (\(text.count) chars)", category: .session)
        match.deliver(text)
    }
}

// MARK: - Minimal HTTP/1.1 callback connection

/// One accepted callback connection. All access is serialized on the
/// listener's queue; the parsed body is handed to the main actor.
private final class CallbackConnectionState: @unchecked Sendable {
    /// Largest accepted request head (headers) and body, in bytes.
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 64 * 1024

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxBodyBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                buffer.append(data)
            }
            switch Self.parseRequest(from: buffer) {
            case .body(let body):
                onBody(body)
                respond(status: "200 OK", body: Data("{\"ok\":true}".utf8))
            case .invalid:
                // Rejected before any body is read (bad Content-Length or an
                // oversized head); answer 400 and close.
                respond(status: "400 Bad Request", body: Data("{\"ok\":false}".utf8))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
    }

    private enum ParseResult {
        case incomplete
        case invalid
        case body(Data)
    }

    /// Parses the request head and returns the body once the full HTTP
    /// request (headers + Content-Length bytes of body) has arrived.
    /// `Content-Length` is validated before any body bytes are read: a
    /// missing, negative, non-numeric or oversized value is rejected instead
    /// of underflowing the index math or buffering without bound.
    private static func parseRequest(from data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        let header = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var contentLength: Int?
        for line in header.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        guard let contentLength, contentLength > 0, contentLength <= maxBodyBytes else {
            return .invalid
        }
        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return .incomplete }
        return .body(data[bodyStart..<(data.index(bodyStart, offsetBy: contentLength))])
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
