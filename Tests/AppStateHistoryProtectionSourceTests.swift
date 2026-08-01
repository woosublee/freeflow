import Foundation

struct AppStateHistoryProtectionSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        try expect(
            source.contains("if initialHistoryArchiveSafety == .normal,")
                && source.contains("pipelineHistoryStore.availability == .ready"),
            "startup work is gated by history availability and archive safety"
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
                "if initialHistoryArchiveSafety == .normal,",
                "pipelineHistoryStore.availability == .ready {",
                "recoverRecordingJournalsBeforeHistoryLoad(",
                "cloudTranscriptionJobStore.reconcile(",
                "sweepOrphanStoredFiles(",
                "} else {\n            print(\"Skipping history startup work because persistent history is unavailable.\")"
            ],
            in: startup,
            label: "ready startup work remains grouped behind availability and archive-safety gates"
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
            source.contains("@Published private(set) var isHistoryUnavailable = false")
                && source.contains("private func synchronizeHistoryPersistenceState()")
                && source.contains("let unavailable = pipelineHistoryStore.availability == .unavailable")
                && source.contains("isHistoryUnavailable = unavailable")
                && source.contains("historyArchiveSafety == .unresolvedArchive")
                && source.contains("historyPersistenceWarning = warning"),
            "history transitions publish protection and archived-history UI state"
        )
        try expect(
            source.contains("private func loadPipelineHistory() -> [PipelineHistoryItem]")
                && source.contains("synchronizeHistoryPersistenceState()"),
            "runtime history reads synchronize the published protection state"
        )
        let archivedStartupRange = try source.range(
            from: "} else if initialHistoryArchiveSafety == .unresolvedArchive,",
            to: "        } else {\n            print(\"Skipping history startup work because persistent history is unavailable.\")"
        )
        let archivedStartup = String(source[archivedStartupRange])
        try expect(
            archivedStartup.contains("cloudTranscriptionJobStore.reconcile(")
                && !archivedStartup.contains("recoverRecordingJournalsBeforeHistoryLoad(")
                && !archivedStartup.contains("sweepOrphanStoredFiles("),
            "published archives preserve old-data cleanup safeguards while reconciling new-generation cloud jobs"
        )
        try expect(
            source.contains("func archiveOldHistoryAndStartFresh() -> Bool")
                && source.contains("try pipelineHistoryStore.detachForHistoryArchive()")
                && source.contains("HistoryArchiveTransition(")
                && source.contains("Task.detached(priority: .userInitiated)")
                && source.contains("completeHistoryArchiveTransition(")
                && source.contains("let activeStore = Self.pipelineHistoryStoreAtURLFactory(")
                && source.contains("historyArchiveSafety = HistoryArchiveTransition.inspect("),
            "explicit archive transitions in the background and installs only a verified fresh history store"
        )
        let archiveRange = try source.range(
            from: "func archiveOldHistoryAndStartFresh() -> Bool",
            to: "@MainActor\n    func clearPipelineHistory()"
        )
        let archiveBody = String(source[archiveRange])
        for requiredGuard in [
            "historyArchiveSafety == .normal",
            "pendingAudioImportJobIDs.isEmpty",
            "cloudTranscriptionHistoryCoordinator.hasActiveWork",
            "meetingSummaryGeneratingNoteIDs.isEmpty",
            "pendingRecordingJournalFinalizationCount == 0",
            "pendingRecordingStartCount == 0"
        ] {
            try expect(
                archiveBody.contains(requiredGuard),
                "archive waits for \(requiredGuard) before moving history files"
            )
        }
        try expect(
            source.contains("pendingAudioImportJobIDs.insert(jobID)")
                && source.contains("pendingAudioImportJobIDs.remove(jobID)"),
            "audio import is tracked before its detached audio copy can touch history storage"
        )
        let recordingStartRange = try source.range(
            from: "private func startRecording(triggerMode: RecordingTriggerMode",
            to: "/// Whether the configured recording flow will actually exercise Accessibility."
        )
        let recordingStart = String(source[recordingStartRange])
        try expect(
            source.contains("private var pendingRecordingStartCount = 0")
                && recordingStart.contains("pendingRecordingStartCount += 1")
                && recordingStart.contains("defer { self.pendingRecordingStartCount -= 1 }")
                && recordingStart.components(separatedBy: "requireAvailableHistoryForMutation()").count >= 3
                && recordingStart.contains("beginRecording("),
            "an awaited recording start remains pending and rechecks archive protection before creating writers"
        )
        let microphonePermissionRange = try source.range(
            from: "private func ensureMicrophoneAccess() -> Bool",
            to: "private func applyAudioInterruptionIfNeeded()"
        )
        let microphonePermission = String(source[microphonePermissionRange])
        try expect(
            microphonePermission.contains("pendingRecordingStartCount += 1")
                && microphonePermission.contains("defer { strongSelf.pendingRecordingStartCount -= 1 }")
                && microphonePermission.components(
                    separatedBy: "strongSelf.requireAvailableHistoryForMutation()"
                ).count >= 3
                && microphonePermission.contains("strongSelf.beginRecording("),
            "microphone permission resumption remains pending and rechecks archive protection before creating writers"
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
