import Foundation
import FoundationModels

public struct ContextManagerConfiguration: Sendable {
    public var budget: BudgetPolicy
    public var compaction: CompactionPolicy
    public var memory: MemoryPolicy
    public var persistence: PersistencePolicy
    public var diagnostics: DiagnosticsPolicy

    public init(
        budget: BudgetPolicy = .default,
        compaction: CompactionPolicy = .default,
        memory: MemoryPolicy = .default,
        persistence: PersistencePolicy = .default,
        diagnostics: DiagnosticsPolicy = .default
    ) {
        self.budget = budget
        self.compaction = compaction
        self.memory = memory
        self.persistence = persistence
        self.diagnostics = diagnostics
    }

    public static var `default`: ContextManagerConfiguration {
        ContextManagerConfiguration()
    }
}

public struct ThreadConfiguration: Sendable {
    public var instructions: String?
    public var locale: Locale?
    public var model: ModelPolicy
    public var tools: [any Tool]

    public init(
        instructions: String? = nil,
        locale: Locale? = nil,
        model: ModelPolicy = .default,
        tools: [any Tool] = []
    ) {
        self.instructions = instructions
        self.locale = locale
        self.model = model
        self.tools = tools
    }
}

public struct ModelPolicy: Codable, Sendable, Equatable {
    public enum UseCase: String, Codable, Sendable {
        case general
        case contentTagging
    }

    public enum Guardrails: String, Codable, Sendable {
        case `default`
        case permissiveContentTransformations
    }

    public var useCase: UseCase
    public var guardrails: Guardrails

    public init(
        useCase: UseCase = .general,
        guardrails: Guardrails = .default
    ) {
        self.useCase = useCase
        self.guardrails = guardrails
    }

    public static let `default` = ModelPolicy()
}

public struct BudgetPolicy: Sendable, Equatable {
    public var reservedOutputTokens: Int
    public var preemptiveCompactionFraction: Double
    public var emergencyFraction: Double
    public var maxBridgeRetries: Int
    public var exactCountingPreferred: Bool
    public var heuristicSafetyMultiplier: Double
    public var defaultContextWindowTokens: Int

    public init(
        reservedOutputTokens: Int = 768,
        preemptiveCompactionFraction: Double = 0.78,
        emergencyFraction: Double = 0.90,
        maxBridgeRetries: Int = 2,
        exactCountingPreferred: Bool = true,
        heuristicSafetyMultiplier: Double = 1.10,
        defaultContextWindowTokens: Int = 4096
    ) {
        self.reservedOutputTokens = reservedOutputTokens
        self.preemptiveCompactionFraction = preemptiveCompactionFraction
        self.emergencyFraction = emergencyFraction
        self.maxBridgeRetries = maxBridgeRetries
        self.exactCountingPreferred = exactCountingPreferred
        self.heuristicSafetyMultiplier = heuristicSafetyMultiplier
        self.defaultContextWindowTokens = defaultContextWindowTokens
    }

    public static let `default` = BudgetPolicy()
}

public struct CompactionPolicy: Sendable, Equatable {
    public var mode: CompactionMode
    public var maxRecentTurns: Int
    public var chunkTargetTokens: Int
    public var chunkSummaryTargetTokens: Int
    public var maxMergeDepth: Int

    public init(
        mode: CompactionMode = .hybrid,
        maxRecentTurns: Int = 8,
        chunkTargetTokens: Int = 1200,
        chunkSummaryTargetTokens: Int = 160,
        maxMergeDepth: Int = 3
    ) {
        self.mode = mode
        self.maxRecentTurns = maxRecentTurns
        self.chunkTargetTokens = chunkTargetTokens
        self.chunkSummaryTargetTokens = chunkSummaryTargetTokens
        self.maxMergeDepth = maxMergeDepth
    }

    public static let `default` = CompactionPolicy()
}

public struct MemoryPolicy: Sendable, Equatable {
    public var automaticallyExtractMemories: Bool
    public var retrievalLimit: Int
    public var inlineBlobByteLimit: Int

    public init(
        automaticallyExtractMemories: Bool = true,
        retrievalLimit: Int = 5,
        inlineBlobByteLimit: Int = 2048
    ) {
        self.automaticallyExtractMemories = automaticallyExtractMemories
        self.retrievalLimit = retrievalLimit
        self.inlineBlobByteLimit = inlineBlobByteLimit
    }

    public static let `default` = MemoryPolicy()
}

public struct PersistencePolicy: Sendable {
    public var threads: any ThreadStore
    public var memories: any MemoryStore
    public var blobs: any BlobStore
    public var retriever: (any Retriever)?

