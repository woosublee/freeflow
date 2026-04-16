import SwiftUI
import UserNotifications

// MARK: - Obsidian Export Manager

final class ObsidianExportManager: ObservableObject {
    static let shared = ObsidianExportManager()
    private init() {}

    @Published private(set) var processingIDs: Set<UUID> = []

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    func export(
        itemID: UUID,
        content: String,
        fileName: String,
        vaultPath: String,
        audioSrcURL: URL?,
        useGemini: Bool,
        geminiPrompt: String,
        timestamp: Date
    ) {
        processingIDs.insert(itemID)  // 메인 스레드에서 즉시 반영
        Task {
            defer {
                Task { @MainActor in
                    self.processingIDs.remove(itemID)
                }
            }
            do {
                let finalContent: String
                if useGemini {
                    finalContent = try await self.runGemini(content: content, prompt: geminiPrompt)
                } else {
                    finalContent = content
                }

                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                let audioEmbed = audioSrcURL != nil ? "\n![[\(fileName).wav]]\n" : ""

                let markdown: String
                if useGemini {
                    // Gemini 정리 내용 상단, 원본 전사문은 하단 섹션으로
                    markdown = """
---
title: \(fileName)
date: \(iso.string(from: timestamp))
source: FreeFlow
---

\(finalContent)

---

# 전사문
\(audioEmbed)
\(content)
"""
                } else {
                    markdown = """
---
title: \(fileName)
date: \(iso.string(from: timestamp))
source: FreeFlow
---

# 전사문
\(audioEmbed)
\(content)
"""
                }

                let vaultURL = URL(fileURLWithPath: vaultPath)
                let mdURL = vaultURL.appendingPathComponent(fileName + ".md")
                try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

                if let srcURL = audioSrcURL,
                   FileManager.default.fileExists(atPath: srcURL.path) {
                    let dstURL = vaultURL.appendingPathComponent(fileName + ".wav")
                    try? FileManager.default.removeItem(at: dstURL)
                    try FileManager.default.copyItem(at: srcURL, to: dstURL)
                }

                await self.notify(title: "내보내기 완료", body: "\(fileName).md 저장됨", success: true)
            } catch {
                await self.notify(title: "내보내기 실패", body: error.localizedDescription, success: false)
            }
        }
    }

