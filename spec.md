I'll update the library name from `FoundationContextManager` to `LanguageModelContextKit` throughout the spec:

---

Below is a handoff spec you can paste directly into a coding agent.

Apple's current Foundation Models surface is enough to support this library, but it leaves long-context management to the app. The public framework exposes Apple's **on-device** model through Swift APIs on macOS, iOS, iPadOS, and visionOS; Apple describes that model as optimized for summarization, extraction, refinement, and short dialog rather than broad world knowledge or advanced reasoning. Sessions are stateful, every `respond` call is recorded in a transcript, and the current on-device session window is **4,096 tokens**. When a session overflows, Apple recommends creating a new session and carrying forward selected transcript entries or a summary. ([Apple Machine Learning Research][1])

Newer Foundation Models SDKs also expose token-budgeting primitives such as `contextSize`, `tokenCount(for:)`, and `tokenUsage(for:)`. Apple also notes that instructions, tools, prompts, generated output, and schema material all consume context, and that `includeSchemaInPrompt` can sometimes be disabled to reduce token usage when the response format is already well established. ([Apple Developer][2])

Apple does **not** currently provide a built-in embeddings model for RAG in Foundation Models; Apple points developers to Natural Language embeddings or Core ML for that layer. Availability and locale support also need to be handled explicitly, including unavailable-model states and `unsupportedLanguageOrLocale` errors. ([Apple Developer][3])

This design intentionally follows the same broad pattern as existing long-context work: hierarchical memory / virtual context management and prompt compression. That pattern also already exists in early Swift community work around Foundation Models token-limit handling. ([Swift Forums][4])

---

# Implementation Spec: `LanguageModelContextKit`

## 1. Goal

Build a Swift package that adds a **context-management layer** on top of Apple Foundation Models / Apple Intelligence.

The package must provide:

1. token counting / budget reporting
2. automatic context compaction
3. automatic bridging across multiple Foundation Models context windows
4. durable thread state that outlives any single `LanguageModelSession`
5. a clean Swift-first API suitable for app integration

This is a **library**, not a UI framework.

## 2. Product definition

### 2.1 What this package is

A stateful wrapper around Foundation Models that lets app code interact with a **logical conversation thread** while the library transparently manages one or more underlying `LanguageModelSession` windows.

### 2.2 What this package is not

Do **not** build:

* a general-purpose chat UI
* a cloud LLM abstraction layer
* a full vector database
* a magical "infinite memory" system with opaque behavior
* a dependency-heavy framework

V1 should be Apple-first and practical.

## 3. Design principles

1. **Transcript is cache, not truth.**
   `LanguageModelSession` transcript is useful, but the library's source of truth must be its own normalized turn log and durable memory records.

2. **Prefer deterministic reduction over magic.**
   Compaction should be explainable, inspectable, and logged.

3. **Prefer extraction over prose summarization.**
   Preserve facts, entities, decisions, constraints, and open tasks as structured state.

4. **Never depend on one huge session.**
   A logical thread may span many Foundation Models sessions.

5. **Budget pessimistically.**
   Underestimation is worse than overestimation.

6. **Graceful degradation matters.**
   Exact token APIs may not exist on every supported runtime; the library must still work.

## 4. Deliverable

Create a SwiftPM package named:

`LanguageModelContextKit`

Main public entrypoint:

`LanguageModelContextKit`

Optional secondary target for Natural Language retrieval helpers:

`LanguageModelContextKitNL`

## 5. Package structure

Use this layout:

```text
Package.swift
Sources/
  LanguageModelContextKit/
    Public/
    Core/
    Budgeting/
    Compaction/
    Bridging/
    Memory/
    Persistence/
    Diagnostics/
    AppleAdapter/
  LanguageModelContextKitNL/           // optional target
Examples/
  ChatExample/
Tests/
  LanguageModelContextKitTests/
  LanguageModelContextKitIntegrationTests/
```

## 6. Core architecture

### 6.1 Main concepts

Implement these internal concepts:

* `LogicalThread`
* `WindowSession`
* `ThreadState`
* `NormalizedTurn`
* `DurableMemoryRecord`
* `BlobRecord`
* `ContextSnapshot`
* `ContextPlan`
* `BudgetReport`
* `CompactionReport`
* `BridgeReport`
* `ThreadDiagnostics`

### 6.2 High-level flow

For every request:

1. load thread state
2. check model availability / locale support
3. build a context snapshot from:

   * stable instructions
   * durable memory
   * recent tail
   * retrieved memories
   * current prompt
