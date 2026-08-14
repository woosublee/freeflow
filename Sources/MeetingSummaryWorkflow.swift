import Foundation

struct MeetingSummaryGeneratorConfiguration: Sendable {
    let backendExecutor: AIProcessingBackendExecutor
    let cloudFallbackModelID: String?
}

struct MeetingSummaryWorkflowDependencies {
    var makeGenerator:
        @MainActor (MeetingSummaryGeneratorConfiguration)
            -> any MeetingSummaryGenerating
    var now: @Sendable () -> Date
}

struct MeetingSummaryWorkflowRequest {
    let noteID: UUID
    let initialItem: PipelineHistoryItem
    let requestedOutputLanguage: String
    let configuredBackendKind: MeetingSummaryBackendKind
    let configuredModelID: String
    let providerHost: String?
    let generatorConfiguration: MeetingSummaryGeneratorConfiguration
}

struct MeetingSummaryHistoryAccess {
    var durability:
        @MainActor @Sendable () -> PipelineHistoryDurability
    var item:
        @MainActor @Sendable (UUID) -> PipelineHistoryItem?
    var persist:
        @MainActor @Sendable (PipelineHistoryItem, Bool) throws -> Void
}

struct MeetingSummaryWorkflowState: Equatable, Sendable {
    var generatingNoteIDs: Set<UUID>
    var pendingRevealNoteIDs: Set<UUID>

    static let initial = MeetingSummaryWorkflowState(
        generatingNoteIDs: [],
        pendingRevealNoteIDs: []
    )
}

enum MeetingSummaryWorkflowEvent {
    case stateChanged(MeetingSummaryWorkflowState)
    case itemPersisted(PipelineHistoryItem)
}

enum MeetingSummaryWorkflowOutcome {
    case verifiedSuccess
    case unverifiedSuccess
    case invalidInput
    case sourceChanged
    case generationFailed(Error)
    case persistenceFailed
}

@MainActor
final class MeetingSummaryWorkflow {
    private let dependencies: MeetingSummaryWorkflowDependencies
    private var generationRevisionByID: [UUID: Int] = [:]
    private(set) var state = MeetingSummaryWorkflowState.initial
    var onEvent: ((MeetingSummaryWorkflowEvent) -> Void)?

    init(dependencies: MeetingSummaryWorkflowDependencies) {
        self.dependencies = dependencies
    }

