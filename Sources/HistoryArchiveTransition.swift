import CoreData
import Darwin
import Foundation

enum HistoryArchiveSafety: Equatable, Sendable {
    case normal
    case unresolvedArchive
    case unresolvedInterruptedTransaction
    case transitioning
}

struct HistoryArchiveSnapshotComponent: Codable, Equatable, Sendable {
    enum Identifier: String, Codable, CaseIterable, Sendable {
        case sqlite
        case sqliteWAL
        case sqliteSHM
        case assetReferenceSnapshot
        case audio
        case transcripts
        case cloudTranscriptionJobs
        case legacyRecoveryEvidence
    }

    let identifier: Identifier
    let relativePath: String
    let byteCount: UInt64
    let isDirectory: Bool
}

struct HistoryArchiveSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let archivedAt: Date
    let components: [HistoryArchiveSnapshotComponent]
}

struct HistoryArchiveTransitionResult: Sendable {
    let snapshot: HistoryArchiveSnapshot
    let recoveryDirectory: URL
}

enum HistoryArchiveTransitionError: Error, LocalizedError {
    case recoveryAlreadyRequiresAttention
    case freshStoreUnavailable
    case probeDidNotPersist
    case probeDidNotDelete
    case unexpectedActiveArtifact(String)
    case rollbackFailed
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .recoveryAlreadyRequiresAttention:
            return "An existing history recovery needs attention before archiving again."
        case .freshStoreUnavailable:
            return "A new recording history could not be verified."
        case .probeDidNotPersist:
            return "A new recording history did not retain its verification record."
        case .probeDidNotDelete:
            return "A new recording history did not remove its verification record."
        case .unexpectedActiveArtifact(let name):
            return "An unexpected active history artifact exists at \(name)."
        case .rollbackFailed:
            return "The history archive could not be rolled back safely."
        case .systemCall(let operation, let code):
            return "\(operation) failed (errno \(code))."
        }
    }
}

final class HistoryArchiveTransition {
    private static let recoveryDirectoryName = "Recovery"
    private static let transactionDirectoryName = ".transactions"
    private static let stagingPrefix = ".staging-"
    private static let snapshotPrefix = "history-"