4. estimate token usage
5. if usage exceeds soft budget, compact
6. run request against active session or a new bridged session
7. on success:

   * capture turn
   * update recent tail
   * optionally extract memory
8. on `exceededContextWindowSize`:

   * emergency compact
   * start a fresh session
   * retry
9. persist updated state and diagnostics

## 7. Public API

Implement a clean public API roughly like this:

```swift
import Foundation
import FoundationModels

public struct ContextManagerConfiguration: Sendable {
    public var budgetPolicy: BudgetPolicy
    public var compactionPolicy: CompactionPolicy
    public var memoryPolicy: MemoryPolicy
    public var persistence: PersistencePolicy
    public var diagnostics: DiagnosticsPolicy
}

public struct ThreadConfiguration: Sendable {
    public var instructions: Instructions?
    public var locale: Locale?
    public var tools: [any Tool]
}

public struct BudgetPolicy: Sendable {
    public var reservedOutputTokens: Int
    public var preemptiveCompactionFraction: Double
    public var emergencyFraction: Double
    public var maxBridgeRetries: Int
    public var exactCountingPreferred: Bool
}

public struct ManagedTextResponse: Sendable {
    public let text: String
    public let budget: BudgetReport
    public let compaction: CompactionReport?
    public let bridge: BridgeReport?
}

public struct BudgetReport: Sendable {
    public enum Accuracy: Sendable { case exact, approximate }
    public let accuracy: Accuracy
    public let contextSize: Int
    public let estimatedInputTokens: Int
    public let reservedOutputTokens: Int
    public let projectedTotalTokens: Int
    public let breakdown: [BudgetComponent: Int]
}

public enum BudgetComponent: String, Sendable {
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

public actor LanguageModelContextKit {
    public init(configuration: ContextManagerConfiguration)

    public func createThread(
        id: String,
        configuration: ThreadConfiguration
    ) async throws

    public func estimateBudget(
        for prompt: String,
        threadID: String
    ) async throws -> BudgetReport

    public func respond(
        to prompt: String,
        threadID: String
    ) async throws -> ManagedTextResponse

    public func respond<T: Generable>(
        to prompt: String,
        generating type: T.Type,
        threadID: String,
        includeSchemaInPrompt: Bool?
    ) async throws -> T

    public func compact(
        threadID: String
    ) async throws -> CompactionReport

    public func diagnostics(
        threadID: String
    ) async -> ThreadDiagnostics?

    public func resetThread(
        threadID: String
    ) async throws
}
```

### 7.1 Notes on tools

Support `tools: [any Tool]` if it compiles cleanly with the installed SDK.

If existential `Tool` handling becomes awkward, switch `ThreadConfiguration` to a session-builder closure:

```swift
public var makeSession: @Sendable (_ seed: SessionSeed) async throws -> LanguageModelSession
```

Do **not** let tool-type ergonomics block the rest of the implementation.

## 8. Thread model

### 8.1 Logical thread vs window session

A **logical thread** is the app-facing conversation/task history.

A **window session** is one Foundation Models `LanguageModelSession` backing part of that thread.

One logical thread can span many window sessions.

### 8.2 Thread state

Each thread must store:

* thread ID
* base instructions
* optional locale hint
* active window index
* active in-memory session
* normalized turn log
* durable memory store references
* blob references for spilled large payloads
* last budget report
* bridge history
* compaction history

### 8.3 Persistence rule

Persist the library's own normalized records.

Do **not** require Foundation `Transcript` to be serializable or persistable.

Treat Foundation transcript as an in-process optimization only.

## 9. Normalized turn model

Implement a normalized, Codable representation:

```swift
public struct NormalizedTurn: Codable, Sendable, Identifiable {
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
}
```

Rules:

* Every successful request must append a user turn and assistant turn.
* Large tool-like or generated payloads should be spillable into `BlobRecord`.
* Summary turns are synthetic and owned by the library.

## 10. Token budgeting subsystem

## 10.1 Requirements

The library must expose **two modes**:

1. **Exact counting** when the runtime exposes official token APIs.
2. **Approximate counting** fallback otherwise.

### 10.2 Exact counting

Create a `TokenCounter` abstraction.

Implement `AppleExactTokenCounter` using current Foundation Models token APIs when available:

* `contextSize`
* `tokenCount(for:)`
* `tokenUsage(for:)`

The counter must return a breakdown for:

* instructions
* tools
* prompt
* recent tail
* durable memory
* retrieved memory
* schema
* reserved output

### 10.3 Approximate counting

