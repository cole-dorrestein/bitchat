//
// HubBotServiceTests.swift
// bitchatTests
//
// Unit tests for the offline hub peer service: enable flag, the two-message
// protocol (ack + forward with request_id, error reply for empty questions),
// callback correlation on request_id (out-of-order answers with
// OLLAMA_NUM_PARALLEL=4), the answer cap, the question cap, and the
// env-clamping of the timeout.
//
// The responder POST is observed through an injected URLSession with a
// recording URLProtocol, so no real network is touched. The suite is
// serialized because the recorder is process-global.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Recording responder transport

/// Records every request made through the session it is installed on and
/// answers with a configurable HTTP status.
private final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [(url: URL, body: Data?)] = []
    static var statusCode = 200

    static func reset() {
        lock.lock(); recorded = []; statusCode = 200; lock.unlock()
    }

    static func requests() -> [(url: URL, body: Data?)] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    /// The request body. URLSession may hand the protocol a stream instead of
    /// `httpBody`, so read whichever is present.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        stream.close()
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append((request.url ?? URL(string: "http://localhost")!, Self.body(of: request)))
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct HubBotServiceTests {

    // MARK: Helpers

    private func recordingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A hub-enabled service whose responder URL is the recording transport.
    @MainActor
    private func makeHub(environment: [String: String] = [:]) -> HubBotService {
        var env = environment
        env["BITCHAT_HUB_PEER"] = "1"
        env["HUB_RESPONDER_URL"] = "http://127.0.0.1:9/ask"
        env["HUB_CALLBACK_URL"] = "http://127.0.0.1:8091/hub-callback"
        env["HUB_TIMEOUT_SECONDS"] = "30"
        let config = HubBotService.Config(environment: env, infoPlist: [:])
        return HubBotService(config: config, session: recordingSession())
    }

    private func waitForRequests(count: Int, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if RecordingURLProtocol.requests().count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return RecordingURLProtocol.requests().count >= count
    }

    private func postedJSON(_ index: Int = 0) throws -> [String: Any] {
        let body = try #require(RecordingURLProtocol.requests()[safe: index]?.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Enable flag

    @Test @MainActor
    func hubIsDisabledByDefault() {
        let envOnly = HubBotService.Config(environment: [:], infoPlist: [:])
        #expect(!envOnly.enabled)
        #expect(!HubBotService.isHubPeer(environment: [:], infoPlist: [:]))

        let plistOnly = HubBotService.Config(environment: [:], infoPlist: ["BitchatHubPeerEnabled": true])
        #expect(plistOnly.enabled)
        #expect(HubBotService.isHubPeer(environment: [:], infoPlist: ["BitchatHubPeerEnabled": true]))

        let envFlag = HubBotService.Config(environment: ["BITCHAT_HUB_PEER": "1"], infoPlist: [:])
        #expect(envFlag.enabled)
    }

    @Test @MainActor
    func disabledHubIsInert() async {
        RecordingURLProtocol.reset()
        let service = HubBotService(
            config: HubBotService.Config(environment: [:], infoPlist: [:]),
            session: recordingSession()
        )
        let peerID = PeerID(str: "0102030405060708")
        var sent: [(text: String, peer: PeerID)] = []
        service.handleIncomingPrivateMessage(from: peerID, content: "hello?") { text, peer in
            sent.append((text, peer))
        }
        #expect(sent.isEmpty)
        let noPost = await waitForRequests(count: 1, timeout: 0.2)
        #expect(!noPost)
        #expect(RecordingURLProtocol.requests().isEmpty)
    }

    // MARK: Two-message protocol: ack + forward

    @Test @MainActor
    func enabledHubAcksThenForwardsQuestionWithRequestID() async throws {
        RecordingURLProtocol.reset()
        let service = makeHub()
        let peerID = PeerID(str: "0102030405060708")
        var sent: [(text: String, peer: PeerID)] = []
        service.handleIncomingPrivateMessage(
            from: peerID,
            content: "How do I make river water safe?\nloc: 51.50070,-0.12460"
        ) { text, peer in
            sent.append((text, peer))
        }

        // The ack is the synchronous first message, byte-exact per BLUEPRINT_1.md.
        #expect(sent.map(\.text) == [HubBotMessageFormat.ackText])
        #expect(sent.first?.peer == peerID)

        let forwarded = await waitForRequests(count: 1)
        #expect(forwarded)
        let request = RecordingURLProtocol.requests().first!
        #expect(request.url.absoluteString == "http://127.0.0.1:9/ask")
        let json = try postedJSON()
        #expect(json["sender"] as? String == peerID.id)
        #expect(json["question"] as? String == "How do I make river water safe?")
        #expect(json["loc"] as? String == "51.50070,-0.12460")
        #expect(json["callback_url"] as? String == "http://127.0.0.1:8091/hub-callback")
        let requestID = json["request_id"] as? String
        #expect(requestID != nil && !(requestID?.isEmpty ?? true))
    }

    @Test @MainActor
    func responderPayloadIncludesRequestIDAndOptionalLoc() {
        let peerID = PeerID(str: "0102030405060708")
        let withLoc = HubBotService.responderPayload(
            requestID: "req-1",
            sender: peerID,
            question: "q?",
            loc: "51.5,-0.12",
            callbackURL: "http://127.0.0.1:8091/hub-callback"
        )
        #expect(withLoc["request_id"] as? String == "req-1")
        #expect(withLoc["sender"] as? String == peerID.id)
        #expect(withLoc["question"] as? String == "q?")
        #expect(withLoc["loc"] as? String == "51.5,-0.12")
        #expect(withLoc["callback_url"] as? String == "http://127.0.0.1:8091/hub-callback")

        let withoutLoc = HubBotService.responderPayload(
            requestID: "req-2",
            sender: peerID,
            question: "q?",
            loc: nil,
            callbackURL: "http://127.0.0.1:8091/hub-callback"
        )
        #expect(withoutLoc["loc"] == nil)
    }

    @Test @MainActor
    func eachQuestionGetsItsOwnRequestID() async throws {
        RecordingURLProtocol.reset()
        let service = makeHub()
        let peerID = PeerID(str: "0102030405060708")
        var sent: [(text: String, peer: PeerID)] = []
        service.handleIncomingPrivateMessage(from: peerID, content: "Q1") { text, peer in sent.append((text, peer)) }
        service.handleIncomingPrivateMessage(from: peerID, content: "Q2") { text, peer in sent.append((text, peer)) }
        #expect(sent.map(\.text) == [HubBotMessageFormat.ackText, HubBotMessageFormat.ackText])

        let bothForwarded = await waitForRequests(count: 2)
        #expect(bothForwarded)
        let id1 = try postedJSON(0)["request_id"] as? String
        let id2 = try postedJSON(1)["request_id"] as? String
        #expect(id1 != nil && id2 != nil && id1 != id2)
    }

    // MARK: Empty / loc-only question (no silent hang)

    @Test @MainActor
    func emptyOrLocOnlyQuestionGetsAckThenErrorReplyAndNoForward() async {
        RecordingURLProtocol.reset()
        let service = makeHub()
        let peerID = PeerID(str: "0102030405060708")
        var sent: [(text: String, peer: PeerID)] = []
        service.handleIncomingPrivateMessage(from: peerID, content: "loc: 51.5,-0.12") { text, peer in
            sent.append((text, peer))
        }
        // Two-message protocol: ack, then a short error reply — never silence.
        #expect(sent.map(\.text) == [HubBotMessageFormat.ackText, HubBotMessageFormat.emptyQuestionText])
        let noPost = await waitForRequests(count: 1, timeout: 0.2)
        #expect(!noPost)
        #expect(RecordingURLProtocol.requests().isEmpty)
    }

    // MARK: Callback correlation on request_id

    @Test @MainActor
    func outOfOrderAnswersCorrelateOnRequestID() async throws {
        RecordingURLProtocol.reset()
        let service = makeHub()
        let peerID = PeerID(str: "0102030405060708")
        var sent: [(text: String, peer: PeerID)] = []
        service.handleIncomingPrivateMessage(from: peerID, content: "Q1") { text, peer in sent.append((text, peer)) }
        service.handleIncomingPrivateMessage(from: peerID, content: "Q2") { text, peer in sent.append((text, peer)) }
        let bothForwarded = await waitForRequests(count: 2)
        #expect(bothForwarded)
        let id1 = try #require(try postedJSON(0)["request_id"] as? String)
        let id2 = try #require(try postedJSON(1)["request_id"] as? String)
        #expect(id1 != id2)

        // The responder answers Q2 first (OLLAMA_NUM_PARALLEL=4 completes out
        // of order): the answer must go to Q2's asker entry, not Q1's.
        let callback2 = try JSONSerialization.data(withJSONObject: [
            "request_id": id2, "sender": peerID.id, "answer": "answer-two"
        ])
        service.handleCallback(body: callback2)
        #expect(sent.count == 3)
        #expect(sent[2].text.hasPrefix("answer-two"))
        #expect(sent[2].text.hasSuffix(HubBotMessageFormat.disclaimer))

        // A legacy callback without request_id falls back to the oldest
        // in-flight question from that sender — here Q1, still pending.
        let legacy = try JSONSerialization.data(withJSONObject: [
            "sender": peerID.id, "answer": "answer-one"
        ])
        service.handleCallback(body: legacy)
        #expect(sent.count == 4)
        #expect(sent[3].text.hasPrefix("answer-one"))
        #expect(sent[3].text.hasSuffix(HubBotMessageFormat.disclaimer))

        // An unknown request_id is ignored, not mis-delivered.
        let unknown = try JSONSerialization.data(withJSONObject: [
            "request_id": "no-such-request", "sender": peerID.id, "answer": "bogus"
        ])
        service.handleCallback(body: unknown)
        #expect(sent.count == 4)
    }

    // MARK: Caps

    @Test @MainActor
    func answerIsCappedAndKeepsDisclaimerTail() async throws {
        RecordingURLProtocol.reset()
        let service = makeHub()
        let peerID = PeerID(str: "0102030405060708")
        var sent: [(text: String, peer: PeerID)] = []
        service.handleIncomingPrivateMessage(from: peerID, content: "q") { text, peer in sent.append((text, peer)) }
        let forwarded = await waitForRequests(count: 1)
        #expect(forwarded)
        let requestID = try #require(try postedJSON()["request_id"] as? String)

        let hugeAnswer = String(repeating: "x", count: 100_000)
        let callback = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID, "sender": peerID.id, "answer": hugeAnswer
        ])
        service.handleCallback(body: callback)
        let delivered = try #require(sent.last?.text)
        #expect(delivered.count <= service.config.maxAnswerChars)
        #expect(delivered.hasSuffix(HubBotMessageFormat.disclaimer))
    }

    @Test @MainActor
    func inboundQuestionIsCappedBeforeForwarding() async throws {
        RecordingURLProtocol.reset()
        let service = makeHub(environment: ["HUB_MAX_QUESTION_CHARS": "256"])
        let peerID = PeerID(str: "0102030405060708")
        var sent: [(text: String, peer: PeerID)] = []
        service.handleIncomingPrivateMessage(from: peerID, content: String(repeating: "q", count: 10_000)) { text, peer in
            sent.append((text, peer))
        }
        let forwarded = await waitForRequests(count: 1)
        #expect(forwarded)
        let question = try #require(try postedJSON()["question"] as? String)
        #expect(question.count <= 256)
    }

    // MARK: Env clamping

    @Test @MainActor
    func timeoutEnvIsClampedAndNeverTraps() {
        // Negative / NaN / infinite values fall back or clamp instead of
        // reaching `UInt64(timeout * 1e9)`, which traps.
        #expect(HubBotService.Config(environment: ["HUB_TIMEOUT_SECONDS": "-5"], infoPlist: [:]).timeout == 1)
        #expect(HubBotService.Config(environment: ["HUB_TIMEOUT_SECONDS": "nan"], infoPlist: [:]).timeout == 120)
        #expect(HubBotService.Config(environment: ["HUB_TIMEOUT_SECONDS": "inf"], infoPlist: [:]).timeout == 120)
        #expect(HubBotService.Config(environment: ["HUB_TIMEOUT_SECONDS": "999999"], infoPlist: [:]).timeout == 3600)
        #expect(HubBotService.Config(environment: [:], infoPlist: [:]).timeout == 120)
        #expect(HubBotService.Config(environment: ["HUB_TIMEOUT_SECONDS": "45"], infoPlist: [:]).timeout == 45)
    }
}

// MARK: - Small helpers

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
