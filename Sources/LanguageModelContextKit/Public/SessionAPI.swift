import Foundation
import FoundationModels

public typealias SessionConfiguration = ThreadConfiguration

public struct ContextSession: Sendable {
    fileprivate let runtime: LanguageModelContextKit
    public let id: String

    init(runtime: LanguageModelContextKit, id: String) {
        self.runtime = runtime
        self.id = id
    }

    public func respond(_ prompt: String) async throws -> String {
        let response = try await runtime.respond(to: prompt, threadID: id)
        return response.text
    }

    public func reply(to prompt: String) async throws -> TextReply {
        let response = try await runtime.respond(to: prompt, threadID: id)
        return response.asTextReply()
    }

    public func generate<Content: Generable>(
        _ prompt: String,
        as type: Content.Type
    ) async throws -> Content {
        let response = try await runtime.respondManaged(
            to: prompt,
            generating: type,
            threadID: id
        )
        return response.content
    }

    public func reply<Content: Generable>(
        to prompt: String,
        as type: Content.Type
    ) async throws -> GeneratedReply<Content> {
        let response = try await runtime.respondManaged(
            to: prompt,
            generating: type,
            threadID: id
        )
        return response.asGeneratedReply()
    }

    public func stream(_ prompt: String) -> AsyncThrowingStream<TextStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let upstream = await runtime.streamText(to: prompt, threadID: id)
                    for try await event in upstream {
                        continuation.yield(event.asTextStreamEvent())
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func stream<Content: Generable>(
        _ prompt: String,
        as type: Content.Type
    ) -> AsyncThrowingStream<GeneratedStreamEvent<Content>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let upstream = await runtime.streamManaged(
                        to: prompt,
                        generating: type,
                        threadID: id
                    )
                    for try await event in upstream {
                        continuation.yield(event.asGeneratedStreamEvent())
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public var inspection: SessionInspection {
        SessionInspection(runtime: runtime, id: id)
    }

    public var maintenance: SessionMaintenance {
        SessionMaintenance(runtime: runtime, id: id)
    }
}

public struct TextReply: Sendable, Equatable {
    public let text: String
    public let metadata: TurnMetadata
}

public struct GeneratedReply<Content: Generable>: @unchecked Sendable {
    public let value: Content
    public let transcriptText: String
    public let metadata: TurnMetadata
}

public struct TurnMetadata: Sendable, Equatable {
    public let compaction: CompactionReport?
    public let bridge: BridgeReport?
}

public enum TextStreamEvent: Sendable {
    case partial(String)
    case completed(TextReply)
}

public enum GeneratedStreamEvent<Content: Generable>: @unchecked Sendable {
    case partial(Content.PartiallyGenerated)
    case completed(GeneratedReply<Content>)
}

public struct SessionInspection: Sendable {
    fileprivate let runtime: LanguageModelContextKit
    public let id: String

    public func diagnostics() async -> SessionDiagnostics? {
        let diagnostics = await runtime.diagnostics(threadID: id)
        return diagnostics?.asSessionDiagnostics()
    }

    public func history() async throws -> [NormalizedTurn] {
        let state = try await runtime.threadState(threadID: id)
        return state.turns
    }

    public func durableMemory() async throws -> [DurableMemoryRecord] {
        try await runtime.durableMemories(threadID: id)
    }
}

public struct SessionMaintenance: Sendable {
    fileprivate let runtime: LanguageModelContextKit
    public let id: String

    public func compact() async throws -> CompactionReport {
        try await runtime.compact(threadID: id)
    }

    public func reset() async throws {
        try await runtime.resetThread(threadID: id)
    }

    public func importHistory(
        _ turns: [NormalizedTurn],
        durableMemory: [DurableMemoryRecord] = [],
        replaceExisting: Bool = false
    ) async throws {
        try await runtime.importHistory(
            turns,
            durableMemory: durableMemory,
            replaceExisting: replaceExisting,
            threadID: id
        )
    }

    public func appendTurns(_ turns: [NormalizedTurn]) async throws {
        try await runtime.appendTurns(turns, threadID: id)
    }

    public func appendMemory(
        _ records: [DurableMemoryRecord],
        deduplicate: Bool = true
    ) async throws {
        try await runtime.appendMemories(records, threadID: id, deduplicate: deduplicate)
    }
}

public struct SessionDiagnostics: Codable, Sendable, Equatable {
    public let sessionID: String
    public let windowIndex: Int
    public let lastCompaction: CompactionReport?
    public let lastBridge: BridgeReport?
    public let turnCount: Int
    public let durableMemoryCount: Int
    public let blobCount: Int
}

fileprivate extension ManagedTextResponse {
    func asTextReply() -> TextReply {
        TextReply(
            text: text,
            metadata: TurnMetadata(
                compaction: compaction,
                bridge: bridge
            )
        )
    }
}

fileprivate extension ManagedStructuredResponse {
    func asGeneratedReply() -> GeneratedReply<Content> {
        GeneratedReply(
            value: content,
            transcriptText: transcriptText,
            metadata: TurnMetadata(
                compaction: compaction,
                bridge: bridge
            )
        )
    }
}

fileprivate extension ManagedTextStreamEvent {
    func asTextStreamEvent() -> TextStreamEvent {
        switch self {
        case .partial(let text):
            .partial(text)
        case .completed(let response):
            .completed(response.asTextReply())
        }
    }
}

fileprivate extension ManagedStructuredStreamEvent {
    func asGeneratedStreamEvent() -> GeneratedStreamEvent<Content> {
        switch self {
        case .partial(let content, _):
            .partial(content)
        case .completed(let response):
            .completed(response.asGeneratedReply())
        }
    }
}

fileprivate extension ThreadDiagnostics {
    func asSessionDiagnostics() -> SessionDiagnostics {
        SessionDiagnostics(
            sessionID: threadID,
            windowIndex: windowIndex,
            lastCompaction: lastCompaction,
            lastBridge: lastBridge,
            turnCount: turnCount,
            durableMemoryCount: durableMemoryCount,
            blobCount: blobCount
        )
    }
}
