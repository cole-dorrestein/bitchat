import BitFoundation
import Foundation

@MainActor
final class HubBitchatBridge {
    private weak var viewModel: ChatViewModel?
    private let enabled: Bool
    private let responder: HubResponder
    private var tails: [String: (UUID, Task<Void, Never>)] = [:]

    init(viewModel: ChatViewModel) {
        let config = HubConfig()
        self.viewModel = viewModel
        self.enabled = config.enabled
        self.responder = HubResponder(
            model: OllamaClient(baseURL: config.ollamaURL, model: config.model),
            send: { [weak viewModel] peerID, text in
                await MainActor.run { viewModel?.sendPrivateMessage(text, to: PeerID(str: peerID)) }
            },
            log: { print($0) }
        )
    }

    func receive(_ message: BitchatMessage) {
        guard enabled, message.isPrivate, message.sender != "system",
              let viewModel, let sender = message.senderPeerID,
              !sender.isEmpty, !sender.isGeoDM, !sender.isGeoChat, !sender.isGroup, !sender.isBridge,
              sender.toShort() != viewModel.myPeerID.toShort(),
              !viewModel.privateConversationCoordinator.isDuplicateMessage(message.id, targetPeerID: sender),
              !message.content.hasPrefix("[FAVORITED]"), !message.content.hasPrefix("[UNFAVORITED]") else { return }
        let peerID = sender.toShort().id
        let previous = tails[peerID]?.1
        let id = UUID()
        let responder = self.responder
        let work = Task { [weak self] in
            await previous?.value
            await responder.handle(text: message.content, from: peerID)
            if self?.tails[peerID]?.0 == id { self?.tails.removeValue(forKey: peerID) }
        }
        tails[peerID] = (id, work)
    }
}
