//
// HubBotMessageFormatTests.swift
// bitchatTests
//
// Unit tests for the offline hub peer's plain-text message format
// (BLUEPRINT_1.md "Message format"): `loc:` line parsing, the disclaimer
// suffix/append rules, and truncation that always keeps the disclaimer tail.
//

import Testing
import Foundation
@testable import bitchat

struct HubBotMessageFormatTests {

    // MARK: Byte-exact protocol strings (BLUEPRINT_1.md)

    @Test
    func protocolStrings_areByteExact() {
        #expect(HubBotMessageFormat.ackText == "Received. Working on an answer.")
        #expect(HubBotMessageFormat.disclaimer == "AI answer from an open-weight model on the hub. Not verified emergency advice.")
        #expect(HubBotMessageFormat.unreachableText == "Hub not reachable. Please retry.")
    }

    // MARK: loc parsing

    @Test
    func splitQuestionAndLoc_parsesTrailingLocLine() {
        let (question, loc) = HubBotMessageFormat.splitQuestionAndLoc(
            "How do I make river water safe to drink?\nloc: 51.50070,-0.12460"
        )
        #expect(question == "How do I make river water safe to drink?")
        #expect(loc == "51.50070,-0.12460")
    }

    @Test
    func splitQuestionAndLoc_multilineQuestionKeepsInnerNewlines() {
        let (question, loc) = HubBotMessageFormat.splitQuestionAndLoc("line one\nline two\nloc: 51.5,-0.12")
        #expect(question == "line one\nline two")
        #expect(loc == "51.5,-0.12")
    }

    @Test
    func splitQuestionAndLoc_locOnlyLeavesEmptyQuestion() {
        let (question, loc) = HubBotMessageFormat.splitQuestionAndLoc("loc: 51.5,-0.12")
        #expect(question.isEmpty)
        #expect(loc == "51.5,-0.12")
    }

    @Test
    func splitQuestionAndLoc_malformedLocStaysInQuestion() {
        let (question, loc) = HubBotMessageFormat.splitQuestionAndLoc("hi there\nloc: not,coords")
        #expect(loc == nil)
        #expect(question == "hi there\nloc: not,coords")
    }

    @Test
    func splitQuestionAndLoc_noLocReturnsTrimmedContent() {
        let (question, loc) = HubBotMessageFormat.splitQuestionAndLoc("  just a question?  \n\n")
        #expect(question == "just a question?")
        #expect(loc == nil)
    }

    @Test
    func splitQuestionAndLoc_isCaseInsensitiveAndToleratesWhitespace() {
        let (question, loc) = HubBotMessageFormat.splitQuestionAndLoc("where am I?\nLOC:  51.5 ,  -0.12 ")
        #expect(question == "where am I?")
        #expect(loc == "51.5,-0.12")
    }

    // MARK: Disclaimer append

    @Test
    func appendDisclaimer_appendsWhenMissing() {
        let result = HubBotMessageFormat.appendDisclaimerIfMissing("Boil it for 1 minute.", maxLength: 1000)
        #expect(result == "Boil it for 1 minute.\n" + HubBotMessageFormat.disclaimer)
    }

    @Test
    func appendDisclaimer_matchesSuffixNotSubstring() {
        // A disclaimer mentioned mid-answer does not count as the label; the
        // hub *ends* every answer with it, so it is appended at the end.
        let answer = "Note: " + HubBotMessageFormat.disclaimer + " Keep boiling."
        let result = HubBotMessageFormat.appendDisclaimerIfMissing(answer, maxLength: 1000)
        #expect(result == answer + "\n" + HubBotMessageFormat.disclaimer)
        #expect(HubBotMessageFormat.hasDisclaimerSuffix(answer) == false)
    }

    @Test
    func appendDisclaimer_alreadyLabeledShortAnswerIsUnchanged() {
        let answer = "Boil it.\n" + HubBotMessageFormat.disclaimer
        #expect(HubBotMessageFormat.hasDisclaimerSuffix(answer))
        #expect(HubBotMessageFormat.appendDisclaimerIfMissing(answer, maxLength: 1000) == answer)
    }

    @Test
    func appendDisclaimer_caseInsensitiveSuffixIsRecognized() {
        let answer = "Boil it.\n" + HubBotMessageFormat.disclaimer.uppercased()
        #expect(HubBotMessageFormat.hasDisclaimerSuffix(answer))
        // The canonical (byte-exact) label is what ends up in the message.
        #expect(HubBotMessageFormat.appendDisclaimerIfMissing(answer, maxLength: 1000).hasSuffix(HubBotMessageFormat.disclaimer))
    }

    // MARK: Truncation with disclaimer survival

    @Test
    func appendDisclaimer_truncatesLongAnswerKeepingDisclaimerTail() {
        let longAnswer = String(repeating: "a", count: 5000)
        let result = HubBotMessageFormat.appendDisclaimerIfMissing(longAnswer, maxLength: 1000)
        #expect(result.count <= 1000)
        #expect(result.hasSuffix(HubBotMessageFormat.disclaimer))
    }

    @Test
    func appendDisclaimer_capAppliesEvenWhenAnswerAlreadyLabeled() {
        // A responder that appends the disclaimer itself must not bypass the
        // short-text mesh cap (review finding: substring match used to return
        // the full untruncated answer).
        let longLabeled = String(repeating: "b", count: 5000) + "\n" + HubBotMessageFormat.disclaimer
        let result = HubBotMessageFormat.appendDisclaimerIfMissing(longLabeled, maxLength: 1000)
        #expect(result.count <= 1000)
        #expect(result.hasSuffix(HubBotMessageFormat.disclaimer))
    }

    @Test
    func appendDisclaimer_degenerateMaxLengthStaysWithinCap() {
        // maxLength below the disclaimer length: no leading separator, result
        // never exceeds maxLength.
        let result = HubBotMessageFormat.appendDisclaimerIfMissing("hello", maxLength: 10)
        #expect(result.count <= 10)
        #expect(result == String(HubBotMessageFormat.disclaimer.prefix(10)))
        #expect(HubBotMessageFormat.appendDisclaimerIfMissing("hello", maxLength: 0) == "")
        #expect(HubBotMessageFormat.appendDisclaimerIfMissing("hello", maxLength: -5) == "")
    }

    @Test
    func appendDisclaimer_emptyAnswerGetsJustTheLabel() {
        let result = HubBotMessageFormat.appendDisclaimerIfMissing("   ", maxLength: 1000)
        #expect(result == HubBotMessageFormat.disclaimer)
    }
}