    private let fileManager: FileManager
    private let now: () -> Date
    private let makeID: () -> UUID
    private let makeStore: (URL) -> PipelineHistoryStore
    private let moveItem: (FileManager, URL, URL) throws -> Void
    private let syncDirectory: (URL) throws -> Void

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init,
        makeStore: @escaping (URL) -> PipelineHistoryStore = {
            PipelineHistoryStore(storeURL: $0)
        },
        moveItem: @escaping (FileManager, URL, URL) throws -> Void = {
            fileManager, sourceURL, destinationURL in
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        },
        syncDirectory: @escaping (URL) throws -> Void = HistoryArchiveDurability.syncDirectory
    ) {
        self.fileManager = fileManager
        self.now = now
        self.makeID = makeID
        self.makeStore = makeStore
        self.moveItem = moveItem
        self.syncDirectory = syncDirectory
    }

    static func inspect(at storageRoot: URL) -> HistoryArchiveSafety {
        let transition = HistoryArchiveTransition()
        return transition.inspectRecovery(at: storageRoot)
    }

    static func rollbackInterruptedTransactions(at storageRoot: URL) -> HistoryArchiveSafety {
        let transition = HistoryArchiveTransition()
        return transition.rollbackInterruptedTransactions(at: storageRoot)
    }

    func archiveAndCreateFreshHistory(
        at storageRoot: URL
    ) throws -> HistoryArchiveTransitionResult {
        guard inspectRecovery(at: storageRoot) == .normal else {
            throw HistoryArchiveTransitionError.recoveryAlreadyRequiresAttention
        }

        let archiveID = makeID()
        let archiveDate = now()
        let recoveryDirectory = storageRoot.appendingPathComponent(
            Self.recoveryDirectoryName,
            isDirectory: true
        )
        let transactionsDirectory = recoveryDirectory.appendingPathComponent(
            Self.transactionDirectoryName,
            isDirectory: true
        )
        let stagingDirectoryName = Self.stagingPrefix + archiveID.uuidString.lowercased()
        let snapshotDirectoryName = Self.snapshotDirectoryName(
            archivedAt: archiveDate,
            id: archiveID
        )
        let stagingDirectory = recoveryDirectory.appendingPathComponent(
            stagingDirectoryName,
            isDirectory: true
        )
        let snapshotDirectory = recoveryDirectory.appendingPathComponent(
            snapshotDirectoryName,
            isDirectory: true
        )
        let transactionURL = transactionsDirectory.appendingPathComponent(
            archiveID.uuidString.lowercased() + ".json"
        )
        let payloadDirectory = stagingDirectory.appendingPathComponent("payload", isDirectory: true)

        try fileManager.createDirectory(at: transactionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        try syncDirectory(recoveryDirectory)

        var transaction = HistoryArchiveTransaction(
            id: archiveID,
            createdAt: archiveDate,
            stagingDirectoryName: stagingDirectoryName,
            snapshotDirectoryName: snapshotDirectoryName,
            components: makeTransactionComponents(at: storageRoot)
        )
        var snapshotWasRenamed = false
        try writeTransaction(transaction, to: transactionURL)

        do {
            for index in transaction.components.indices where transaction.components[index].state != .absent {
                transaction.components[index].state = .preparedToMove
                try writeTransaction(transaction, to: transactionURL)

                let component = transaction.components[index]
                let sourceURL = storageRoot.appendingPathComponent(component.relativePath)
                let destinationURL = payloadDirectory.appendingPathComponent(component.relativePath)
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try moveItem(fileManager, sourceURL, destinationURL)
                try syncDirectory(sourceURL.deletingLastPathComponent())
                try syncDirectory(destinationURL.deletingLastPathComponent())

                transaction.components[index].state = .moved
                try writeTransaction(transaction, to: transactionURL)
            }

            transaction.phase = .probingFreshHistory
            try writeTransaction(transaction, to: transactionURL)
            try verifyFreshHistory(at: storageRoot)

            let snapshot = HistoryArchiveSnapshot(
                schemaVersion: HistoryArchiveSnapshot.currentSchemaVersion,
                id: archiveID,
                archivedAt: archiveDate,
                components: transaction.components.compactMap { component in
                    guard component.state == .moved else { return nil }
                    return HistoryArchiveSnapshotComponent(
                        identifier: component.identifier,
                        relativePath: component.relativePath,
                        byteCount: component.byteCount,
                        isDirectory: component.isDirectory
                    )
                }
            )
            let manifestURL = stagingDirectory.appendingPathComponent("manifest.json")
            try HistoryArchiveDurability.write(
                JSONEncoder().encode(snapshot),
                to: manifestURL,
                fileManager: fileManager
            )

            transaction.phase = .readyToPublish
            try writeTransaction(transaction, to: transactionURL)
            guard !fileManager.fileExists(atPath: snapshotDirectory.path) else {
                throw HistoryArchiveTransitionError.unexpectedActiveArtifact(
                    snapshotDirectory.lastPathComponent
                )
            }
            try moveItem(fileManager, stagingDirectory, snapshotDirectory)
            snapshotWasRenamed = true
            try syncDirectory(recoveryDirectory)
            try fileManager.removeItem(at: transactionURL)
            try syncDirectory(transactionsDirectory)
            return HistoryArchiveTransitionResult(
                snapshot: snapshot,
                recoveryDirectory: recoveryDirectory
            )
        } catch {
            if snapshotWasRenamed {
                throw error
            }
            do {
                try rollback(
                    transaction: transaction,
                    storageRoot: storageRoot,
                    stagingDirectory: stagingDirectory,
                    transactionURL: transactionURL
                )
            } catch {
                throw HistoryArchiveTransitionError.rollbackFailed
            }
            throw error
        }
    }

    private func inspectRecovery(at storageRoot: URL) -> HistoryArchiveSafety {
        let recoveryDirectory = storageRoot.appendingPathComponent(
            Self.recoveryDirectoryName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: recoveryDirectory.path) else { return .normal }

        do {
            let entries = try fileManager.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var hasPublishedSnapshot = false
            for entry in entries {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                if entry.lastPathComponent.hasPrefix(Self.snapshotPrefix) {
                    guard Self.isPublishedSnapshot(entry) else {
                        return .unresolvedInterruptedTransaction
                    }
                    hasPublishedSnapshot = true
                }
            }
            let transactionsDirectory = recoveryDirectory.appendingPathComponent(
                Self.transactionDirectoryName,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: transactionsDirectory.path),
               try !fileManager.contentsOfDirectory(atPath: transactionsDirectory.path).isEmpty {
                return .unresolvedInterruptedTransaction
            }
            return hasPublishedSnapshot ? .unresolvedArchive : .normal
        } catch {
            return .unresolvedInterruptedTransaction
        }
    }

    func rollbackInterruptedTransactions(at storageRoot: URL) -> HistoryArchiveSafety {
        let recoveryDirectory = storageRoot.appendingPathComponent(
            Self.recoveryDirectoryName,
            isDirectory: true
        )
        let transactionsDirectory = recoveryDirectory.appendingPathComponent(
            Self.transactionDirectoryName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: transactionsDirectory.path) else {
            return inspectRecovery(at: storageRoot)
        }

        do {
            let transactionEntries = try fileManager.contentsOfDirectory(
                at: transactionsDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            for entry in transactionEntries where entry.lastPathComponent.hasPrefix(".")
                && entry.pathExtension == "tmp" {
                try fileManager.removeItem(at: entry)
            }
            let transactionURLs = transactionEntries.filter {
                !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "json"
            }
            for transactionURL in transactionURLs {
                let transaction = try JSONDecoder().decode(
                    HistoryArchiveTransaction.self,
                    from: Data(contentsOf: transactionURL)
                )
                let snapshotDirectory = recoveryDirectory.appendingPathComponent(
                    transaction.snapshotDirectoryName,
                    isDirectory: true
                )
                if Self.isPublishedSnapshot(snapshotDirectory) {
                    try syncDirectory(recoveryDirectory)
                    try fileManager.removeItem(at: transactionURL)
                    continue
                }
                let stagingDirectory = recoveryDirectory.appendingPathComponent(
                    transaction.stagingDirectoryName,
                    isDirectory: true
                )
                try rollback(
                    transaction: transaction,
                    storageRoot: storageRoot,
                    stagingDirectory: stagingDirectory,
                    transactionURL: transactionURL
                )
            }
            try syncDirectory(transactionsDirectory)
        } catch {
            return .unresolvedInterruptedTransaction
        }
        return inspectRecovery(at: storageRoot)
    }

    private func makeTransactionComponents(at storageRoot: URL) -> [HistoryArchiveTransactionComponent] {
        HistoryArchiveSnapshotComponent.Identifier.allCases.map { identifier in
            let relativePath = Self.relativePath(for: identifier)
            let sourceURL = storageRoot.appendingPathComponent(relativePath)
            let exists = fileManager.fileExists(atPath: sourceURL.path)
            let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? false
            return HistoryArchiveTransactionComponent(
                identifier: identifier,
                relativePath: relativePath,
                byteCount: exists ? Self.byteCount(at: sourceURL, fileManager: fileManager) : 0,
                isDirectory: isDirectory,
                state: exists ? .pending : .absent
            )
        }
    }

    private func verifyFreshHistory(at storageRoot: URL) throws {
        let storeURL = storageRoot.appendingPathComponent("PipelineHistory.sqlite")
        let writer = makeStore(storeURL)
        guard writer.availability == .ready,
              writer.durability == .durable,
              writer.verifyHistoryReadable() else {
            throw HistoryArchiveTransitionError.freshStoreUnavailable
        }

        let probe = PipelineHistoryItem(
            id: UUID(),
            timestamp: now(),
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: "",
            debugStatus: "",
            customVocabulary: "",
            usedPostProcessing: false
        )
        _ = try writer.upsert(probe, maxCount: Int.max, requiresDurableStore: true)

        let reader = makeStore(storeURL)
        guard reader.availability == .ready,
              reader.verifyHistoryReadable(),
              reader.loadAllHistory().contains(where: { $0.id == probe.id }) else {
            throw HistoryArchiveTransitionError.probeDidNotPersist
        }
        _ = try reader.delete(id: probe.id)

        let activeStore = makeStore(storeURL)
        guard activeStore.availability == .ready,
              activeStore.durability == .durable,
              activeStore.verifyHistoryReadable(),
              !activeStore.loadAllHistory().contains(where: { $0.id == probe.id }) else {
            throw HistoryArchiveTransitionError.probeDidNotDelete
        }
    }

    private func rollback(
        transaction: HistoryArchiveTransaction,
        storageRoot: URL,
        stagingDirectory: URL,
        transactionURL: URL
    ) throws {
        if transaction.phase != .prepared {
            try removeFreshStoreArtifacts(at: storageRoot)
        }
        for component in transaction.components.reversed() where component.state != .absent {
            let sourceURL = storageRoot.appendingPathComponent(component.relativePath)
            let stagedURL = stagingDirectory
                .appendingPathComponent("payload", isDirectory: true)
                .appendingPathComponent(component.relativePath)
            guard fileManager.fileExists(atPath: stagedURL.path) else { continue }
            guard !fileManager.fileExists(atPath: sourceURL.path) else {
                throw HistoryArchiveTransitionError.unexpectedActiveArtifact(
                    component.relativePath
                )
            }
            try fileManager.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: stagedURL, to: sourceURL)
            try syncDirectory(sourceURL.deletingLastPathComponent())
        }
        try? fileManager.removeItem(at: stagingDirectory)
        try? fileManager.removeItem(at: transactionURL)
    }

    private func removeFreshStoreArtifacts(at storageRoot: URL) throws {
        let storeURL = storageRoot.appendingPathComponent("PipelineHistory.sqlite")
        let freshArtifacts = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
            storageRoot.appendingPathComponent("PipelineHistory-asset-references.json")
        ]
        for artifact in freshArtifacts where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
        try syncDirectory(storageRoot)
    }

    private func writeTransaction(
        _ transaction: HistoryArchiveTransaction,
        to transactionURL: URL
    ) throws {
        try HistoryArchiveDurability.write(
            JSONEncoder().encode(transaction),
            to: transactionURL,
            fileManager: fileManager
        )
    }

    private static func relativePath(
        for identifier: HistoryArchiveSnapshotComponent.Identifier
    ) -> String {
        switch identifier {
        case .sqlite:
            return "PipelineHistory.sqlite"
        case .sqliteWAL:
            return "PipelineHistory.sqlite-wal"
        case .sqliteSHM:
            return "PipelineHistory.sqlite-shm"
        case .assetReferenceSnapshot:
            return "PipelineHistory-asset-references.json"
        case .audio:
            return "audio"
        case .transcripts:
            return "transcripts"
        case .cloudTranscriptionJobs:
            return "cloud-transcription/jobs"
        case .legacyRecoveryEvidence:
            return "History Recovery"
        }
    }

    private static func snapshotDirectoryName(archivedAt: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return Self.snapshotPrefix
            + formatter.string(from: archivedAt)
            + "-"
            + id.uuidString.lowercased()
    }

    private static func isPublishedSnapshot(_ directory: URL) -> Bool {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let payloadURL = directory.appendingPathComponent("payload", isDirectory: true)
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: payloadURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(HistoryArchiveSnapshot.self, from: data) else {
            return false
        }
        return manifest.schemaVersion == HistoryArchiveSnapshot.currentSchemaVersion
    }

    private static func byteCount(at url: URL, fileManager: FileManager) -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber {
            return size.uint64Value
        }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += UInt64(max(0, size))
        }
        return total
    }
}

