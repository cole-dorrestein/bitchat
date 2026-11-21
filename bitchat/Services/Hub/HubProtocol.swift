import Foundation

enum HubProtocol {
    static let nickname = "hub"
    static let ackText = "Received. Working on an answer."
    static let answerLabel = "AI answer from an open-weight model on the hub. Not verified emergency advice."
    static let errorText = "The hub could not answer right now. Please try again."
    static let emptyText = "Send a question in plain words, for example: How do I make water safe to drink?"
    static let locationShareDefaultNote = "Shared location"
    static let maxQuestionUnits = 500
    static let maxAnswerBodyUnits = 900
    static let ackTimeoutMS = 30_000
    static let answerTimeoutMS = 150_000
    static let modelTimeoutMS = 120_000

    static let systemPrompt = """
    Help someone facing an emergency. You have no live information about the current emergency. Use plain words for a stressed reader. Give short numbered steps, with the most urgent action first and at most 8 steps. Use plain text, with no markdown. If life is at risk and the person can reach emergency services, tell them to call 999 or 112.
    """

    struct Location: Equatable {
        let lat: Double
        let lon: Double
    }
    struct Question {
        let body: String
        let location: Location?
        var isEmpty: Bool { body.isEmpty }
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func decimal(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    static func encodeLocation(_ location: Location) -> String {
        "loc: \(decimal(location.lat)),\(decimal(location.lon))"
    }
    static func decodeLocation(_ line: String) -> Location? {
        let text = trim(line)
        let pattern = #"^loc:\s*(-?[0-9]{1,3}(?:\.[0-9]+)?)\s*,\s*(-?[0-9]{1,3}(?:\.[0-9]+)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text),
              let latRange = Range(match.range(at: 1), in: text),
              let lonRange = Range(match.range(at: 2), in: text),
              let lat = Double(text[latRange]), let lon = Double(text[lonRange]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return Location(lat: lat, lon: lon)
    }
    private static func prefix(_ text: String, units: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf16.count
            if used + size > units { break }
            result.append(character)
            used += size
        }
        return result
    }
    static func parseQuestion(_ wire: String) -> Question {
        var lines = normalize(wire).components(separatedBy: "\n")
        while let last = lines.last, trim(last).isEmpty { lines.removeLast() }
        var location: Location?
        if let last = lines.last, let decoded = decodeLocation(last) {
            location = decoded
            lines.removeLast()
        }
        return Question(body: prefix(trim(lines.joined(separator: "\n")), units: maxQuestionUnits), location: location)
    }
    static func userContent(_ question: Question) -> String {
        guard let location = question.location else { return question.body }
        return "\(question.body)\n\nThe person's approximate location: \(decimal(location.lat)), \(decimal(location.lon)) (London, UK)."
    }
    static func composeAnswer(_ output: String) -> String? {
        let lines = normalize(output).components(separatedBy: "\n").filter { trim($0) != answerLabel }
        var body = trim(lines.joined(separator: "\n"))
        guard !body.isEmpty else { return nil }
        if body.utf16.count > maxAnswerBodyUnits {
            body = prefix(body, units: maxAnswerBodyUnits - 1)
            let floor = maxAnswerBodyUnits / 2
            if let newline = body.lastIndex(of: "\n"), body[..<newline].utf16.count >= floor {
                body = String(body[..<newline])
            } else if let space = body.lastIndex(of: " "), body[..<space].utf16.count >= floor {
                body = String(body[..<space])
            }
            body = body.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
        }
        return body + "\n" + answerLabel
    }
}
