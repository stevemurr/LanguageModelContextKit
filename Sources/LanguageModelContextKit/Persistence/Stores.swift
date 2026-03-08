import Foundation

public actor InMemoryThreadStore: ThreadStore {
    private var storage: [String: PersistedThreadState] = [:]

    public init() {}

    public func load(threadID: String) async throws -> PersistedThreadState? {
        storage[threadID]
    }

    public func save(_ state: PersistedThreadState, threadID: String) async throws {
        storage[threadID] = state
    }

    public func delete(threadID: String) async throws {
        storage.removeValue(forKey: threadID)
    }
}

public actor FileThreadStore: ThreadStore {
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    public func load(threadID: String) async throws -> PersistedThreadState? {
        let url = fileURL(for: threadID)
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(PersistedThreadState.self, from: data)
    }

    public func save(_ state: PersistedThreadState, threadID: String) async throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: fileURL(for: threadID), options: .atomic)
    }

    public func delete(threadID: String) async throws {
        let url = fileURL(for: threadID)
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for threadID: String) -> URL {
        directoryURL.appendingPathComponent(StorageKey.filename(threadID)).appendingPathExtension("json")
    }
}

public actor InMemoryMemoryStore: MemoryStore {
    private var storage: [String: [DurableMemoryRecord]] = [:]

    public init() {}

    public func load(threadID: String) async throws -> [DurableMemoryRecord] {
        storage[threadID] ?? []
    }

    public func save(_ records: [DurableMemoryRecord], threadID: String) async throws {
        storage[threadID] = records
    }

    public func append(_ record: DurableMemoryRecord, threadID: String) async throws {
        storage[threadID, default: []].append(record)
    }

    public func deleteAll(threadID: String) async throws {
        storage.removeValue(forKey: threadID)
    }
}

public actor FileMemoryStore: MemoryStore {
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    public func load(threadID: String) async throws -> [DurableMemoryRecord] {
        let url = fileURL(for: threadID)
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([DurableMemoryRecord].self, from: data)
    }

    public func save(_ records: [DurableMemoryRecord], threadID: String) async throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(records)
        try data.write(to: fileURL(for: threadID), options: .atomic)
    }

    public func append(_ record: DurableMemoryRecord, threadID: String) async throws {
        var records = try await load(threadID: threadID)
        records.append(record)
        try await save(records, threadID: threadID)
    }

    public func deleteAll(threadID: String) async throws {
        let url = fileURL(for: threadID)
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for threadID: String) -> URL {
        directoryURL.appendingPathComponent(StorageKey.filename(threadID)).appendingPathExtension("json")
    }
}

public actor InMemoryBlobStore: BlobStore {
    private var storage: [UUID: Data] = [:]

    public init() {}

    public func put(_ data: Data) async throws -> UUID {
        let id = UUID()
        storage[id] = data
        return id
    }

    public func get(_ id: UUID) async throws -> Data? {
        storage[id]
    }

    public func delete(_ id: UUID) async throws {
        storage.removeValue(forKey: id)
    }
}

public actor FileBlobStore: BlobStore {
    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func put(_ data: Data) async throws -> UUID {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let id = UUID()
        try data.write(to: fileURL(for: id), options: .atomic)
        return id
    }

    public func get(_ id: UUID) async throws -> Data? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    public func delete(_ id: UUID) async throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("blob")
    }
}

enum StorageKey {
    static func filename(_ input: String) -> String {
        let data = Data(input.utf8).base64EncodedString()
        return data
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