Implement `HeuristicTokenCounter` as fallback.

Requirements:

* prefer overestimation
* include message overhead
* estimate from UTF-8 byte length plus word-token heuristic
* optionally use `NLTokenizer` when `NaturalLanguage` is available
* expose `accuracy = .approximate`

Recommended formula:

```swift
estimate = max(
    ceil(Double(utf8ByteCount) / 4.0),
    ceil(Double(wordCount) * 1.35)
) + perMessageOverhead
```

Recommended defaults:

* `perMessageOverhead = 6`
* apply a configurable safety multiplier, default `1.10`

## 10.4 Budget policy defaults

Default v1 values:

```swift
reservedOutputTokens = 768
preemptiveCompactionFraction = 0.78
emergencyFraction = 0.90
maxBridgeRetries = 2
exactCountingPreferred = true
```

The library must also adapt to future context sizes by using runtime `contextSize` when available instead of hard-coding 4096.

## 11. Compaction subsystem

## 11.1 Required compaction modes

Implement these modes:

1. `slidingWindow`
2. `structuredSummary`
3. `hybrid` (default)

### 11.2 Built-in reducer chain

Implement reducers in this order:

1. `ToolPayloadDigesterReducer`
2. `DropLowPriorityRetrievedMemoryReducer`
3. `SlidingTailReducer`
4. `StructuredSummaryReducer`
5. `AggressiveSummaryReducer`
6. `EmergencyResetReducer`

Each reducer must be:

* async
* deterministic given the same input plan
* logged
* independently testable

### 11.3 Priority model

Every context item must have a priority.

Recommended defaults:

* base instructions: `1000`
* current user prompt: `950`
* pinned facts / user constraints: `900`
* open tasks / unresolved questions: `860`
* last assistant answer: `800`
* recent user/assistant turns: `700`
* retrieved historical memory: `600`
* older summaries: `500`
* raw tool payload: `250`

Reducers must compact lowest-priority material first.

## 11.4 Structured summary schema

Compaction must prefer structured extraction over freeform summary.

Implement an internal summary schema like:

```swift
public struct CompactedState: Codable, Sendable {
    public var stableFacts: [StableFact]
    public var userConstraints: [String]
    public var openTasks: [OpenTask]
    public var decisions: [Decision]
    public var entities: [EntityRef]
    public var blobReferences: [BlobReference]
    public var retrievalHints: [String]
}

public struct StableFact: Codable, Sendable {
    public var key: String
    public var value: String
}

public struct OpenTask: Codable, Sendable {
    public var description: String
    public var status: String
}

public struct Decision: Codable, Sendable {
    public var summary: String
}

public struct EntityRef: Codable, Sendable {
    public var name: String
    public var type: String
}

public struct BlobReference: Codable, Sendable {
    public var id: UUID
    public var reason: String
}
```

In the Apple adapter, provide a `@Generable` version of this schema for internal use by Foundation Models.

## 11.5 Summary prompt template

Use a dedicated compaction prompt template.

Required prompt intent:

* preserve stable facts
* preserve user preferences and constraints
* preserve decisions
* preserve unresolved work
* preserve named entities and identifiers
* preserve conclusions from tool results
* omit chit-chat, repetition, filler, and stylistic wording
* do not invent facts

Use a **separate summarizer session** for compaction.

Do not summarize inside the already-full active user session.

## 11.6 Hierarchical compaction

If old material is itself too large to summarize in one pass:

1. split into chunks by estimated token size
2. summarize each chunk
3. summarize the chunk summaries
4. persist the merged summary
5. retire old raw turns from active context

Recommended defaults:

* chunk target: `<= 1200` estimated tokens
* chunk-summary target: `<= 160` estimated tokens
* max merge depth: `3`

## 11.7 Fallback if structured summary fails

If structured generation fails due to decoding or similar issues:

1. retry once with greedy sampling and the same schema
2. if it still fails, fallback to plain-text compact summary
3. still persist a machine-readable wrapper with the plain text inside

Never let one structured-summary failure break the thread.

## 12. Bridging multiple context windows

## 12.1 Objective

When a single `LanguageModelSession` becomes too full, the library must open a new session while preserving enough prior state for continuity.

## 12.2 Bridge seed

A new bridged window should be built from:

1. original instructions
2. pinned durable memory
3. current compacted summary
4. a small recent normalized tail
5. current prompt

## 12.3 Transcript carryover

When practical, carry forward relevant transcript entries into the new session.

At minimum, always preserve the original instructions.

