//
// HubBotMessageFormat.swift
// bitchat
//
// Plain-text question/answer format for the offline hub peer (the
// disaster-mesh "Ask" capability; see BLUEPRINT_1.md "Message format").
//
// Kept Foundation-only and side-effect free so it can be compiled and
// unit-tested outside the app target.
//

import Foundation

enum HubBotMessageFormat {
    /// First private reply, sent immediately when a question arrives.
    static let ackText = "Received. Working on an answer."

    /// Sent when the hub responder is unreachable or does not answer within
    /// the configured timeout.
    static let unreachableText = "Hub not reachable. Please retry."

    /// Second private reply when the incoming DM carries no question text
    /// (empty, or only a `loc:` line), so the asker never hangs after the ack.
    static let emptyQuestionText = "No question received. Send your question as plain text, with an optional loc: lat,lon line."

    /// Appended to every hub answer (BLUEPRINT_1.md: the label must reach
    /// people who use stock BitChat too).
    static let disclaimer = "AI answer from an open-weight model on the hub. Not verified emergency advice."

    /// Matches a trailing `loc: lat,lon` line, e.g. `loc: 51.50070,-0.12460`.
    private static let locLinePattern = try! NSRegularExpression(
        pattern: "^loc:\\s*(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?)\\s*$",
        options: [.caseInsensitive]
    )

    /// Splits an incoming private message into the question text and the
    /// optional trailing `loc: lat,lon` line. Returns `loc` as `"lat,lon"`.
    static func splitQuestionAndLoc(_ content: String) -> (question: String, loc: String?) {
        var lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if let last = lines.last {
            let ns = last as NSString
            if let match = locLinePattern.firstMatch(in: last, range: NSRange(location: 0, length: ns.length)) {
                let lat = ns.substring(with: match.range(at: 1))
                let lon = ns.substring(with: match.range(at: 2))
                lines.removeLast()
                let question = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (question, "\(lat),\(lon)")
            }
        }
        return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    /// True when `text` ends with the disclaimer (case-insensitive). The hub
    /// *ends* every answer with it (BLUEPRINT_1.md), so it is matched as a
    /// suffix, not as a substring anywhere in the answer.
    static func hasDisclaimerSuffix(_ text: String) -> Bool {
        guard text.count >= disclaimer.count else { return false }
        return text.suffix(disclaimer.count).compare(disclaimer, options: .caseInsensitive) == .orderedSame
    }

    /// Returns the answer with the disclaimer appended if it is missing.
    /// `maxLength` is always enforced — including when the answer already
    /// carries the disclaimer — by truncating the answer body and keeping the
    /// disclaimer tail, so mesh traffic stays short text only and the label
    /// always survives truncation.
    static func appendDisclaimerIfMissing(_ answer: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = "\n"

        let body: String
        if hasDisclaimerSuffix(trimmed) {
            // Already labeled: strip the label and re-append it below so the
            // cap is enforced uniformly and the tail always survives.
            body = String(trimmed.dropLast(disclaimer.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = trimmed
        }

        guard maxLength > disclaimer.count else {
            // Degenerate cap: keep as much of the label as fits.
            return String(disclaimer.prefix(maxLength))
        }
        let budget = max(0, maxLength - separator.count - disclaimer.count)
        let cappedBody = String(body.prefix(budget))
        if cappedBody.isEmpty {
            return disclaimer
        }
        return cappedBody + separator + disclaimer
    }
}
