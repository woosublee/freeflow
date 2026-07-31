import Foundation

struct AppStateHistoryProtectionSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        try expect(
            source.contains("if pipelineHistoryStore.availability == .ready {"),
            "startup work is gated by history availability"
        )
        let startupRange = try source.range(
            from: "var savedHistory: [PipelineHistoryItem] = []",
            to: "let storedInputID = AudioInputDevice.normalized("
        )
        let startup = String(source[startupRange])
        try expectOrdered(
            [
                "if pipelineHistoryStore.availability == .ready {",
                "pipelineHistoryStore.verifyHistoryReadable()",
                "recoverRecordingJournalsBeforeHistoryLoad(",
                "cloudTranscriptionJobStore.reconcile(",
                "sweepOrphanStoredFiles(",
                "} else {\n            print(\"Skipping history startup work because persistent history is unavailable.\")"
            ],
            in: startup,
            label: "ready startup work remains grouped behind availability gate"
        )
        let initialHistoryRead = try startup.range(
            of: "pipelineHistoryStore.verifyHistoryReadable()"
        ).unwrap("history readability probe")
        let journalRecovery = try startup.range(
            of: "recoverRecordingJournalsBeforeHistoryLoad("
        ).unwrap("journal recovery")
        try expect(
            initialHistoryRead.lowerBound < journalRecovery.lowerBound,
            "history readability is verified before startup recovery work"
        )

        try expect(
            !source.contains("@Published private(set) var historyPersistenceWarning")
                && source.contains("var historyPersistenceWarning: QuillUserIssueRecord? {\n        isHistoryUnavailable"),
            "history-unavailable warning stays current after a runtime read failure"
        )

        let persistenceRange = try source.range(
            from: "private func recordPipelineHistoryEntry(",
            to: "private func startRealtimeStreamingIfEnabled()"
        )
        let persistence = String(source[persistenceRange])
        try expect(
            persistence.contains("if existingID == nil, !isJournalAudioFile {"),
            "a failed update preserves assets already owned by an existing history entry"
        )

        let orphanSweepRange = try source.range(
            from: "if referenceTrust.permitsStartupReferenceCleanup {\n                    let sweepReferenceTrust",
            to: "            } else {\n                print(\"Skipping history startup work because persistent history is unavailable.\")"
        )
        let orphanSweep = String(source[orphanSweepRange])
        try expect(
            orphanSweep.contains("let sweepNow = Date()")
                && orphanSweep.contains("now: sweepNow"),
            "delayed orphan cleanup uses the startup reference snapshot time"
        )

        for functionMarker in [
            "func clearPipelineHistory()",
            "func deleteHistoryEntry(id: UUID)",
            "func updateHistoryItemTitle(id: UUID, title: String)",
            "func retryTranscription(item: PipelineHistoryItem)",
            "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            "func startRecordingFromMCP() -> Bool",
            "private func startRecording(triggerMode: RecordingTriggerMode",
            "func setMeetingSummaryActionCompleted(",
            "func deleteMeetingSummary(noteID: UUID)",
            "func updateTranscript(id: UUID, text: String)"
        ] {
            let range = try source.range(of: functionMarker).unwrap(functionMarker)
            let suffix = String(source[range.lowerBound...])
            try expect(
                suffix.prefix(360).contains("requireAvailableHistoryForMutation()"),
                "\(functionMarker) checks protected history before side effects"
            )
        }

        print("AppStateHistoryProtectionSourceTests passed")
    }

    private static func expectOrdered(
        _ markers: [String],
        in source: String,
        label: String
    ) throws {
        var lowerBound = source.startIndex
        for marker in markers {
            guard let range = source.range(of: marker, range: lowerBound..<source.endIndex) else {
                throw TestFailure("\(label): missing or misordered \(marker)")
            }
            lowerBound = range.upperBound
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private extension String {
    func range(from startMarker: String, to endMarker: String) throws -> Range<Index> {
        let start = try range(of: startMarker).unwrap(startMarker)
        let end = try range(of: endMarker, range: start.upperBound..<endIndex).unwrap(endMarker)
        return start.lowerBound..<end.lowerBound
    }
}

private extension Optional where Wrapped == Range<String.Index> {
    func unwrap(_ marker: String) throws -> Range<String.Index> {
        guard let self else { throw TestFailure("Missing \(marker)") }
        return self
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