If exact transcript-entry construction or manipulation is awkward in the public API, do **not** block on it. Fall back to:

* fresh session
* original instructions
* synthetic bridge context rendered as text
* recent tail rendered from normalized turns

## 12.4 Bridge algorithm

Implement:

```text
build snapshot
estimate
compact if needed
attempt response
if exceededContextWindowSize:
    mark emergency mode
    build new bridge seed
    create fresh session
    retry
if still exceeds after max retries:
    throw budgetExhausted with diagnostics
```

## 12.5 Bridge report

Return structured bridge metadata:

```swift
public struct BridgeReport: Sendable {
    public let fromWindowIndex: Int
    public let toWindowIndex: Int
    public let reason: String
    public let carriedTurnCount: Int
    public let summaryUsed: Bool
}
```

## 13. Durable memory subsystem

## 13.1 Requirements

Implement a simple durable memory layer separate from Foundation transcript.

Memory categories:

* `fact`
* `constraint`
* `decision`
* `openTask`
* `summary`
* `blobRef`

## 13.2 Store protocol

```swift
public protocol MemoryStore: Sendable {
    func load(threadID: String) async throws -> [DurableMemoryRecord]
    func save(_ records: [DurableMemoryRecord], threadID: String) async throws
    func append(_ record: DurableMemoryRecord, threadID: String) async throws
    func deleteAll(threadID: String) async throws
}
```

Provide:

* `InMemoryMemoryStore`
* `FileMemoryStore`

File store can be JSON-backed for v1.

## 13.3 Blob store

Implement a blob store for oversized payloads.

Use it for:

* large tool outputs
* large retrieved documents
* large assistant outputs that should not stay inline

Blob store protocol:

```swift
public protocol BlobStore: Sendable {
    func put(_ data: Data) async throws -> UUID
    func get(_ id: UUID) async throws -> Data?
    func delete(_ id: UUID) async throws
}
```

Provide in-memory and file-backed versions.

## 14. Retrieval subsystem

Because Foundation Models has no built-in embeddings layer, design retrieval as optional and swappable. Default to simple retrieval first; add Natural Language embeddings as an optional adapter. ([Apple Developer][3])

### 14.1 Retriever protocol

```swift
public protocol Retriever: Sendable {
    func retrieve(
        query: String,
        threadID: String,
        limit: Int
    ) async throws -> [DurableMemoryRecord]
}
```

Provide:

* `KeywordRetriever` in core
* `NLEmbeddingRetriever` in optional `LanguageModelContextKitNL` target

### 14.2 Retrieval rules

* retrieval is optional in v1
* retrieval results must be budgeted like any other context
* low-priority retrieved items are first to drop during compaction

## 15. Apple adapter details

## 15.1 Availability handling

Before any request:

1. inspect model availability
2. surface typed errors for:

   * model unavailable
   * device not eligible
   * Apple Intelligence not enabled
   * model not ready
   * unsupported language / locale

Create:

```swift
public enum LanguageModelContextKitError: Error, Sendable {
    case modelUnavailable(String)
    case unsupportedLocale(String)
    case exceededBudget(BudgetReport)
    case budgetExhausted(ThreadDiagnostics)
    case refusal(String)
    case generationFailed(String)
    case persistenceFailed(String)
}
```

## 15.2 Sampling for internal reducers

For compaction / extraction tasks, use **greedy** sampling for determinism where possible. Apple notes greedy mode is deterministic for the same prompt and session state on a given model version, though outputs can still change across OS model updates. Build tests accordingly. ([Apple Developer][5])

## 15.3 Schema prompt optimization

Treat `includeSchemaInPrompt = true` as the safe default for internal structured compaction.

Add an optimization path:

* first request for a schema: `true`
* later requests in same warmed session or when instructions include a full representative example: allow `false`

Correctness first, optimization second.

## 16. Diagnostics and observability

Implement structured diagnostics for every send.

### 16.1 Diagnostics payload

```swift
public struct ThreadDiagnostics: Codable, Sendable {
    public let threadID: String
    public let windowIndex: Int
    public let lastBudget: BudgetReport?
    public let lastCompaction: CompactionReport?
    public let lastBridge: BridgeReport?
    public let turnCount: Int
    public let durableMemoryCount: Int
    public let blobCount: Int
}
```

### 16.2 Logging

Use `OSLog` categories:

* `budget`
* `compaction`
* `bridge`
* `memory`
* `errors`

Every compaction event must log:

* tokens before
* tokens after
* reducers applied
* whether summary was created
* whether bridge occurred

