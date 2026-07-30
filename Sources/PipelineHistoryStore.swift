import Foundation
import CoreData

struct DeletedPipelineHistoryAssets {
    let historyID: UUID
    let audioFileName: String?
    let transcriptFileName: String?
}

enum PipelineHistoryStoreError: Error {
    case storeUnavailable
    case durableStoreUnavailable
}

enum PipelineHistoryDurability: Equatable, Sendable {
    case durable
    case recovered(backupName: String)
    case inMemoryFallback
}

final class PipelineHistoryStore {
    /// Built once and treated as immutable after static initialization. Sharing
    /// the schema prevents multiple entity descriptions from claiming the same
    /// NSManagedObject subclass when several in-memory stores coexist in tests.
    nonisolated(unsafe) private static let managedObjectModel = makeModel()

    private let container: NSPersistentContainer
    private var isStoreLoaded: Bool
    private(set) var durability: PipelineHistoryDurability

    private var isDurableStore: Bool {
        durability != .inMemoryFallback
    }

    convenience init() {
        self.init(inMemory: false)
    }

    convenience init(inMemory: Bool) {
        self.init(
            storeURL: inMemory ? nil : Self.defaultStoreURL(),
            usesInMemoryStore: inMemory,
            persistentStoreLoader: Self.loadPersistentStoresSynchronously,
            moveItem: Self.moveFile
        )
    }

    convenience init(
        storeURL: URL,
        persistentStoreLoader: @escaping (NSPersistentContainer) -> Error?,
        moveItem: @escaping (URL, URL) throws -> Void = PipelineHistoryStore.moveFile
    ) {
        self.init(
            storeURL: storeURL,
            usesInMemoryStore: false,
            persistentStoreLoader: persistentStoreLoader,
            moveItem: moveItem
        )
    }

    private init(
        storeURL: URL?,
        usesInMemoryStore: Bool,
        persistentStoreLoader: @escaping (NSPersistentContainer) -> Error?,
        moveItem: @escaping (URL, URL) throws -> Void
    ) {
        container = NSPersistentContainer(
            name: "PipelineHistory",
            managedObjectModel: Self.managedObjectModel
        )
        isStoreLoaded = false
        durability = .durable

        var loaded = false
        var recoveredBackupName: String?

        if usesInMemoryStore {
            configureInMemoryStore()
            loaded = persistentStoreLoader(container) == nil
        } else {
            configurePersistentStore(at: storeURL)
            if persistentStoreLoader(container) == nil {
                loaded = true
            } else if let storeURL {
                print("[PipelineHistoryStore] Failed to load persistent store. Attempting recovery.")
                do {
                    recoveredBackupName = try Self.moveSQLiteStoreFilesToRecovery(
                        at: storeURL,
                        moveItem: moveItem
                    )
                    removeLoadedPersistentStores()
                    configurePersistentStore(at: storeURL)
                    loaded = persistentStoreLoader(container) == nil
                } catch {
                    print("[PipelineHistoryStore] Failed to preserve persistent history. Falling back to in-memory history.")
                    configureInMemoryStore()
                    loaded = persistentStoreLoader(container) == nil
                    durability = .inMemoryFallback
                    isStoreLoaded = loaded
                    return
                }

                if !loaded {
                    print("[PipelineHistoryStore] Failed to recover persistent store. Falling back to in-memory history.")
                    configureInMemoryStore()
                    loaded = persistentStoreLoader(container) == nil
                    durability = .inMemoryFallback
                    isStoreLoaded = loaded
                    return
                }
            } else {
                loaded = persistentStoreLoader(container) == nil
                if !loaded {
                    configureInMemoryStore()
                    loaded = persistentStoreLoader(container) == nil
                    durability = .inMemoryFallback
                    isStoreLoaded = loaded
                    return
                }
            }
        }

        isStoreLoaded = loaded
        durability = recoveredBackupName.map(PipelineHistoryDurability.recovered) ?? .durable
    }

    func loadAllHistory() -> [PipelineHistoryItem] {
        guard isStoreLoaded else { return [] }
        var result: [PipelineHistoryItem] = []
        container.viewContext.performAndWait {
            let request = pipelineHistoryRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            guard let entities = try? container.viewContext.fetch(request) else { return }
            result = entities.compactMap(Self.makeHistoryItem(from:))
        }
        return result
    }

    func append(_ item: PipelineHistoryItem, maxCount: Int) throws -> [DeletedPipelineHistoryAssets] {
        guard isStoreLoaded else { return [] }
        try insert(item)
        return try trim(to: maxCount)
    }

