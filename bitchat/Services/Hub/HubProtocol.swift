import Foundation

enum HubProtocol {
    static let nickname = "hub"
    static let ackText = "Received. Working on an answer."
    static let answerLabel = "AI answer from an open-weight model on the hub. Not verified emergency advice."
    static let errorText = "The hub could not answer right now. Please try again."
    static let emptyText = "Send a question in plain words, for example: How do I make water safe to drink?"
    static let locationShareDefaultNote = "Shared location"
    static let maxMessageBytes = 255
    static let maxQuestionBytes = 200
    static let maxAnswerBodyBytes = 900
    static let maxAnswerParts = 9
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
    // Python's str.strip/lstrip in the protocol reference use these Unicode whitespace scalars.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }
    private static func trim(_ text: String, leading: Bool = true, trailing: Bool = true) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        if leading {
            while start < end && isWhitespace(scalars[start]) { scalars.formIndex(after: &start) }
        }
        if trailing {
            while start < end {
                let previous = scalars.index(before: end)
                guard isWhitespace(scalars[previous]) else { break }
                end = previous
            }
        }
        return String(scalars[start..<end])
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
    private static func prefix(_ text: String, bytes: Int) -> String {
        var result = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if used + size > bytes { break }
            result.unicodeScalars.append(scalar)
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
        return Question(body: prefix(trim(lines.joined(separator: "\n")), bytes: maxQuestionBytes), location: location)
    }
    static func userContent(_ question: Question) -> String {
        guard let location = question.location else { return question.body }
        return "\(question.body)\n\nThe person's approximate location: \(decimal(location.lat)), \(decimal(location.lon)) (London, UK)."
    }
    private static func truncateBody(_ body: String) -> String {
        guard body.utf8.count > maxAnswerBodyBytes else { return body }
        var cut = prefix(body, bytes: maxAnswerBodyBytes - "…".utf8.count)
        let scalars = cut.unicodeScalars
        let floor = maxAnswerBodyBytes / 2
        if let newline = scalars.lastIndex(of: "\n"), scalars.distance(from: scalars.startIndex, to: newline) >= floor {
            cut = String(scalars[..<newline])
        } else if let space = scalars.lastIndex(of: " "), scalars.distance(from: scalars.startIndex, to: space) >= floor {
            cut = String(scalars[..<space])
        }
        return trim(cut, leading: false) + "…"
    }
    private static func splitAnswer(_ body: String) -> [String] {
        let limit = maxMessageBytes - "(9/9) ".utf8.count
        var chunks: [String] = []
        var current = ""
        for originalLine in body.components(separatedBy: "\n") {
            var line = originalLine
            while line.utf8.count > limit {
                var head = prefix(line, bytes: limit)
                let scalars = head.unicodeScalars
                if let space = scalars.lastIndex(of: " "),
                   scalars.distance(from: scalars.startIndex, to: space) >= scalars.count / 2 {
                    head = String(scalars[..<space])
                }
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(head)
                line = trim(String(line.unicodeScalars.dropFirst(head.unicodeScalars.count)), trailing: false)
            }
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.utf8.count <= limit {
                current = candidate
            } else {
                chunks.append(current)
                current = line
            }
        }
        chunks.append(current)
        chunks = chunks.map { trim($0) }.filter { !$0.isEmpty }
        if chunks.count > maxAnswerParts - 1 {
            chunks = Array(chunks.prefix(maxAnswerParts - 1))
            chunks[chunks.count - 1] = trim(prefix(chunks.last!, bytes: limit - "…".utf8.count), leading: false) + "…"
        }
        return chunks
    }
    static func composeAnswer(_ output: String) -> [String]? {
        let lines = normalize(output).components(separatedBy: "\n").filter { trim($0) != answerLabel }
        let body = trim(lines.joined(separator: "\n"))
        guard !body.isEmpty else { return nil }
        let parts = splitAnswer(truncateBody(body)) + [answerLabel]
        return parts.enumerated().map { "(\($0.offset + 1)/\(parts.count)) \($0.element)" }
    }
}