## 17. Testing requirements

## 17.1 Unit tests

Must include unit tests for:

* exact token counter wrapper
* heuristic token counter
* priority sorting
* reducer chain behavior
* blob spill / restore
* memory store persistence
* bridge planning
* diagnostics generation

## 17.2 Integration tests

Add integration tests gated on runtime availability for real Foundation Models.

Scenarios:

1. short thread, no compaction
2. long thread that triggers preemptive compaction
3. forced overflow that triggers emergency bridge
4. structured compaction
5. unsupported locale / unavailable model path

## 17.3 Golden tests

Create a `Tests/Fixtures` folder with normalized transcripts and expected compacted state.

Assertions should check:

* facts preserved
* constraints preserved
* open tasks preserved
* no duplicate facts
* no raw blob payloads left inline after digestion

Do **not** assert exact assistant prose for real-model integration tests.

## 17.4 Acceptance tests

V1 is done when all of the following are true:

1. `estimateBudget` returns a usable `BudgetReport` before send.
2. The manager can carry a logical thread across at least **3 bridged windows** without uncaught overflow.
3. Explicit user constraints and decisions survive compaction in golden tests.
4. Large payloads spill to blob store and are represented inline only by digests / references.
5. Real-model tests either pass on supported devices or skip cleanly when unavailable.
6. README example compiles.

## 18. README and example app

Ship:

1. README with:

   * installation
   * quick start
   * long-thread example
   * manual compaction example
   * diagnostics example

2. Small example app:

   * create thread
   * show budget before send
   * continue across multiple windows
   * inspect diagnostics

## 19. Implementation order

Agent should build in this order:

### Phase 1

* package skeleton
* public API
* thread state
* normalized turn model
* in-memory persistence
* heuristic token counter
* simple sliding window compaction

### Phase 2

* exact token counter wrapper
* bridge logic
* emergency retry on overflow
* diagnostics and logging

### Phase 3

* structured compaction
* dedicated summarizer session
* file-backed persistence
* blob store

### Phase 4

* retrieval abstraction
* keyword retriever
* optional Natural Language embedding retriever

### Phase 5

* example app
* README
* integration tests
* fixture-based evaluation

## 20. Important implementation constraints

* Use Swift concurrency (`actor`, `async/await`) for all mutable shared state.
* Keep third-party dependencies at zero for v1.
* Prefer plain `Codable` persistence.
* Keep the core design inspectable and debuggable.
* Do not block implementation on perfect transcript reconstruction APIs.
* Do not hard-code 4096 anywhere except as a fallback default.
* Do not assume exact token APIs are always present.
* Do not assume the model is always available.
* Do not assume locale support.

## 21. Stretch goals

Only after v1 works:

* SwiftData-backed persistence
* more advanced semantic retrieval
* compaction quality scoring
* Foundation Models Instrument benchmark harness
* per-thread custom reducer pipelines
* explicit tool-aware payload policies

## 22. Final instruction to the agent

Build a production-quality SwiftPM package for the above spec. Favor correctness, deterministic behavior, and observability over cleverness. Where Apple API ergonomics are uncertain, choose the simplest public-API-compatible fallback that preserves the logical-thread abstraction.

[1]: https://machinelearning.apple.com/research/apple-foundation-models-2025-updates "https://machinelearning.apple.com/research/apple-foundation-models-2025-updates"
[2]: https://developer.apple.com/documentation/updates/foundationmodels?changes=_6 "https://developer.apple.com/documentation/updates/foundationmodels?changes=_6"
[3]: https://developer.apple.com/forums/forums/topics/machine-learning-and-ai "https://developer.apple.com/forums/forums/topics/machine-learning-and-ai"
[4]: https://forums.swift.org/t/swift-context-management-a-package-to-efficiently-handle-llm-token-limits-and-history/84326 "https://forums.swift.org/t/swift-context-management-a-package-to-efficiently-handle-llm-token-limits-and-history/84326"
[5]: https://developer.apple.com/videos/play/wwdc2025/301/ "https://developer.apple.com/videos/play/wwdc2025/301/"

---

**Changes made:**
- Package name: `FoundationContextManager` → `LanguageModelContextKit`
- Main public entrypoint actor: `FoundationContextManager` → `LanguageModelContextKit`
- Optional secondary target: `FoundationContextNL` → `LanguageModelContextKitNL`
- Package structure paths updated
- Error enum: `FoundationContextError` → `LanguageModelContextKitError`
- Test target names updated
- All references throughout the spec updated to use the new library name


