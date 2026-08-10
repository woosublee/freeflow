import Foundation

enum TranscriptStatus: Equatable {
    case done, recording, transcribing, audioOnly, recovered, fail
}

struct CloudTranscriptionDisplayProgress: Equatable, Sendable {
    let completedChunkCount: Int
    let totalChunkCount: Int
    let activeAttempt: Int?
}

func transcriptStatus(for item: PipelineHistoryItem, retrying: Set<UUID>) -> TranscriptStatus {
    if retrying.contains(item.id) { return .transcribing }
    switch item.machineStatus {
    case .liveRecording:
        return .recording
    case .importing, .cloudTranscribing:
        return .transcribing
    case .audioOnly:
        return .audioOnly
    case .recovered:
        return .recovered
    case .failed:
        return .fail
    case .completed:
        return item.postProcessingStatus
            == PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus
            ? .transcribing
            : .done
    }
}

enum NoteTimestampFormatter {
    static func detailTimestamp(for item: PipelineHistoryItem, locale: Locale = .current) -> String {
        guard let startedAt = item.recordingStartedAt,
              let endedAt = item.recordingEndedAt,
              endedAt >= startedAt else {
            return normalized(detailTimestampFormatter(locale: locale).string(from: item.timestamp))
        }

        return normalized(
            detailIntervalFormatter(locale: locale).string(from: startedAt, to: endedAt)
        )
    }

    static func rowTimestamp(for item: PipelineHistoryItem, locale: Locale = .current) -> String {
        let timestamp = item.recordingStartedAt ?? item.timestamp
        return normalized(rowTimestampFormatter(locale: locale).string(from: timestamp))
    }

    private static func rowTimestampFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMMdEEEjm")
        return formatter
    }

    private static func detailTimestampFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = .current
        formatter.setLocalizedDateFormatFromTemplate("yMMMdEEEjm")
        return formatter
    }

    private static func detailIntervalFormatter(locale: Locale) -> DateIntervalFormatter {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = .current
        formatter.dateTemplate = "yMMMdEEEjm"
        return formatter
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
    }
}

struct NoteListRowDisplayData: Equatable {
    let id: UUID
    let status: TranscriptStatus
    let rowDate: String
    let displayTitle: String
    let preview: String
    let hasMeetingSummary: Bool

    init(
        item: PipelineHistoryItem,
        retryingIDs: Set<UUID>,
        cloudProgress: CloudTranscriptionDisplayProgress? = nil,
        locale: Locale = .current,
        localizationLanguage: String = preferredLocalizedStringLanguage(),
        localizationBundle: Bundle = .main,
        localization: (
            _ key: String,
            _ arguments: [CVarArg]
        ) -> String = { key, arguments in
            String(
                format: localizedCatalogString(key),
                locale: .current,
                arguments: arguments
            )
        }
    ) {
        let status = transcriptStatus(for: item, retrying: retryingIDs)
        let trimmedCustomTitle = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = trimmedCustomTitle?.isEmpty == true ? nil : trimmedCustomTitle
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = NoteTitleResolver.displayTitle(
            for: item,
            isTranscribing: status == .transcribing,
            language: localizationLanguage,
            bundle: localizationBundle
        )

        self.id = item.id
        self.status = status
        self.rowDate = NoteTimestampFormatter.rowTimestamp(for: item, locale: locale)
        self.displayTitle = displayTitle
        self.hasMeetingSummary = item.meetingSummaryJSON != nil
        self.preview = Self.preview(
            for: item,
            status: status,
            content: content,
            customTitle: customTitle,
            displayTitle: displayTitle,
            cloudProgress: cloudProgress,
            localizationLanguage: localizationLanguage,
            localizationBundle: localizationBundle,
            localization: localization
        )
    }

    private static func preview(
        for item: PipelineHistoryItem,
        status: TranscriptStatus,
        content: String,
        customTitle: String?,
        displayTitle: String,
        cloudProgress: CloudTranscriptionDisplayProgress?,
        localizationLanguage: String,
        localizationBundle: Bundle,
        localization: (
            _ key: String,
            _ arguments: [CVarArg]
        ) -> String
    ) -> String {
        if status == .audioOnly {
            return localizedCatalogString(
                "Not transcribed",
                language: localizationLanguage,
                bundle: localizationBundle
            )
        }
        if status == .fail {
            return item.userIssuePresentation(
                language: localizationLanguage,
                bundle: localizationBundle
            )?.body ?? localizedCatalogString(
                "Quill could not complete this transcription.",
                language: localizationLanguage,
                bundle: localizationBundle
            )
        }
        if status == .recovered {
            return item.recoveredRecordingContext?.localizedDescription() ?? ""
        }
        if status == .transcribing {
            guard item.machineStatus == .cloudTranscribing,
                  let cloudProgress else {
                return ""
            }
            guard cloudProgress.activeAttempt != nil else {
                return localization("Resuming cloud transcription…", [])
            }
            let activeChunkNumber = min(
                cloudProgress.completedChunkCount + 1,
                cloudProgress.totalChunkCount
            )
            return localization(
                "Transcribing %d of %d…",
                [activeChunkNumber, cloudProgress.totalChunkCount]
            )
        }
        if customTitle != nil || item.calendarMatch?.appliedTitle != nil {
            return String(content.prefix(100))
        }
        if content.hasPrefix(displayTitle) {
            let rest = content.dropFirst(displayTitle.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return String(rest.prefix(100))
        }
        return String(content.prefix(100))
    }
}