    public init(
        threads: any ThreadStore,
        memories: any MemoryStore,
        blobs: any BlobStore,
        retriever: (any Retriever)? = nil
    ) {
        self.threads = threads
        self.memories = memories
        self.blobs = blobs
        self.retriever = retriever
    }

    public static var `default`: PersistencePolicy {
        PersistencePolicy(
            threads: InMemoryThreadStore(),
            memories: InMemoryMemoryStore(),
            blobs: InMemoryBlobStore(),
            retriever: nil
        )
    }
}

public struct DiagnosticsPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var logToOSLog: Bool

    public init(
        isEnabled: Bool = true,
        logToOSLog: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.logToOSLog = logToOSLog
    }

    public static let `default` = DiagnosticsPolicy()
}

public enum CompactionMode: String, Codable, Sendable {
    case slidingWindow
    case structuredSummary
    case hybrid
}

public struct ManagedTextResponse: Sendable {
    public let text: String
    public let budget: BudgetReport
    public let compaction: CompactionReport?
    public let bridge: BridgeReport?

    public init(
        text: String,
        budget: BudgetReport,
        compaction: CompactionReport?,
        bridge: BridgeReport?
    ) {
        self.text = text
        self.budget = budget
        self.compaction = compaction
        self.bridge = bridge
    }
}

public struct BudgetReport: Codable, Sendable, Equatable {
    public enum Accuracy: String, Codable, Sendable {
        case exact
        case approximate
    }

    public let accuracy: Accuracy
    public let contextWindowTokens: Int
    public let estimatedInputTokens: Int
    public let reservedOutputTokens: Int
    public let projectedTotalTokens: Int
    public let softLimitTokens: Int
    public let emergencyLimitTokens: Int
    public let breakdown: [BudgetComponent: Int]

    public init(
        accuracy: Accuracy,
        contextWindowTokens: Int,
        estimatedInputTokens: Int,
        reservedOutputTokens: Int,
        projectedTotalTokens: Int,
        softLimitTokens: Int,
        emergencyLimitTokens: Int,
        breakdown: [BudgetComponent: Int]
    ) {
        self.accuracy = accuracy
        self.contextWindowTokens = contextWindowTokens
        self.estimatedInputTokens = estimatedInputTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.projectedTotalTokens = projectedTotalTokens
        self.softLimitTokens = softLimitTokens
        self.emergencyLimitTokens = emergencyLimitTokens
        self.breakdown = breakdown
    }
}

public enum BudgetComponent: String, Codable, Sendable, Hashable, CaseIterable {
    case instructions
    case tools
    case durableMemory
    case retrievedMemory
    case recentTail
    case currentPrompt
    case schema
    case outputReserve
    case other
}

public struct CompactionReport: Codable, Sendable, Equatable {
    public let mode: CompactionMode
    public let tokensBefore: Int
    public let tokensAfter: Int
    public let reducersApplied: [ReducerKind]
    public let summaryCreated: Bool
    public let spilledBlobCount: Int

    public init(
        mode: CompactionMode,
        tokensBefore: Int,
        tokensAfter: Int,
        reducersApplied: [ReducerKind],
        summaryCreated: Bool,
        spilledBlobCount: Int
    ) {
        self.mode = mode
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.reducersApplied = reducersApplied
        self.summaryCreated = summaryCreated
        self.spilledBlobCount = spilledBlobCount
    }
}

public enum ReducerKind: String, Codable, Sendable {
    case toolPayloadDigester
    case dropLowPriorityRetrievedMemory
    case slidingTail
    case structuredSummary
    case aggressiveSummary
    case emergencyReset
}

public struct BridgeReport: Codable, Sendable, Equatable {
    public let fromWindowIndex: Int
    public let toWindowIndex: Int
    public let reason: String
    public let carriedTurnCount: Int
    public let summaryUsed: Bool

    public init(
        fromWindowIndex: Int,
        toWindowIndex: Int,
        reason: String,
        carriedTurnCount: Int,
        summaryUsed: Bool
    ) {
        self.fromWindowIndex = fromWindowIndex
        self.toWindowIndex = toWindowIndex
        self.reason = reason
        self.carriedTurnCount = carriedTurnCount
        self.summaryUsed = summaryUsed
    }
}

public struct ThreadDiagnostics: Codable, Sendable, Equatable {
    public let threadID: String
    public let windowIndex: Int
    public let lastBudget: BudgetReport?
    public let lastCompaction: CompactionReport?
    public let lastBridge: BridgeReport?
    public let turnCount: Int
    public let durableMemoryCount: Int
    public let blobCount: Int

