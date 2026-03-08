import Foundation
import FoundationModels

struct LogicalThread: Sendable {
    var state: PersistedThreadState
    var configuration: ThreadConfiguration
}

struct WindowSession: Sendable {
    var windowIndex: Int
    var handle: any SessionHandle
}

struct ContextSnapshot: Sendable {
    var instructions: String?
    var toolDescriptions: [String]
    var durableMemory: [DurableMemoryRecord]
    var retrievedMemory: [DurableMemoryRecord]
    var recentTail: [NormalizedTurn]
    var currentPrompt: String
    var schemaDescription: String?
}

struct ContextPlan: Sendable {
    var state: PersistedThreadState
    var durableMemory: [DurableMemoryRecord]
    var retrievedMemory: [DurableMemoryRecord]
    var recentTail: [NormalizedTurn]
    var currentPrompt: String
    var schemaDescription: String?
    var budget: BudgetReport
    var originalProjectedTotalTokens: Int?
    var summaryCreated: Bool = false
    var spilledBlobCount: Int = 0
    var reducersApplied: [ReducerKind] = []
    var latestCompactedState: CompactedState?
    var requiresBridge: Bool = false
}

struct PreparedRequest: Sendable {
    var thread: LogicalThread
    var plan: ContextPlan
    var bridge: BridgeReport?
}

struct SessionSeed: Sendable {
    var instructions: String?
}

enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

enum SessionFailure: Error, Sendable, Equatable {
    case exceededContextWindowSize(String)
    case unsupportedLocale(String)
    case refusal(String)
    case generationFailed(String)
}

struct SessionTextResult: Sendable, Equatable {
    var text: String
}

struct SessionStructuredResult<Content: Generable>: @unchecked Sendable {
    var content: Content
    var transcriptText: String
}

protocol SessionHandle: Sendable {
    func respondText(to prompt: String, maximumResponseTokens: Int?) async throws -> SessionTextResult
    func respondStructured<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        maximumResponseTokens: Int?
    ) async throws -> SessionStructuredResult<Content>
}

protocol SessionDriving: Sendable {
    func availability(for policy: ModelPolicy) -> ModelAvailability
    func supportsLocale(_ locale: Locale?, policy: ModelPolicy) -> Bool
    func makeSession(
        seed: SessionSeed,
        tools: [any Tool],
        policy: ModelPolicy
    ) async throws -> any SessionHandle
    func summarize(
        turns: [NormalizedTurn],
        policy: ModelPolicy,
        locale: Locale?
    ) async -> String?
}

extension PersistedThreadState {
    var locale: Locale? {
        localeIdentifier.map(Locale.init(identifier:))
    }
}