    func generate(
        request: MeetingSummaryWorkflowRequest,
        history: MeetingSummaryHistoryAccess
    ) async -> MeetingSummaryWorkflowOutcome {
        guard history.durability() == .durable else {
            return .persistenceFailed
        }
        guard let initialItem = history.item(request.noteID) else {
            return .invalidInput
        }
        let initialFingerprint = Self.availabilitySource(
            for: request.initialItem
        ).fingerprint
        guard Self.availabilitySource(for: initialItem).fingerprint
                == initialFingerprint else {
            return .sourceChanged
        }

        let generationRevision = generationRevisionByID[
            request.noteID,
            default: 0
        ]
        state.generatingNoteIDs.insert(request.noteID)
        emitState()

        let transcript = Self.transcript(for: initialItem)
        let resolvedLanguage: (
            context: MeetingSummaryLanguageContext,
            resolvedSpokenLanguage: SpokenLanguageResolution?
        )
        do {
            resolvedLanguage = try Self.resolvedLanguage(
                for: initialItem,
                transcript: transcript,
                requestedOutputLanguage: request.requestedOutputLanguage
            )
        } catch {
            guard isCurrent(
                noteID: request.noteID,
                revision: generationRevision,
                sourceFingerprint: initialFingerprint,
                history: history
            ) else {
                return .sourceChanged
            }
            finishGeneration(
                noteID: request.noteID,
                revision: generationRevision
            )
            return .generationFailed(error)
        }

        var sourceItem = initialItem
        if let spokenLanguage = resolvedLanguage.resolvedSpokenLanguage {
            guard let currentItem = currentItem(
                noteID: request.noteID,
                revision: generationRevision,
                sourceFingerprint: initialFingerprint,
                history: history
            ) else {
                return .sourceChanged
            }
            let updated = currentItem.withSpokenLanguage(spokenLanguage)
            do {
                try history.persist(updated, true)
            } catch {
                finishGeneration(
                    noteID: request.noteID,
                    revision: generationRevision
                )
                return .persistenceFailed
            }
            onEvent?(.itemPersisted(updated))
            sourceItem = updated
        }

        let source = Self.source(
            for: sourceItem,
            languageContext: resolvedLanguage.context
        )
        let generator = dependencies.makeGenerator(
            request.generatorConfiguration
        )
        let result: MeetingSummaryGenerationResult
        do {
            result = try await generator.generate(source: source)
        } catch {
            guard isCurrent(
                noteID: request.noteID,
                revision: generationRevision,
                sourceFingerprint: source.fingerprint,
                history: history
            ) else {
                return .sourceChanged
            }
            finishGeneration(
                noteID: request.noteID,
                revision: generationRevision
            )
            if let summaryError = error as? MeetingSummaryError,
               summaryError == .sourceChanged {
                return .sourceChanged
            }
            return .generationFailed(error)
        }

        guard let currentItem = currentItem(
            noteID: request.noteID,
            revision: generationRevision,
            sourceFingerprint: source.fingerprint,
            history: history
        ) else {
            return .sourceChanged
        }
        let envelope = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: result.promptVersion,
            generatedAt: dependencies.now(),
            sourceFingerprint: source.fingerprint,
            modelID: result.modelID,
            backendKind: result.backendKind,
            languageContext: source.languageContext,
            evidenceVerification: result.evidenceVerification == .unverified
                ? .unverified
                : nil,
            content: result.draft.materialized()
        ).preservingCompletion(from: currentItem.meetingSummary)
        let attempt = MeetingSummaryAttempt(
            occurredAt: dependencies.now(),
            outcome: .succeeded,
            backendKind: result.backendKind,
            modelID: result.modelID,
            providerHost: Self.providerHost(
                backendKind: result.backendKind,
                configuredProviderHost: request.providerHost
            ),
            language: source.languageContext,
            issue: nil,
            sourceFingerprint: source.fingerprint
        )
        let updated = currentItem
            .withMeetingSummary(envelope)
            .withMeetingSummaryAttempt(attempt)
        do {
            try history.persist(updated, true)
        } catch {
            finishGeneration(
                noteID: request.noteID,
                revision: generationRevision
            )
            return .persistenceFailed
        }
        onEvent?(.itemPersisted(updated))
        finishGeneration(
            noteID: request.noteID,
            revision: generationRevision,
            pendingReveal: true
        )
        return result.evidenceVerification == .unverified
            ? .unverifiedSuccess
            : .verifiedSuccess
    }

    func invalidate(noteID: UUID) {
        generationRevisionByID[noteID, default: 0] += 1
        state.generatingNoteIDs.remove(noteID)
        state.pendingRevealNoteIDs.remove(noteID)
        emitState()
    }

    func forget(noteID: UUID) {
        generationRevisionByID.removeValue(forKey: noteID)
        state.generatingNoteIDs.remove(noteID)
        state.pendingRevealNoteIDs.remove(noteID)
        emitState()
    }

    func forgetAll() {
        generationRevisionByID.removeAll()
        state = .initial
        emitState()
    }

    func consumePendingReveal(noteID: UUID) -> Bool {
        let consumed = state.pendingRevealNoteIDs.remove(noteID) != nil
        if consumed { emitState() }
        return consumed
    }

    static func transcript(for item: PipelineHistoryItem) -> String {
        let processed = item.postProcessedTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return processed.isEmpty ? item.rawTranscript : processed
    }

    static func source(
        for item: PipelineHistoryItem,
        languageContext: MeetingSummaryLanguageContext
    ) -> MeetingSummarySource {
        let calendar = item.calendarMatch.map { match in
            MeetingSummaryCalendarContext(
                title: match.title,
                start: match.start,
                end: match.end,
                attendees: match.attendees.compactMap { attendee in
                    let name = attendee.displayName?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? ""
                    if !name.isEmpty { return name }
                    let email = attendee.email?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? ""
                    return email.isEmpty ? nil : email
                }
            )
        }
        return MeetingSummarySource(
            transcript: transcript(for: item),
            calendar: calendar,
            languageContext: languageContext
        )
    }

    static func availabilitySource(
        for item: PipelineHistoryItem
    ) -> MeetingSummarySource {
        source(
            for: item,
            languageContext: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "",
                resolutionSource: .unavailable
            )
        )
    }

    static func resolvedLanguage(
        for item: PipelineHistoryItem,
        transcript: String,
        requestedOutputLanguage: String
    ) throws -> (
        context: MeetingSummaryLanguageContext,
        resolvedSpokenLanguage: SpokenLanguageResolution?
    ) {
        let requested = requestedOutputLanguage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let explicitCode = TranscriptionLanguage.code(
            forSummaryOutput: requested
        ) {
            return (
                MeetingSummaryLanguageContext(
                    requestedOutputLanguage: requested,
                    appliedLanguageCode: explicitCode,
                    resolutionSource: .configured
                ),
                nil
            )
        }
        let existingSpokenLanguage = item.spokenLanguage
        let requiresTranscriptResolution =
            existingSpokenLanguage?.source == .transcriptInferred
                || existingSpokenLanguage?.source == .unavailable
        let spoken = requiresTranscriptResolution
            ? SpokenLanguageResolver.resolve(
                requestedLanguageCode: item.transcriptionLanguageCode,
                engineLanguageCode: nil,
                transcript: transcript
            )
            : existingSpokenLanguage ?? SpokenLanguageResolver.resolve(
                requestedLanguageCode: item.transcriptionLanguageCode,
                engineLanguageCode: nil,
                transcript: transcript
            )
        guard let code = spoken.languageCode else {
            throw QuillUserIssueError.meetingSummaryLanguageUnavailable()
        }
        return (
            MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: code,
                resolutionSource: spoken.source
            ),
            requiresTranscriptResolution || existingSpokenLanguage == nil
                ? spoken
                : nil
        )
    }

    static func providerHost(
        backendKind: MeetingSummaryBackendKind,
        configuredProviderHost: String?
    ) -> String? {
        backendKind == .cloud ? configuredProviderHost : nil
    }

    private func currentItem(
        noteID: UUID,
        revision: Int,
        sourceFingerprint: String,
        history: MeetingSummaryHistoryAccess
    ) -> PipelineHistoryItem? {
        guard generationRevisionByID[noteID, default: 0] == revision,
              let item = history.item(noteID),
              Self.availabilitySource(for: item).fingerprint
                == sourceFingerprint else {
            return nil
        }
        return item
    }

    private func isCurrent(
        noteID: UUID,
        revision: Int,
        sourceFingerprint: String,
        history: MeetingSummaryHistoryAccess
    ) -> Bool {
        currentItem(
            noteID: noteID,
            revision: revision,
            sourceFingerprint: sourceFingerprint,
            history: history
        ) != nil
    }

    private func finishGeneration(
        noteID: UUID,
        revision: Int,
        pendingReveal: Bool = false
    ) {
        guard generationRevisionByID[noteID, default: 0] == revision else {
            return
        }
        if pendingReveal {
            state.pendingRevealNoteIDs.insert(noteID)
        }
        state.generatingNoteIDs.remove(noteID)
        emitState()
    }

    private func emitState() {
        onEvent?(.stateChanged(state))
    }
}
