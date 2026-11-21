import Foundation

struct HubConfig {
    let enabled: Bool
    let ollamaURL: URL
    let model: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if os(macOS)
        enabled = environment["BITCHAT_HUB"] == "1"
        #else
        enabled = false
        #endif
        ollamaURL = URL(string: environment["BITCHAT_HUB_OLLAMA_URL"] ?? "http://127.0.0.1:11434")
            ?? URL(string: "http://127.0.0.1:11434")!
        model = environment["BITCHAT_HUB_MODEL"] ?? "ministral-3:14b-instruct-2512-q4_K_M"
    }
}
