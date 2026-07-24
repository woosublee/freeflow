import Foundation

@main
struct MeetingSummaryUIContractTests {
    static func main() throws {
        let settings = try source("Sources/SettingsView.swift")
        let noteBrowser = try source("Sources/NoteBrowserView.swift")
        let summaryView = try source("Sources/MeetingSummaryView.swift")
        testCardOrder(settings)
        testExistingFeatureSectionBodiesRemainIndependent(settings)
        testTranscriptFirstSummaryPresentation(
            noteBrowser: noteBrowser,
            summaryView: summaryView
        )
        testNoteListRowSummaryBadgeOrder(noteBrowser)
        print("MeetingSummaryUIContractTests passed")
    }

    private static func testNoteListRowSummaryBadgeOrder(_ noteBrowser: String) {
        guard let audioOnlyBadge = noteBrowser.range(
            of: "displayData.status == .audioOnly"
        ), let summaryBadge = noteBrowser.range(
            of: "displayData.hasMeetingSummary"
        ) else {
            preconditionFailure("Missing Note List row badge condition")
        }
        precondition(
            audioOnlyBadge.lowerBound < summaryBadge.lowerBound,
            "Audio only badge must appear before the Summary badge"
        )
    }

    private static func testCardOrder(_ source: String) {
        guard let postProcessingCard = source.range(
            of: "SettingsCard(\"Post-processing\""
        ), let contextCard = source.range(
            of: "SettingsCard(\"Context\""
        ), let meetingSummaryCard = source.range(
            of: "SettingsCard(\"Meeting Summary\""
        ) else {
            preconditionFailure("Missing model Settings card")
        }

        precondition(postProcessingCard.lowerBound < contextCard.lowerBound)
        precondition(contextCard.lowerBound < meetingSummaryCard.lowerBound)
    }

    private static func testExistingFeatureSectionBodiesRemainIndependent(
        _ source: String
    ) {
        let postProcessing = block(
            in: source,
            from: "private var postProcessingFeatureSection: some View",
            to: "\n    private var contextEnabled"
        )
        let context = block(
            in: source,
            from: "private var contextFeatureSection: some View",
            to: "\n    private var meetingSummaryEnabled"
        )

        for statement in [
            "Toggle(\"\", isOn: postProcessingEnabled)",
            "aiProcessingChoicePicker(for: .postProcessing)",
            "postProcessingDetails"
        ] {
            precondition(postProcessing.contains(statement))
        }
        for statement in [
            "Toggle(\"\", isOn: contextEnabled)",
            "aiProcessingChoicePicker(for: .context)",
            "contextDetails"
        ] {
            precondition(context.contains(statement))
        }
        precondition(!postProcessing.contains("meetingSummary"))
        precondition(!context.contains("meetingSummary"))
    }

    private static func testTranscriptFirstSummaryPresentation(
        noteBrowser: String,
        summaryView: String
    ) {
        for expected in [
            "enum NoteContentMode",
            "case transcript",
            "case summary",
            "@State private var selectedContentMode: NoteContentMode = .transcript",
            "Picker(\"Note Content\", selection: $selectedContentMode)",
            ".pickerStyle(.segmented)",
            "selectedContentMode = .transcript",
            "MeetingSummaryView(",
            "generateMeetingSummary(id: item.id)",
            "private var noteHeader: some View",
            "NoteAudioPlayerView(audioURL: storedAudioURL)",
            "@State private var highlightedSourceQuote: String?",
            "highlightedSourceQuote: highlightedSourceQuote",
            "MeetingSummarySourceLocator.range(",
            "scrollRangeToVisible",
            ".accessibilityLabel(\"Note Content\")",
            "? \"Create Summary\"",
            ": \"Regenerate Summary\"",
            "private var showsSummaryTab: Bool {",
            "summaryEnvelope != nil",
            "summaryActionIsDisabled",
            "handleSummaryAction",
            "@State private var showDeleteSummaryConfirmation = false",
            "\"Delete this summary?\"",
            "sourceQuoteIsValid:",
            "consumeMeetingSummaryPendingReveal(id: item.id)",
            ".onChange(of: selectedContentMode) { newValue in",
            "onDelete:"
        ] {
            precondition(noteBrowser.contains(expected), "Missing Note Browser contract: \(expected)")
        }
        precondition(
            !noteBrowser.contains("if showsSummaryTab {\n                toolbarButton"),
            "Summary toolbar action is no longer gated behind showsSummaryTab"
        )
        let generateSummaryBody = block(
            in: noteBrowser,
            from: "private func generateSummary() {",
            to: "\n    private func deleteSummary"
        )
        precondition(
            !generateSummaryBody.contains("revealSummaryIfPending"),
            "generateSummary must not race with onAppear/onChange by directly revealing the tab"
        )
        precondition(
            !generateSummaryBody.contains("selectedContentMode = .summary"),
            "generateSummary must not directly set selectedContentMode"
        )
        let revealSummaryIfPendingBody = block(
            in: noteBrowser,
            from: "private func revealSummaryIfPending() {",
            to: "\n    private func generateSummary"
        )
        precondition(
            revealSummaryIfPendingBody.contains("DispatchQueue.main.async"),
            "revealing the Summary tab defers selection so a freshly appearing segmented control settles first"
        )
        let meetingSummaryJSONOnChangeBody = block(
            in: noteBrowser,
            from: ".onChange(of: item.meetingSummaryJSON) { newValue in",
            to: "\n        .onChange(of: selectedContentMode)"
        )
        precondition(
            meetingSummaryJSONOnChangeBody.contains("newValue == nil"),
            "meetingSummaryJSON onChange must decide from its own newValue, not a stale self.item read"
        )
        precondition(
            !meetingSummaryJSONOnChangeBody.contains("showsSummaryTab"),
            "meetingSummaryJSON onChange must not rely on showsSummaryTab, which reads a potentially stale self.item"
        )

        for expected in [
            "struct MeetingSummaryView: View",
            "Overview",
            "Key Points",
            "Decisions",
            "Action Items",
            "Open Questions",
            "Label(\"View in Transcript\"",
            ".accessibilityLabel(item.task)",
            "sourceQuoteIsValid: (String) -> Bool",
            "onDelete: () -> Void",
            "Label(\"Delete Summary\", systemImage: \"trash\")"
        ] {
            precondition(summaryView.contains(expected), "Missing Summary view contract: \(expected)")
        }
        for unexpected in [
            "Quick review draft",
            "onCreate",
            "onOpenModelSettings",
            "onCopyText",
            "isGenerating",
            "Divider()",
            ".help(\"Copy Section\")",
            ".help(\"Copy Action Item\")"
        ] {
            precondition(
                !summaryView.contains(unexpected),
                "Summary view should no longer contain: \(unexpected)"
            )
        }
    }

    private static func block(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(
                  of: endMarker,
                  range: start.upperBound..<source.endIndex
              ) else {
            preconditionFailure(
                "Expected source block from \(startMarker) to \(endMarker)"
            )
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }
}
