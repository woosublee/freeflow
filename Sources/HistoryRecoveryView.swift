import AppKit
import SwiftUI

struct HistoryUnavailableRecoveryActions: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsArchiveConfirmation = false

    var body: some View {
        Group {
            if appState.isHistoryArchiveTransitioning {
                ProgressView("Archiving recording history…")
                    .controlSize(.small)
            } else {
                HStack(spacing: 10) {
                    Button("Open Data Folder") {
                        appState.openHistoryDataFolder()
                    }
                    if appState.historyArchiveSafety == .normal {
                        Button("Archive Old History and Start Fresh…") {
                            showsArchiveConfirmation = true
                        }
                        .disabled(!appState.isHistoryUnavailable)
                    }
                    Button("Quit Quill") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .confirmationDialog(
            "Archive old history?",
            isPresented: $showsArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive and Start Fresh", role: .destructive) {
                _ = appState.archiveOldHistoryAndStartFresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Your earlier notes will not appear in the new history. The original database, audio, transcripts, and recovery metadata will be kept in a recovery snapshot. Restore, import, and merge are not available yet. Cancel to leave everything unchanged."
            )
        }
    }
}

struct HistoryArchiveNoticeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.historyArchiveSafety == .unresolvedArchive {
            let presentation = QuillUserIssueRecord(code: .historyArchived).presentation()
            VStack(alignment: .leading, spacing: 6) {
                Label(presentation.title, systemImage: "archivebox.fill")
                    .font(.caption.weight(.semibold))
                Text(presentation.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Recovery Folder") {
                    appState.openHistoryRecoveryFolder()
                }
                .controlSize(.small)
            }
            .foregroundStyle(.orange)
        }
    }
}
