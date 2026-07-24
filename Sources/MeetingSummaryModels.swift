import CryptoKit
import Foundation

enum MeetingSummaryBackendKind: String, Codable, Equatable, Sendable {
    case cloud
    case local
}

struct MeetingSummaryCalendarContext: Codable, Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
}

struct MeetingSummarySource: Equatable, Sendable {
    static let fingerprintVersion = 1

    let transcript: String
    let calendar: MeetingSummaryCalendarContext?

    var normalizedTranscript: String {
        transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var fingerprint: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        let calendarText: String
        if let calendar {
            calendarText = [
                calendar.title,
                formatter.string(from: calendar.start),
                formatter.string(from: calendar.end),
                calendar.attendees.sorted().joined(separator: "\u{1F}")
            ].joined(separator: "\u{1E}")
        } else {
            calendarText = ""
        }

        let canonical = [
            "meeting-summary-source-v\(Self.fingerprintVersion)",
            normalizedTranscript,
            calendarText
        ].joined(separator: "\u{1D}")

        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct MeetingSummaryEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let promptVersion: Int
    let generatedAt: Date
    let sourceFingerprint: String
    let modelID: String
    let backendKind: MeetingSummaryBackendKind
    var content: MeetingSummaryContent

    func preservingCompletion(
        from previous: MeetingSummaryEnvelope?
    ) -> Self {
        guard let previous else { return self }

        let previousActions = Dictionary(
            previous.content.actionItems.map {
                (MeetingSummaryActionIdentity($0), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var copy = self
        copy.content.actionItems = content.actionItems.map { action in
            guard let previousAction = previousActions[
                MeetingSummaryActionIdentity(action)
            ] else {
                return action
            }
            var preserved = action
            preserved = MeetingSummaryActionItem(
                id: previousAction.id,
                task: action.task,
                owner: action.owner,
                dueDate: action.dueDate,
                sourceQuote: action.sourceQuote,
                isCompleted: previousAction.isCompleted
            )
            return preserved
        }
        return copy
    }
}

struct MeetingSummaryContent: Codable, Equatable, Sendable {
    let overview: String
    let keyPoints: [MeetingSummaryPoint]
    let decisions: [MeetingSummaryPoint]
    var actionItems: [MeetingSummaryActionItem]
    let openQuestions: [MeetingSummaryPoint]
}

struct MeetingSummaryPoint: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sourceQuote: String?
}

struct MeetingSummaryActionItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let task: String
    let owner: String?
    let dueDate: String?
    let sourceQuote: String?
    var isCompleted: Bool
}

struct MeetingSummaryDraftPoint: Codable, Equatable, Sendable {
    let text: String
    let sourceQuote: String?
}

struct MeetingSummaryDraftActionItem: Codable, Equatable, Sendable {
    let task: String
    let owner: String?
    let dueDate: String?
    let sourceQuote: String?
}

struct MeetingSummaryDraftContent: Codable, Equatable, Sendable {
    let overview: String
    let keyPoints: [MeetingSummaryDraftPoint]
    let decisions: [MeetingSummaryDraftPoint]
    let actionItems: [MeetingSummaryDraftActionItem]
    let openQuestions: [MeetingSummaryDraftPoint]

    func materialized(
        id: () -> UUID = UUID.init
    ) -> MeetingSummaryContent {
        MeetingSummaryContent(
            overview: overview,
            keyPoints: keyPoints.map {
                MeetingSummaryPoint(
                    id: id(),
                    text: $0.text,
                    sourceQuote: $0.sourceQuote
                )
            },
            decisions: decisions.map {
                MeetingSummaryPoint(
                    id: id(),
                    text: $0.text,
                    sourceQuote: $0.sourceQuote
                )
            },
            actionItems: actionItems.map {
                MeetingSummaryActionItem(
                    id: id(),
                    task: $0.task,
                    owner: $0.owner,
                    dueDate: $0.dueDate,
                    sourceQuote: $0.sourceQuote,
                    isCompleted: false
                )
            },
            openQuestions: openQuestions.map {
                MeetingSummaryPoint(
                    id: id(),
                    text: $0.text,
                    sourceQuote: $0.sourceQuote
                )
            }
        )
    }
}

enum MeetingSummaryMarkdownRenderer {
    static func render(_ envelope: MeetingSummaryEnvelope) -> String {
        let content = envelope.content
        return [
            section(title: "Overview", body: content.overview),
            listSection(title: "Key Points", points: content.keyPoints),
            listSection(title: "Decisions", points: content.decisions),
            actionSection(content.actionItems),
            listSection(title: "Open Questions", points: content.openQuestions)
        ].joined(separator: "\n\n")
    }

    static func renderActionItem(
        _ item: MeetingSummaryActionItem
    ) -> String {
        var details: [String] = []
        if let owner = nonempty(item.owner) {
            details.append("Owner: \(owner)")
        }
        if let dueDate = nonempty(item.dueDate) {
            details.append("Due: \(dueDate)")
        }
        let suffix = details.isEmpty
            ? ""
            : " (\(details.joined(separator: ", ")))"
        return "- [\(item.isCompleted ? "x" : " ")] \(item.task)\(suffix)"
    }

    private static func section(title: String, body: String) -> String {
        "## \(title)\n\n\(body)"
    }

    private static func listSection(
        title: String,
        points: [MeetingSummaryPoint]
    ) -> String {
        let body = points.isEmpty
            ? "- None"
            : points.map { "- \($0.text)" }.joined(separator: "\n")
        return section(title: title, body: body)
    }

    private static func actionSection(
        _ items: [MeetingSummaryActionItem]
    ) -> String {
        let body = items.isEmpty
            ? "- None"
            : items.map(renderActionItem).joined(separator: "\n")
        return section(title: "Action Items", body: body)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MeetingSummarySourceLocator {
    static func range(
        of quote: String,
        in transcript: String
    ) -> Range<String.Index>? {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return transcript.range(of: trimmed, options: [.literal])
    }
}

private struct MeetingSummaryActionIdentity: Hashable {
    let task: String
    let owner: String?
    let dueDate: String?

    init(_ item: MeetingSummaryActionItem) {
        task = Self.normalize(item.task)
        owner = Self.normalizeOptional(item.owner)
        dueDate = Self.normalizeOptional(item.dueDate)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalize(value)
        return normalized.isEmpty ? nil : normalized
    }
}
