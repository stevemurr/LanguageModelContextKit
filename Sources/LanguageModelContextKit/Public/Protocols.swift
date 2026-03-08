import Foundation

public protocol ThreadStore: Sendable {
    func load(threadID: String) async throws -> PersistedThreadState?
    func save(_ state: PersistedThreadState, threadID: String) async throws
    func delete(threadID: String) async throws
}

public protocol MemoryStore: Sendable {
    func load(threadID: String) async throws -> [DurableMemoryRecord]
    func save(_ records: [DurableMemoryRecord], threadID: String) async throws
    func append(_ record: DurableMemoryRecord, threadID: String) async throws
    func deleteAll(threadID: String) async throws
}

public protocol BlobStore: Sendable {
    func put(_ data: Data) async throws -> UUID
    func get(_ id: UUID) async throws -> Data?
    func delete(_ id: UUID) async throws
}

public protocol Retriever: Sendable {
    func retrieve(
        query: String,
        threadID: String,
        limit: Int
    ) async throws -> [DurableMemoryRecord]
}
