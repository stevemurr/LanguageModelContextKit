# LanguageModelContextKit

`LanguageModelContextKit` is a Swift package that wraps Apple Foundation Models with a logical-thread API. It budgets prompts, compacts context, bridges across session windows, persists normalized state, and exposes diagnostics without making the app manage raw `LanguageModelSession` history directly.

## Requirements

- Swift 6.2
- macOS 26.0, iOS 26.0, or visionOS 26.0
- Foundation Models availability on the target device for real generation

## Installation

Add the package to your SwiftPM dependencies:

```swift
.package(
    name: "LanguageModelContextKit",
    url: "https://github.com/stevemurr/LanguageModelContextKit.git",
    branch: "main"
)
```

Then depend on the product:

```swift
.product(name: "LanguageModelContextKit", package: "LanguageModelContextKit")
```

## Quick Start

```swift
import Foundation
import LanguageModelContextKit

let kit = LanguageModelContextKit()

try await kit.openThread(
    id: "demo-thread",
    configuration: ThreadConfiguration(
        instructions: "Reply concisely and preserve explicit user constraints.",
        locale: Locale(identifier: "en_US")
    )
)

let budget = try await kit.estimateBudget(
    for: "Summarize the current task.",
    threadID: "demo-thread"
)

print("Projected tokens:", budget.projectedTotalTokens)

let response = try await kit.respond(
    to: "Summarize the current task.",
    threadID: "demo-thread"
)

print(response.text)
```

## Availability

Callers can check Foundation Models readiness and locale support without reaching into adapter internals:

```swift
switch await kit.availabilityStatus() {
case .available:
    break
case .unavailable(let reason):
    print("Model unavailable:", reason)
}

let supportsFrench = await kit.supportsLocale(Locale(identifier: "fr_FR"))
print("French supported:", supportsFrench)
```

## Structured Responses

Use `respondManaged` when you need structured output plus persisted metadata:

```swift
import FoundationModels

@Generable(description: "A compact project summary.")
struct ProjectSummary {
    var headline: String
    var openTasks: [String]
}

let managed = try await kit.respondManaged(
    to: "Summarize the current project state.",
    generating: ProjectSummary.self,
    threadID: "demo-thread",
    transcriptRenderer: { summary in
        """
        \(summary.headline)
        Open tasks:
        \(summary.openTasks.joined(separator: "\n"))
        """
    }
)

print(managed.content.headline)
print(managed.transcriptText)
print(managed.budget.projectedTotalTokens)
```

`respond(to:generating:threadID:includeSchemaInPrompt:transcriptRenderer:)` remains available as a convenience wrapper that returns only `managed.content`.

## Streaming

The library exposes managed streaming for both plain text and structured generation. Partial events stream during generation, and one final completion event includes `budget`, `compaction`, and `bridge`. Assistant turns are only persisted on successful completion.

```swift
for try await event in await kit.streamText(
    to: "Write a short project status update.",
    threadID: "demo-thread"
) {
    switch event {
    case .partial(let text):
        print("partial:", text)
    case .completed(let response):
        print("final:", response.text)
        print("budget:", response.budget.projectedTotalTokens)
    }
}
```

```swift
for try await event in await kit.streamManaged(
    to: "Summarize the project state.",
    generating: ProjectSummary.self,
    threadID: "demo-thread"
) {
    switch event {
    case .partial(let content, _):
        print("partial headline:", content.headline)
    case .completed(let response):
        print("final tasks:", response.content.openTasks)
    }
}
```

## Long Thread Example

```swift
import LanguageModelContextKit

let kit = LanguageModelContextKit(
    configuration: ContextManagerConfiguration(
        budget: BudgetPolicy(
            reservedOutputTokens: 768,
            preemptiveCompactionFraction: 0.78,
            emergencyFraction: 0.90,
            maxBridgeRetries: 2,
            exactCountingPreferred: true,
            heuristicSafetyMultiplier: 1.10,
            defaultContextWindowTokens: 4096
        )
    )
)

try await kit.openThread(
    id: "project-thread",
    configuration: ThreadConfiguration(
        instructions: "Track project facts, decisions, and open tasks."
    )
)

for prompt in [
    "Project: LanguageModelContextKit.",
    "We decided to use Swift concurrency actors.",
    "TODO: write integration tests.",
    "Summarize what still needs to be done."
] {
    let response = try await kit.respond(to: prompt, threadID: "project-thread")
    print(response.text)
}
```

When the estimated budget crosses the configured soft limit, the package compacts older context and bridges to a fresh Foundation Models session as needed.

## Manual Compaction

```swift
let report = try await kit.compact(threadID: "project-thread")
print(report.reducersApplied)
print(report.summaryCreated)
```

## Diagnostics

```swift
if let diagnostics = await kit.diagnostics(threadID: "project-thread") {
    print("Window:", diagnostics.windowIndex)
    print("Turns:", diagnostics.turnCount)
    print("Durable memories:", diagnostics.durableMemoryCount)
    print("Last bridge:", diagnostics.lastBridge?.reason ?? "none")
}
```

## Persistence

The default configuration uses in-memory stores. For durable persistence, pass file-backed stores:

```swift
import Foundation
import LanguageModelContextKit

let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let persistence = PersistencePolicy(
    threads: FileThreadStore(directoryURL: root.appendingPathComponent("LMCK/threads")),
    memories: FileMemoryStore(directoryURL: root.appendingPathComponent("LMCK/memories")),
    blobs: FileBlobStore(directoryURL: root.appendingPathComponent("LMCK/blobs")),
    retriever: nil
)

let kit = LanguageModelContextKit(
    configuration: ContextManagerConfiguration(persistence: persistence)
)
```

## Importing Existing State

You can bootstrap a logical thread from app-owned history before the next model call:

```swift
try await kit.importThread(
    id: "migrated-thread",
    configuration: ThreadConfiguration(
        instructions: "Preserve prior user constraints and decisions."
    ),
    turns: existingTurns,
    durableMemory: existingDurableMemory,
    replaceExisting: true
)
```

Imported turns are sorted by `createdAt`, existing `windowIndex` values are preserved, persisted durable memory is written through the configured memory store, and any live in-memory session is invalidated so the next call rehydrates from imported state.
Re-importing the same imported records is idempotent for matching turns and durable memories.

## External Mutations and Inspection

Apps can append externally produced context without going through `respond(...)`:

```swift
try await kit.appendTurns(toolTurns, threadID: "demo-thread")
try await kit.appendMemories(memoryRecords, threadID: "demo-thread")

let state = try await kit.threadState(threadID: "demo-thread")
let memories = try await kit.durableMemories(threadID: "demo-thread")

print(state.turns.count)
print(memories.count)
```

Appending turns or memories does not trigger compaction. It updates persisted thread timestamps and invalidates any live session so the next generation request rehydrates cleanly.

## Notes

- Call `openThread` after app launch or resume for any thread that uses tools, because tool implementations are runtime-only.
- The library persists normalized turns and durable memories, not Foundation transcript objects.
- Structured calls persist assistant text from `transcriptRenderer(content)` when provided; otherwise they persist the adapter transcript text.
- Exact budgeting still falls back to heuristics today because Foundation Models does not currently expose public token-count or context-window APIs that the package can bind to.
