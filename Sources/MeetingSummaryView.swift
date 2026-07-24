import SwiftUI

struct MeetingSummaryView: View {
    let envelope: MeetingSummaryEnvelope
    let availability: MeetingSummaryAvailability
    let isStale: Bool
    let sourceQuoteIsValid: (String) -> Bool
    let onToggleAction: (UUID, Bool) -> Void
    let onViewSource: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topBar
                statusMessages
                summaryContent(envelope)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Label("Delete Summary", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete Summary")
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if isStale {
            statusBanner(
                icon: "exclamationmark.triangle",
                title: "Transcript changed after this summary was generated.",
                detail: "Regenerate to align the draft with the current transcript.",
                color: .orange
            )
        }
        if availability == .featureDisabled {
            statusBanner(
                icon: "pause.circle",
                title: "Meeting Summary is off",
                detail: "This saved summary is still available. Turn the feature on to regenerate it.",
                color: .secondary
            )
        } else if availability == .modelUnavailable {
            statusBanner(
                icon: "exclamationmark.circle",
                title: "Summary model is unavailable.",
                detail: "This saved summary remains available for review and copying.",
                color: .secondary
            )
        }
    }

    private func statusBanner(
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func summaryContent(
        _ envelope: MeetingSummaryEnvelope
    ) -> some View {
        let content = envelope.content
        return VStack(alignment: .leading, spacing: 24) {
            summarySection(title: "Overview") {
                Text(content.overview)
                    .font(.body)
                    .textSelection(.enabled)
            }
            pointSection(title: "Key Points", points: content.keyPoints)
            pointSection(title: "Decisions", points: content.decisions)
            actionSection(content.actionItems)
            pointSection(title: "Open Questions", points: content.openQuestions)
        }
    }

    private func pointSection(
        title: LocalizedStringKey,
        points: [MeetingSummaryPoint]
    ) -> some View {
        summarySection(title: title) {
            if points.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(points) { point in
                        evidenceRow(text: point.text, sourceQuote: point.sourceQuote)
                    }
                }
            }
        }
    }

    private func actionSection(
        _ actions: [MeetingSummaryActionItem]
    ) -> some View {
        summarySection(title: "Action Items") {
            if actions.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(actions) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle(
                                item.task,
                                isOn: Binding(
                                    get: { item.isCompleted },
                                    set: { onToggleAction(item.id, $0) }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel(item.task)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.task)
                                    .strikethrough(item.isCompleted)
                                    .foregroundStyle(
                                        item.isCompleted ? .secondary : .primary
                                    )
                                actionMetadata(item)
                                if let quote = nonempty(item.sourceQuote),
                                   sourceQuoteIsValid(quote) {
                                    sourceButton(quote)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func actionMetadata(_ item: MeetingSummaryActionItem) -> some View {
        let owner = nonempty(item.owner)
        let dueDate = nonempty(item.dueDate)
        return HStack(spacing: 8) {
            if let owner {
                Text(owner)
            } else {
                Text("Owner needs review")
            }
            Text("·")
                .foregroundStyle(.tertiary)
            if let dueDate {
                Text(dueDate)
            } else {
                Text("Due date needs review")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func evidenceRow(
        text: String,
        sourceQuote: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 4, height: 4)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .textSelection(.enabled)
                if let quote = nonempty(sourceQuote), sourceQuoteIsValid(quote) {
                    sourceButton(quote)
                }
            }
        }
    }

    private func sourceButton(_ quote: String) -> some View {
        Button {
            onViewSource(quote)
        } label: {
            Label("View in Transcript", systemImage: "text.magnifyingglass")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func summarySection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