    func upsert(
        _ item: PipelineHistoryItem,
        maxCount: Int,
        requiresDurableStore: Bool = false
    ) throws -> [DeletedPipelineHistoryAssets] {
        guard isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        if requiresDurableStore, !isDurableStore {
            throw PipelineHistoryStoreError.durableStoreUnavailable
        }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
                let entity = try container.viewContext.fetch(request).first
                    ?? PipelineHistoryEntry(context: container.viewContext)
                Self.apply(item, to: entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return try trim(to: maxCount)
    }

    func update(
        _ item: PipelineHistoryItem,
        requiresDurableStore: Bool = false
    ) throws {
        guard isStoreLoaded else { return }
        if requiresDurableStore, !isDurableStore {
            throw PipelineHistoryStoreError.durableStoreUnavailable
        }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else { return }
                Self.apply(item, to: entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    func delete(
        id: UUID,
        beforeDeleting: (DeletedPipelineHistoryAssets) -> Void = { _ in }
    ) throws -> DeletedPipelineHistoryAssets? {
        guard isStoreLoaded else { return nil }

        var deletedAssets: DeletedPipelineHistoryAssets?
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else { return }
                let assets = Self.deletedAssets(from: entity)
                beforeDeleting(assets)
                deletedAssets = assets
                container.viewContext.delete(entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return deletedAssets
    }

    func clearAll(
        beforeDeleting: ([DeletedPipelineHistoryAssets]) -> Void = { _ in }
    ) throws -> [DeletedPipelineHistoryAssets] {
        guard isStoreLoaded else { return [] }

        var deletedAssets: [DeletedPipelineHistoryAssets] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                guard let entities = try? container.viewContext.fetch(request) else { return }
                deletedAssets = entities.map(Self.deletedAssets(from:))
                beforeDeleting(deletedAssets)
                for entity in entities {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return deletedAssets
    }

    func trim(
        to maxCount: Int,
        beforeDeleting: ([DeletedPipelineHistoryAssets]) -> Void = { _ in }
    ) throws -> [DeletedPipelineHistoryAssets] {
        guard isStoreLoaded else { return [] }
        guard maxCount > 0 else {
            let deletedAssets = try clearAll(beforeDeleting: beforeDeleting)
            return deletedAssets
        }

        var deletedAssets: [DeletedPipelineHistoryAssets] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                guard let entities = try? container.viewContext.fetch(request), entities.count > maxCount else { return }
                let dropped = entities[maxCount...]
                deletedAssets = dropped.map(Self.deletedAssets(from:))
                beforeDeleting(deletedAssets)
                for entity in dropped {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return deletedAssets
    }

    private func insert(_ item: PipelineHistoryItem) throws {
        guard isStoreLoaded else { return }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let context = container.viewContext
                let entity = PipelineHistoryEntry(context: context)
                Self.apply(item, to: entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    private static func apply(
        _ item: PipelineHistoryItem,
        to entity: PipelineHistoryEntry
    ) {
        entity.id = item.id
        entity.intent = item.intent.rawValue
        entity.selectedText = item.selectedText
        entity.capturedSelection = item.capturedSelection
        entity.timestamp = item.timestamp
        entity.recordingStartedAt = item.recordingStartedAt
        entity.recordingEndedAt = item.recordingEndedAt
        entity.calendarMatchJSON = encodeCalendarMatch(item.calendarMatch)
        entity.rawTranscript = item.rawTranscript
        entity.postProcessedTranscript = item.postProcessedTranscript
        entity.postProcessingPrompt = item.postProcessingPrompt
        entity.systemPrompt = item.systemPrompt
        entity.contextSummary = item.contextSummary
        entity.contextSystemPrompt = item.contextSystemPrompt
        entity.contextPrompt = item.contextPrompt
        entity.contextScreenshotDataURL = item.contextScreenshotDataURL
        entity.contextScreenshotStatus = item.contextScreenshotStatus
        entity.postProcessingStatus = item.postProcessingStatus
        entity.aiProcessingOutcome = item.aiProcessingOutcome
        entity.debugStatus = item.debugStatus
        entity.customVocabulary = item.customVocabulary
        entity.customSystemPrompt = item.customSystemPrompt
        entity.audioFileName = item.audioFileName
        entity.usedLocalTranscription = item.usedLocalTranscription
        entity.usedContextCapture = item.usedContextCapture
        entity.usedPostProcessing = item.usedPostProcessing
        entity.transcriptionLanguageCode = item.transcriptionLanguageCode
        entity.localTranscriptionModelID = item.localTranscriptionModelID
        entity.transcriptFileName = item.transcriptFileName
        entity.contextAppName = item.contextAppName
        entity.contextBundleIdentifier = item.contextBundleIdentifier
        entity.contextWindowTitle = item.contextWindowTitle
        entity.customTitle = item.customTitle
        entity.meetingSummaryJSON = item.meetingSummaryJSON
    }

    private func saveContext() throws {
        guard container.viewContext.hasChanges else { return }
        do {
            try container.viewContext.save()
        } catch {
            container.viewContext.rollback()
            throw error
        }
    }

    private func pipelineHistoryRequest() -> NSFetchRequest<PipelineHistoryEntry> {
        NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
    }

    private static func deletedAssets(from entity: PipelineHistoryEntry) -> DeletedPipelineHistoryAssets {
        DeletedPipelineHistoryAssets(
            historyID: entity.id,
            audioFileName: entity.audioFileName,
            transcriptFileName: entity.transcriptFileName
        )
    }

    private func configurePersistentStore(at storeURL: URL?) {
        if let storeURL {
            let description = NSPersistentStoreDescription(url: storeURL)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        } else {
            container.persistentStoreDescriptions = [NSPersistentStoreDescription()]
        }
    }

    private func configureInMemoryStore() {
        removeLoadedPersistentStores()
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
    }

    private func removeLoadedPersistentStores() {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private static func defaultStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let baseURL = appSupport.appendingPathComponent(
            AppName.displayName,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
        return baseURL.appendingPathComponent("PipelineHistory.sqlite")
    }

    // Safe: loadPersistentStores calls back on a private queue, not the calling thread.
    static func loadPersistentStoresSynchronously(container: NSPersistentContainer) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedError: Error?
        var remainingCompletions = max(1, container.persistentStoreDescriptions.count)

        container.loadPersistentStores { _, error in
            lock.lock()
            if capturedError == nil, let error {
                capturedError = error
            }
            remainingCompletions -= 1
            let shouldSignal = remainingCompletions <= 0
            lock.unlock()

            if shouldSignal {
                semaphore.signal()
            }
        }

        semaphore.wait()
        return capturedError
    }

    private static func moveFile(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    private static func moveSQLiteStoreFilesToRecovery(
        at storeURL: URL,
        moveItem: (URL, URL) throws -> Void
    ) throws -> String? {
        let fileManager = FileManager.default
        let components = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ].filter { fileManager.fileExists(atPath: $0.path) }
        guard !components.isEmpty else { return nil }

        let recoveryRootURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("History Recovery", isDirectory: true)
        let backupName = "\(recoveryTimestamp())-\(UUID().uuidString)"
        let backupURL = recoveryRootURL.appendingPathComponent(
            backupName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: backupURL,
            withIntermediateDirectories: true
        )

        var movedComponents: [URL] = []
        do {
            for component in components {
                try moveItem(
                    component,
                    backupURL.appendingPathComponent(component.lastPathComponent)
                )
                movedComponents.append(component)
            }
        } catch {
            for component in movedComponents.reversed() {
                let backupComponent = backupURL.appendingPathComponent(
                    component.lastPathComponent
                )
                try? moveItem(backupComponent, component)
            }
            throw error
        }
        return backupName
    }

    private static func recoveryTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func encodeCalendarMatch(_ match: CalendarEventMatch?) -> String? {
        guard let match, let data = try? JSONEncoder().encode(match) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeCalendarMatch(_ json: String?) -> CalendarEventMatch? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CalendarEventMatch.self, from: data)
    }

    private static func makeHistoryItem(from entity: PipelineHistoryEntry) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: PipelineHistoryItemIntent(rawValue: entity.intent ?? "") ?? .dictation,
            selectedText: entity.selectedText,
            capturedSelection: entity.capturedSelection,
            id: entity.id,
            timestamp: entity.timestamp ?? Date(),
            recordingStartedAt: entity.recordingStartedAt,
            recordingEndedAt: entity.recordingEndedAt,
            calendarMatch: decodeCalendarMatch(entity.calendarMatchJSON),
            rawTranscript: entity.rawTranscript ?? "",
            postProcessedTranscript: entity.postProcessedTranscript ?? "",
            postProcessingPrompt: entity.postProcessingPrompt,
            systemPrompt: entity.systemPrompt,
            contextSummary: entity.contextSummary ?? "",
            contextSystemPrompt: entity.contextSystemPrompt,
            contextPrompt: entity.contextPrompt,
            contextScreenshotDataURL: entity.contextScreenshotDataURL,
            contextScreenshotStatus: entity.contextScreenshotStatus ?? "available (image)",
            postProcessingStatus: entity.postProcessingStatus ?? "",
            aiProcessingOutcome: entity.aiProcessingOutcome ?? "succeeded",
            debugStatus: entity.debugStatus ?? "",
            customVocabulary: entity.customVocabulary ?? "",
            customSystemPrompt: entity.customSystemPrompt ?? "",
            audioFileName: entity.audioFileName,
            usedLocalTranscription: entity.usedLocalTranscription,
            usedContextCapture: entity.usedContextCapture,
            usedPostProcessing: entity.usedPostProcessing,
            transcriptionLanguageCode: entity.transcriptionLanguageCode ?? "auto",
            localTranscriptionModelID: entity.localTranscriptionModelID ?? TranscriptionModel.default.id,
            transcriptFileName: entity.transcriptFileName,
            contextAppName: entity.contextAppName,
            contextBundleIdentifier: entity.contextBundleIdentifier,
            contextWindowTitle: entity.contextWindowTitle,
            customTitle: entity.customTitle,
            meetingSummaryJSON: entity.meetingSummaryJSON
        )
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "PipelineHistoryEntry"
        entity.managedObjectClassName = NSStringFromClass(PipelineHistoryEntry.self)

        entity.properties = [
            makeAttribute(name: "intent", type: .stringAttributeType, isOptional: true, defaultValue: "dictation"),
            makeAttribute(name: "selectedText", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "capturedSelection", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "id", type: .UUIDAttributeType, isOptional: false),
            makeAttribute(name: "timestamp", type: .dateAttributeType, isOptional: false),
            makeAttribute(name: "recordingStartedAt", type: .dateAttributeType, isOptional: true),
            makeAttribute(name: "recordingEndedAt", type: .dateAttributeType, isOptional: true),
            makeAttribute(name: "calendarMatchJSON", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "rawTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessedTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "systemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextSummary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "contextSystemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotDataURL", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "aiProcessingOutcome", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "debugStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "customVocabulary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "customSystemPrompt", type: .stringAttributeType, isOptional: false, defaultValue: ""),
            makeAttribute(name: "audioFileName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "usedLocalTranscription", type: .booleanAttributeType, isOptional: false),
            makeAttribute(name: "usedContextCapture", type: .booleanAttributeType, isOptional: false),
            makeAttribute(name: "usedPostProcessing", type: .booleanAttributeType, isOptional: false),
            makeAttribute(name: "transcriptionLanguageCode", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "localTranscriptionModelID", type: .stringAttributeType, isOptional: false, defaultValue: "mlx-community/whisper-large-v3-turbo"),
            makeAttribute(name: "transcriptFileName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextAppName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextBundleIdentifier", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextWindowTitle", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "customTitle", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "meetingSummaryJSON", type: .binaryDataAttributeType, isOptional: true)
        ]

        model.entities = [entity]
        return model
    }

    private static func makeAttribute(
        name: String,
        type: NSAttributeType,
        isOptional: Bool,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        attribute.defaultValue = defaultValue
        return attribute
    }
}

@objc(PipelineHistoryEntry)
final class PipelineHistoryEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var intent: String?
    @NSManaged var selectedText: String?
    @NSManaged var capturedSelection: String?
    @NSManaged var timestamp: Date?
    @NSManaged var recordingStartedAt: Date?
    @NSManaged var recordingEndedAt: Date?
    @NSManaged var calendarMatchJSON: String?
    @NSManaged var rawTranscript: String?
    @NSManaged var postProcessedTranscript: String?
    @NSManaged var postProcessingPrompt: String?
    @NSManaged var systemPrompt: String?
    @NSManaged var contextSummary: String?
    @NSManaged var contextSystemPrompt: String?
    @NSManaged var contextPrompt: String?
    @NSManaged var contextScreenshotDataURL: String?
    @NSManaged var contextScreenshotStatus: String?
    @NSManaged var postProcessingStatus: String?
    @NSManaged var aiProcessingOutcome: String?
    @NSManaged var debugStatus: String?
    @NSManaged var customVocabulary: String?
    @NSManaged var customSystemPrompt: String?
    @NSManaged var audioFileName: String?
    @NSManaged var usedLocalTranscription: Bool
    @NSManaged var usedContextCapture: Bool
    @NSManaged var usedPostProcessing: Bool
    @NSManaged var transcriptionLanguageCode: String?
    @NSManaged var localTranscriptionModelID: String?
    @NSManaged var transcriptFileName: String?
    @NSManaged var contextAppName: String?
    @NSManaged var contextBundleIdentifier: String?
    @NSManaged var contextWindowTitle: String?
    @NSManaged var customTitle: String?
    @NSManaged var meetingSummaryJSON: Data?
}
