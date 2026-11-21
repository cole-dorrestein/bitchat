import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol HubModel {
    func answer(system: String, user: String) async throws -> String
}

enum HubModelError: Error {
    case timeout
    case httpStatus(Int)
    case invalidResponse
}

// A structured task group waits for cancelled children. A model may ignore
// cancellation, so resolve the deadline independently and cancel the loser.
private final class HubTimeoutRace<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }
    func add(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

func withHubTimeout<Value>(milliseconds: Int, operation: @escaping () async throws -> Value) async throws -> Value {
    let race = HubTimeoutRace<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        race.install(continuation)
        race.add(Task {
            do { race.finish(.success(try await operation())) }
            catch { race.finish(.failure(error)) }
        })
        race.add(Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
                race.finish(.failure(HubModelError.timeout))
            } catch { }
        })
    }
}

struct OllamaClient: HubModel {
    let baseURL: URL
    let model: String
    let timeoutMS: Int

    init(baseURL: URL, model: String, timeoutMS: Int = HubProtocol.modelTimeoutMS) {
        self.baseURL = baseURL
        self.model = model
        self.timeoutMS = timeoutMS
    }

    func answer(system: String, user: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Double(timeoutMS) / 1000
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "keep_alive": -1,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "options": ["num_predict": 400, "temperature": 0.3]
        ])
        return try await withHubTimeout(milliseconds: timeoutMS) {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HubModelError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw HubModelError.httpStatus(http.statusCode) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String else { throw HubModelError.invalidResponse }
            return content
        }
    }
}
