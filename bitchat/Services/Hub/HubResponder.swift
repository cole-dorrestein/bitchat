import Foundation

actor HubResponder {
    typealias Sender = (String, String) async -> Void
    private let model: any HubModel
    private let send: Sender
    private let log: (String) -> Void
    private let timeoutMS: Int
    private var tails: [String: (UUID, Task<Void, Never>)] = [:]

    init(model: any HubModel, timeoutMS: Int = HubProtocol.modelTimeoutMS,
         send: @escaping Sender, log: @escaping (String) -> Void) {
        self.model = model
        self.timeoutMS = timeoutMS
        self.send = send
        self.log = log
    }

    func handle(text: String, from peerID: String) async {
        let received = Date()
        let previous = tails[peerID]?.1
        let id = UUID()
        let work = Task {
            await previous?.value
            await process(text: text, from: peerID, received: received)
        }
        tails[peerID] = (id, work)
        await work.value
        if tails[peerID]?.0 == id { tails.removeValue(forKey: peerID) }
    }

    private func process(text: String, from peerID: String, received: Date) async {
        let question = HubProtocol.parseQuestion(text)
        let outcome: String
        if question.isEmpty {
            await send(peerID, HubProtocol.emptyText)
            outcome = "empty"
        } else {
            await send(peerID, HubProtocol.ackText)
            do {
                let model = self.model
                let output = try await withHubTimeout(milliseconds: timeoutMS) {
                    try await model.answer(system: HubProtocol.systemPrompt, user: HubProtocol.userContent(question))
                }
                if let messages = HubProtocol.composeAnswer(output) {
                    for message in messages { await send(peerID, message) }
                    outcome = "answered"
                } else {
                    await send(peerID, HubProtocol.errorText)
                    outcome = "error"
                }
            } catch {
                await send(peerID, HubProtocol.errorText)
                outcome = "error"
            }
        }
        let latency = max(0, Int(Date().timeIntervalSince(received) * 1000))
        let time = ISO8601DateFormatter().string(from: Date())
        log("\(time) sender=\(peerID.prefix(8)) question_bytes=\(question.body.utf8.count) location=\(question.location != nil) outcome=\(outcome) latency_ms=\(latency)")
    }
}
