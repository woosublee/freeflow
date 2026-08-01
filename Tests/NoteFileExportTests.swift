import Foundation

@main
struct NoteFileExportTests {
    static func main() throws {
        try testSanitizedBaseNameAndFallback()
        try testSuggestedBaseNamePrefersTitle()
        try testSuggestedBaseNameFallsBackToCalendarTitle()
        try testSuggestedBaseNameUsesLocalizedTimestamp()
        try testLocalizedTimestampNameExportsWithColon()
        try testDestinationNamesPreserveAudioExtension()
        try testExportsTranscriptAndAudio()
        try testConflictDoesNotOverwriteWithoutConsent()
        try testPreparedFileReportsLateConflict()
        try testReplaceOverwritesExistingFile()
        try testPartialFailureKeepsSuccessfulTranscript()
        print("NoteFileExportTests passed")
    }

    private static func testSanitizedBaseNameAndFallback() throws {
        precondition(
            NoteFileExporter.sanitizedBaseName(
                "  meeting/a:b?  ",
                fallback: "fallback"
            ) == "meeting-a:b-"
        )
        precondition(
            NoteFileExporter.sanitizedBaseName(
                " /\\*?\"<>| ",
                fallback: "2026년 7월 24일 오전 1:45"
            ) == "2026년 7월 24일 오전 1:45"
        )
    }

    private static let localizedNameTimestamp = Date(
        timeIntervalSince1970: 1_784_825_100
    )
    private static let seoulTimeZone = TimeZone(identifier: "Asia/Seoul")!

    private static func testSuggestedBaseNamePrefersTitle() throws {
        let name = NoteFileExportNaming.suggestedBaseName(
            customTitle: "  Product review  ",
            calendarTitle: "Calendar review",
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "ko_KR"),
            timeZone: seoulTimeZone
        )
        precondition(name == "Product review")
    }

    private static func testSuggestedBaseNameFallsBackToCalendarTitle() throws {
        let name = NoteFileExportNaming.suggestedBaseName(
            customTitle: " \n ",
            calendarTitle: "  Product review  ",
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "ko_KR"),
            timeZone: seoulTimeZone
        )
        precondition(name == "Product review")
    }

    private static func testSuggestedBaseNameUsesLocalizedTimestamp() throws {
        let korean = NoteFileExportNaming.suggestedBaseName(
            customTitle: " \n ",
            calendarTitle: nil,
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "ko_KR"),
            timeZone: seoulTimeZone
        )
        let english = NoteFileExportNaming.suggestedBaseName(
            customTitle: nil,
            calendarTitle: nil,
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "en_US"),
            timeZone: seoulTimeZone
        )

        precondition(korean == "2026년 7월 24일 오전 1:45")
        precondition(english == "July 24, 2026 at 1:45 AM")
    }

    private static func testLocalizedTimestampNameExportsWithColon() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let audio = sourceDirectory.appendingPathComponent("recording.wav")
        try Data([4, 5, 6]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "# Transcript", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "2026년 7월 24일 오전 1:45",
            destinationDirectory: destination
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(Set(result.savedItems) == [.transcript, .audio])
        precondition(result.failures.isEmpty)
        precondition(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("2026년 7월 24일 오전 1:45.txt")
                    .path
            )
        )
        precondition(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("2026년 7월 24일 오전 1:45.wav")
                    .path
            )
        )
    }

    private static func testDestinationNamesPreserveAudioExtension() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.m4a")
        try Data([1, 2, 3]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "hello", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .markdown,
            baseName: "Meeting",
            destinationDirectory: root
        )
        let urls = NoteFileExporter.destinationURLs(for: request)

        precondition(urls[.transcript]?.lastPathComponent == "Meeting.md")
        precondition(urls[.audio]?.lastPathComponent == "Meeting.m4a")
    }

    private static func testExportsTranscriptAndAudio() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let audio = sourceDirectory.appendingPathComponent("recording.wav")
        try Data([4, 5, 6]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "# Transcript", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: destination
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        let transcript = try String(
            contentsOf: destination.appendingPathComponent("Meeting.txt"),
            encoding: .utf8
        )
        let audioData = try Data(
            contentsOf: destination.appendingPathComponent("Meeting.wav")
        )
        precondition(Set(result.savedItems) == [.transcript, .audio])
        precondition(result.failures.isEmpty)
        precondition(transcript == "# Transcript")
        precondition(audioData == Data([4, 5, 6]))
    }

    private static func testConflictDoesNotOverwriteWithoutConsent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Meeting.txt")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "new", audioURL: nil),
            selectedItems: [.transcript],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems.isEmpty)
        let existingContent = try String(contentsOf: existing, encoding: .utf8)
        precondition(result.failures == [
            NoteFileExportFailure(item: .transcript, reason: .destinationExists)
        ])
        precondition(existingContent == "old")
    }

    private static func testPreparedFileReportsLateConflict() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = root.appendingPathComponent("prepared.tmp")
        let destination = root.appendingPathComponent("Meeting.txt")
        try "new".write(to: prepared, atomically: true, encoding: .utf8)
        try "old".write(to: destination, atomically: true, encoding: .utf8)

        do {
            try NoteFileExporter.installPreparedFile(
                prepared,
                at: destination,
                replaceExisting: false
            )
            preconditionFailure("Expected a late destination conflict")
        } catch NoteFileExporter.ExportWriteError.destinationExists {
            // Expected.
        }
        let destinationContent = try String(contentsOf: destination, encoding: .utf8)
        precondition(destinationContent == "old")
    }

    private static func testReplaceOverwritesExistingFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Meeting.txt")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "new", audioURL: nil),
            selectedItems: [.transcript],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: true)

        let existingContent = try String(contentsOf: existing, encoding: .utf8)
        precondition(result.savedItems == [.transcript])
        precondition(result.failures.isEmpty)
        precondition(existingContent == "new")
    }

    private static func testPartialFailureKeepsSuccessfulTranscript() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingAudio = root.appendingPathComponent("missing.wav")
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "saved text", audioURL: missingAudio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems == [.transcript])
        let transcript = try String(
            contentsOf: root.appendingPathComponent("Meeting.txt"),
            encoding: .utf8
        )
        precondition(result.failures == [
            NoteFileExportFailure(item: .audio, reason: .sourceMissing)
        ])
        precondition(transcript == "saved text")
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-file-export-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
