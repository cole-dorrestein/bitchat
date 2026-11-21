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

    /// Returns the answer with the disclaimer appended if it is missing,
    /// truncated so the whole message stays within `maxLength` characters
    /// (mesh traffic stays short text only; the disclaimer always survives
    /// the truncation).
    static func appendDisclaimerIfMissing(_ answer: String, maxLength: Int) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: disclaimer, options: .caseInsensitive) != nil {
            return trimmed
        }
        let separator = "\n"
        let budget = max(0, maxLength - separator.count - disclaimer.count)
        return String(trimmed.prefix(budget)) + separator + disclaimer
    }
}