struct HistoryArchiveTransaction: Codable {
    static let currentSchemaVersion = 1

    enum Phase: String, Codable {
        case prepared
        case probingFreshHistory
        case readyToPublish
    }

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var phase: Phase
    let stagingDirectoryName: String
    let snapshotDirectoryName: String
    var components: [HistoryArchiveTransactionComponent]

    init(
        id: UUID,
        createdAt: Date,
        stagingDirectoryName: String,
        snapshotDirectoryName: String,
        components: [HistoryArchiveTransactionComponent]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        phase = .prepared
        self.stagingDirectoryName = stagingDirectoryName
        self.snapshotDirectoryName = snapshotDirectoryName
        self.components = components
    }
}

struct HistoryArchiveTransactionComponent: Codable {
    enum State: String, Codable {
        case absent
        case pending
        case preparedToMove
        case moved
    }

    let identifier: HistoryArchiveSnapshotComponent.Identifier
    let relativePath: String
    let byteCount: UInt64
    let isDirectory: Bool
    var state: State
}

private enum HistoryArchiveDurability {
    static func write(_ data: Data, to targetURL: URL, fileManager: FileManager) throws {
        let parentDirectory = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let temporaryURL = parentDirectory.appendingPathComponent(
            ".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw HistoryArchiveTransitionError.systemCall("open archive metadata", errno)
        }
        var isOpen = true
        defer {
            if isOpen { Darwin.close(descriptor) }
            try? fileManager.removeItem(at: temporaryURL)
        }

        try writeAll(data, to: descriptor)
        try fullSync(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw HistoryArchiveTransitionError.systemCall("close archive metadata", errno)
        }
        isOpen = false
        guard Darwin.rename(temporaryURL.path, targetURL.path) == 0 else {
            throw HistoryArchiveTransitionError.systemCall("rename archive metadata", errno)
        }
        try syncDirectory(parentDirectory)
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw HistoryArchiveTransitionError.systemCall("open archive directory", errno)
        }
        defer { Darwin.close(descriptor) }
        try fullSync(descriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else {
                    throw HistoryArchiveTransitionError.systemCall("write archive metadata", errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func fullSync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw HistoryArchiveTransitionError.systemCall("sync archive metadata", errno)
        }
    }
}