    private func notify(title: String, body: String, success: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = success ? .default : nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func runGemini(content: String, prompt: String) async throws -> String {
        let candidates = [
            "/Users/\(NSUserName())/.npm-global/bin/gemini",
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini"
        ]
        guard let geminiPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "GeminiCLI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "gemini CLI를 찾을 수 없습니다"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: geminiPath)
            process.arguments = ["--yolo", "-p", "\(prompt)\n\n---\n\(content)"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { _ in
                let raw = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let cleaned = raw.replacingOccurrences(
                    of: #"\x1B\[[0-9;]*[mGKHF]"#,
                    with: "", options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                if cleaned.isEmpty {
                    let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? "알 수 없는 오류"
                    continuation.resume(throwing: NSError(
                        domain: "GeminiCLI", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: err.trimmingCharacters(in: .whitespacesAndNewlines)]
                    ))
                } else {
                    continuation.resume(returning: cleaned)
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

// MARK: - Note Title Store

final class NoteTitleStore: ObservableObject {
    static let shared = NoteTitleStore()

    @Published private(set) var titles: [UUID: String] = [:]
    private let key = "note_custom_titles"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            titles = Dictionary(uniqueKeysWithValues: raw.compactMap {
                guard let uuid = UUID(uuidString: $0.key) else { return nil }
                return (uuid, $0.value)
            })
        }
    }

    func setTitle(_ title: String, for id: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            titles.removeValue(forKey: id)
        } else {
            titles[id] = trimmed
        }
        save()
    }

    func title(for id: UUID) -> String? { titles[id] }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: titles.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Note Browser Window

struct NoteBrowserView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var exportManager: ObsidianExportManager
    @StateObject private var titleStore = NoteTitleStore.shared
    @State private var selectedItemID: UUID?
    @State private var searchText = ""

    private var filteredHistory: [PipelineHistoryItem] {
        guard !searchText.isEmpty else { return appState.pipelineHistory }
        let q = searchText.lowercased()
        return appState.pipelineHistory.filter {
            $0.postProcessedTranscript.lowercased().contains(q) ||
            $0.contextSummary.lowercased().contains(q) ||
            (titleStore.title(for: $0.id) ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarPanel
            detailPanel
        }
        .frame(minWidth: 780, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if selectedItemID == nil {
                selectedItemID = appState.pipelineHistory.first?.id
            }
        }
        .onChange(of: appState.pipelineHistory.map(\.id)) { ids in
            if let id = selectedItemID, ids.contains(id) { return }
            selectedItemID = ids.first
        }
    }

    // MARK: - Sidebar

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if filteredHistory.isEmpty {
                Spacer()
                Text(appState.pipelineHistory.isEmpty ? "노트가 없습니다" : "검색 결과 없음")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredHistory) { item in
                            NoteListRow(
                                item: item,
                                isSelected: selectedItemID == item.id,
                                customTitle: titleStore.title(for: item.id)
                            )
                            .onTapGesture { selectedItemID = item.id }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 250)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Divider()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("검색", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let id = selectedItemID,
           let item = appState.pipelineHistory.first(where: { $0.id == id }) {
            NoteDetailView(item: item, titleStore: titleStore) {
                appState.deleteHistoryEntry(id: id)
            }
            .id(id)
        } else {
            VStack {
                Spacer()
                Image(systemName: "note.text")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
                Text("노트를 선택하세요")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Note List Row

private struct NoteListRow: View {
    let item: PipelineHistoryItem
    let isSelected: Bool
    var customTitle: String? = nil

    @EnvironmentObject private var exportManager: ObsidianExportManager

    private var isExporting: Bool {
        exportManager.processingIDs.contains(item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(rowDate)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.6))
                    .textCase(.uppercase)
                    .kerning(0.3)
                if isExporting {
                    HStack(spacing: 3) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                        Text("내보내는 중")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            HStack(spacing: 4) {
                if item.postProcessingStatus.hasPrefix("Error:") {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red.opacity(0.7))
                }
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            if !notePreview.isEmpty {
                Text(notePreview)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.65) : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                    )
            }
        }
        .contentShape(Rectangle())
    }

    private var rowDate: String {
        let f = DateFormatter()
        f.dateFormat = "M월 d일 · HH:mm"
        return f.string(from: item.timestamp)
    }

    private var displayTitle: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        return autoTitle
    }

    private var autoTitle: String {
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return "(내용 없음)" }
        let firstLine = content.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60))
    }

    private var notePreview: String {
        // 커스텀 제목이 있으면 내용 첫 줄을 미리보기로
        if customTitle != nil {
            let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(content.prefix(100))
        }
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count > autoTitle.count else { return "" }
        let rest = content.dropFirst(autoTitle.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(rest.prefix(100))
    }
}

// MARK: - Note Detail View

private struct NoteDetailView: View {
    let item: PipelineHistoryItem
    let titleStore: NoteTitleStore
    let onDelete: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var loadedContent: String?
    @State private var isCopied = false
    @State private var showExportSheet = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var isRetrying = false

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    private var canRetry: Bool {
        isError && item.audioFileName != nil
    }

    private var displayContent: String { loadedContent ?? item.postProcessedTranscript }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                noteHeader
                contentArea
            }
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadContent() }
        .sheet(isPresented: $showExportSheet) {
            ObsidianExportSheet(
                item: item,
                content: displayContent,
                customTitle: titleStore.title(for: item.id),
                onDismiss: { showExportSheet = false }
            )
        }
    }

    // MARK: Header

    private var noteHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 제목 영역
            if isEditingTitle {
                HStack(spacing: 8) {
                    TextField("제목 입력", text: $titleDraft)
                        .font(.system(size: 22, weight: .bold))
                        .textFieldStyle(.plain)
                        .onSubmit { commitTitle() }
                    Button { commitTitle() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    Button { isEditingTitle = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) {
                    Text(titleStore.title(for: item.id) ?? item.timestamp.formatted(date: .long, time: .shortened))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                    Button {
                        titleDraft = titleStore.title(for: item.id) ?? ""
                        isEditingTitle = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("제목 편집")
                }
            }

            // 날짜 + 배지
            HStack(spacing: 6) {
                if titleStore.title(for: item.id) != nil {
                    Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("·").foregroundStyle(.tertiary).font(.caption)
                }
                statusBadges
                if isError {
                    badge("전사 실패", color: .red)
                }
                if !item.contextSummary.isEmpty
                    && !item.contextSummary.hasPrefix("Could not")
                    && item.contextSummary != "Context capture disabled" {
                    Text("·").foregroundStyle(.tertiary).font(.caption)
                    Text(item.contextSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private func commitTitle() {
        titleStore.setTitle(titleDraft, for: item.id)
        isEditingTitle = false
    }

    @ViewBuilder
    private var statusBadges: some View {
        HStack(spacing: 4) {
            if item.usedLocalTranscription { badge("Local", color: .blue) }
            if !item.usedContextCapture    { badge("No Context", color: .orange) }
            if !item.usedPostProcessing    { badge("No LLM", color: .purple) }
            if item.transcriptionLanguageCode != "auto" {
                badge(item.transcriptionLanguageCode, color: .green)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    // MARK: Content

    private var contentArea: some View {
        Group {
            if loadedContent == nil {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if displayContent.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    if isError {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28, weight: .ultraLight))
                            .foregroundStyle(.red.opacity(0.6))
                        Text("전사에 실패했습니다")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(item.postProcessingStatus.replacingOccurrences(of: "Error: ", with: ""))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else {
                        Text("(내용 없음)").foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                NoteTextView(text: displayContent, bottomPadding: 64)
            }
        }
    }

    // MARK: Bottom Toolbar (floating)

    private var bottomToolbar: some View {
        HStack(spacing: 8) {
            Button {
                showExportSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                    Text("Obsidian")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(displayContent.isEmpty)

            Button {
                copyContent()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                    Text(isCopied ? "복사됨" : "복사")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            if canRetry {
                Button {
                    retryTranscription()
                } label: {
                    HStack(spacing: 5) {
                        if isRetrying {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(isRetrying ? "재시도 중..." : "재시도")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.red.opacity(0.15), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    // MARK: Actions

    private func loadContent() {
        let postProcessed = item.postProcessedTranscript
        let raw = item.rawTranscript
        let fileName = item.transcriptFileName
        Task.detached(priority: .userInitiated) {
            let text: String
            if !postProcessed.isEmpty {
                text = postProcessed
            } else if let fileName {
                text = AppState.loadTranscript(from: fileName) ?? raw
            } else {
                text = raw
            }
            await MainActor.run { loadedContent = text }
        }
    }

    private func retryTranscription() {
        isRetrying = true
        appState.retryTranscription(item: item)
        // retryingItemIDs 변화 감지해서 완료 시 isRetrying 해제
        Task {
            while appState.retryingItemIDs.contains(item.id) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await MainActor.run { isRetrying = false }
        }
    }

    private func copyContent() {
        guard !displayContent.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayContent, forType: .string)
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isCopied = false }
        }
    }
}

// MARK: - Obsidian Export Sheet

private struct ObsidianExportSheet: View {
    let item: PipelineHistoryItem
    let content: String
    var customTitle: String? = nil
    let onDismiss: () -> Void

    @AppStorage("obsidian_vault_path") private var vaultPath: String = ""
    @AppStorage("obsidian_gemini_prompt") private var geminiPrompt: String = "다음은 음성 전사 내용입니다. 핵심 내용을 유지하면서 읽기 쉽게 정리해주세요. 마크다운 형식으로 작성하되, 불필요한 설명 없이 정리된 내용만 출력해주세요.\n옵시디언에 다른 회의록을 참고하여 컨텍스트와 작성 포맷을 통일하여 주세요."
    @State private var titleInput: String = ""
    @State private var includeAudio: Bool = true
    @State private var useGemini: Bool = false
    @State private var showPromptEditor: Bool = false
    @State private var exportResult: String?
    @State private var isSuccess = false

    private var defaultTitleInput: String {
        guard let custom = customTitle, !custom.isEmpty else { return "" }
        return custom.replacingOccurrences(
            of: #"^\d{4}-\d{2}-\d{2}\s*"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    private var hasAudio: Bool {
        guard let fileName = item.audioFileName else { return false }
        return FileManager.default.fileExists(
            atPath: AppState.audioStorageDirectory().appendingPathComponent(fileName).path
        )
    }

    private var datePrefix: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: item.timestamp)
    }

    private var finalFileName: String {
        let extra = titleInput.trimmingCharacters(in: .whitespaces)
        return extra.isEmpty ? datePrefix : "\(datePrefix) \(extra)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Obsidian으로 내보내기")
                .font(.headline)
                .padding(.bottom, 20)

            // 파일 제목
            fieldLabel("파일 제목")
            HStack(spacing: 6) {
                Text(datePrefix)
                    .font(.body).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                TextField("제목 추가 (선택)", text: $titleInput)
                    .textFieldStyle(.roundedBorder)
            }
            Text("저장될 파일명: \(finalFileName).md")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 4).padding(.bottom, 16)

            // Vault 폴더
            fieldLabel("Obsidian Vault 폴더")
            HStack(spacing: 8) {
                Text(vaultPath.isEmpty ? "폴더를 선택하세요" : vaultPath)
                    .font(.callout)
                    .foregroundStyle(vaultPath.isEmpty ? .tertiary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                Button("변경") { selectVaultFolder() }.controlSize(.small)
            }
            .padding(.bottom, 16)

            // 오디오 포함
            if hasAudio {
                Toggle(isOn: $includeAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("오디오 파일 포함").font(.callout)
                        Text("md 파일과 같은 폴더에 복사됩니다")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox).padding(.bottom, 12)
            }

            // Gemini 정리
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $useGemini) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gemini로 내용 정리").font(.callout)
                        Text("내보내기 전에 Gemini CLI로 전사 내용을 정리합니다")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if useGemini {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("프롬프트").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button(showPromptEditor ? "접기" : "편집") {
                                showPromptEditor.toggle()
                            }
                            .font(.caption).controlSize(.mini)
                        }
                        if showPromptEditor {
                            TextEditor(text: $geminiPrompt)
                                .font(.caption)
                                .frame(height: 80)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        } else {
                            Text(geminiPrompt)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .padding(.bottom, 16)

            // 결과 메시지
            if let result = exportResult {
                HStack(spacing: 6) {
                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isSuccess ? .green : .red)
                    Text(result).font(.caption)
                        .foregroundStyle(isSuccess ? .green : .red)
                }
                .padding(.bottom, 8)
            }

            Spacer()
            Divider().padding(.bottom, 16)

            HStack {
                Button("취소") { onDismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(useGemini ? "백그라운드로 내보내기" : "내보내기") { exportNote() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vaultPath.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { titleInput = defaultTitleInput }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
    }

    private func selectVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "Obsidian Vault 폴더를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }

    @MainActor
    private func exportNote() {
        guard !vaultPath.isEmpty else { return }

        let safeFileName = finalFileName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")

        let audioSrcURL: URL? = (includeAudio && hasAudio && item.audioFileName != nil)
            ? AppState.audioStorageDirectory().appendingPathComponent(item.audioFileName!)
            : nil

        ObsidianExportManager.shared.export(
            itemID: item.id,
            content: content,
            fileName: safeFileName,
            vaultPath: vaultPath,
            audioSrcURL: audioSrcURL,
            useGemini: useGemini,
            geminiPrompt: geminiPrompt,
            timestamp: item.timestamp
        )

        onDismiss()
    }

    // 더미 — 컴파일러 오류 방지용 (실제 구현은 ObsidianExportManager에 있음)
    private func runGemini_unused(content: String, prompt: String) async throws -> String {
        // gemini CLI 경로 탐색
        let candidates = [
            "/Users/\(NSUserName())/.npm-global/bin/gemini",
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini"
        ]
        guard let geminiPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "GeminiCLI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "gemini CLI를 찾을 수 없습니다"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: geminiPath)
            process.arguments = ["--yolo", "-p", "\(prompt)\n\n---\n\(content)"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { _ in
                let raw = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let cleaned = raw.replacingOccurrences(
                    of: #"\x1B\[[0-9;]*[mGKHF]"#,
                    with: "", options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                if cleaned.isEmpty {
                    let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? "알 수 없는 오류"
                    continuation.resume(throwing: NSError(
                        domain: "GeminiCLI", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: err.trimmingCharacters(in: .whitespacesAndNewlines)]
                    ))
                } else {
                    continuation.resume(returning: cleaned)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Native Text View (NSTextView wrapper)

private struct NoteTextView: NSViewRepresentable {
    let text: String
    var bottomPadding: CGFloat = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 28, height: 16)

        scrollView.documentView = textView
        applyText(text, to: textView, bottomPadding: bottomPadding)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            applyText(text, to: textView, bottomPadding: bottomPadding)
        }
    }

    private func applyText(_ text: String, to textView: NSTextView, bottomPadding: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.paragraphSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .paragraphStyle: style,
            .foregroundColor: NSColor.labelColor
        ]
        // 하단 툴바 공간 확보용 빈 줄 추가
        let padding = String(repeating: "\n", count: max(1, Int(bottomPadding / 20)))
        let attrStr = NSMutableAttributedString(string: text + padding, attributes: attrs)
        textView.textStorage?.setAttributedString(attrStr)
        textView.typingAttributes = attrs
    }
}