    public init(
        threadID: String,
        windowIndex: Int,
        lastBudget: BudgetReport?,
        lastCompaction: CompactionReport?,
        lastBridge: BridgeReport?,
        turnCount: Int,
        durableMemoryCount: Int,
        blobCount: Int
    ) {
        self.threadID = threadID
        self.windowIndex = windowIndex
        self.lastBudget = lastBudget
        self.lastCompaction = lastCompaction
        self.lastBridge = lastBridge
        self.turnCount = turnCount
        self.durableMemoryCount = durableMemoryCount
        self.blobCount = blobCount
    }
}

public struct NormalizedTurn: Codable, Sendable, Identifiable, Equatable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case tool
        case system
        case summary
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let createdAt: Date
    public let priority: Int
    public let tags: [String]
    public let blobIDs: [UUID]
    public let windowIndex: Int
    public let compacted: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        priority: Int,
        tags: [String] = [],
        blobIDs: [UUID] = [],
        windowIndex: Int,
        compacted: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.priority = priority
        self.tags = tags
        self.blobIDs = blobIDs
        self.windowIndex = windowIndex
        self.compacted = compacted
    }
}

public struct DurableMemoryRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case fact
        case constraint
        case decision
        case openTask
        case summary
        case blobRef
    }

    public let id: UUID
    public let kind: Kind
    public let text: String
    public let createdAt: Date
    public let priority: Int
    public let tags: [String]
    public let blobIDs: [UUID]
    public let pinned: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        createdAt: Date = Date(),
        priority: Int,
        tags: [String] = [],
        blobIDs: [UUID] = [],
        pinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.priority = priority
        self.tags = tags
        self.blobIDs = blobIDs
        self.pinned = pinned
    }
}

public struct PersistedThreadState: Codable, Sendable, Equatable {
    public let threadID: String
    public var instructions: String?
    public var localeIdentifier: String?
    public var model: ModelPolicy
    public var activeWindowIndex: Int
    public var turns: [NormalizedTurn]
    public var lastBudget: BudgetReport?
    public var lastCompaction: CompactionReport?
    public var lastBridge: BridgeReport?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        threadID: String,
        instructions: String?,
        localeIdentifier: String?,
        model: ModelPolicy,
        activeWindowIndex: Int = 0,
        turns: [NormalizedTurn] = [],
        lastBudget: BudgetReport? = nil,
        lastCompaction: CompactionReport? = nil,
        lastBridge: BridgeReport? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.instructions = instructions
        self.localeIdentifier = localeIdentifier
        self.model = model
        self.activeWindowIndex = activeWindowIndex
        self.turns = turns
        self.lastBudget = lastBudget
        self.lastCompaction = lastCompaction
        self.lastBridge = lastBridge
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CompactedState: Codable, Sendable, Equatable {
    public var stableFacts: [StableFact]
    public var userConstraints: [String]
    public var openTasks: [OpenTask]
    public var decisions: [Decision]
    public var entities: [EntityRef]
    public var blobReferences: [BlobReference]
    public var retrievalHints: [String]

    public init(
        stableFacts: [StableFact] = [],
        userConstraints: [String] = [],
        openTasks: [OpenTask] = [],
        decisions: [Decision] = [],
        entities: [EntityRef] = [],
        blobReferences: [BlobReference] = [],
        retrievalHints: [String] = []
    ) {
        self.stableFacts = stableFacts
        self.userConstraints = userConstraints
        self.openTasks = openTasks
        self.decisions = decisions
        self.entities = entities
        self.blobReferences = blobReferences
        self.retrievalHints = retrievalHints
    }
}

public struct StableFact: Codable, Sendable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct OpenTask: Codable, Sendable, Equatable {
    public var description: String
    public var status: String

    public init(description: String, status: String) {
        self.description = description
        self.status = status
    }
}

public struct Decision: Codable, Sendable, Equatable {
    public var summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

public struct EntityRef: Codable, Sendable, Equatable {
    public var name: String
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

public struct BlobReference: Codable, Sendable, Equatable {
    public var id: UUID
    public var reason: String

    public init(id: UUID, reason: String) {
        self.id = id
        self.reason = reason
    }
}

public enum LanguageModelContextKitError: Error, Sendable, Equatable {
    case threadNotFound(String)
    case modelUnavailable(String)
    case unsupportedLocale(String)
    case exceededBudget(BudgetReport)
    case budgetExhausted(ThreadDiagnostics)
    case refusal(String)
    case generationFailed(String)
    case persistenceFailed(String)
}
