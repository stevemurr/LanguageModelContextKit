# LanguageModelContextKit

`LanguageModelContextKit` is a Swift package that wraps Apple Foundation Models with a logical-session API. It budgets prompts, compacts context, bridges across session windows, persists normalized state, and exposes inspection and maintenance tools without making the app manage raw `LanguageModelSession` history directly.

## Requirements

- Swift 6.2
- macOS 26.0, iOS 26.0, or visionOS 26.0
- Foundation Models availability on the target device for real generation

## Installation

Add the package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/stevemurr/LanguageModelContextKit.git", branch: "main")
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

let session = try await kit.session(
    id: "demo-thread",
    configuration: SessionConfiguration(
        instructions: "Reply concisely and preserve explicit user constraints.",
        locale: Locale(identifier: "en_US")
    )
)

let response = try await session.respond("Summarize the current task.")
print(response)
```

## Availability

Callers can check Foundation Models readiness and locale support without reaching into adapter internals:

```swift
switch await kit.availability() {
case .available:
    break
case .unavailable(let reason):
    print("Model unavailable:", reason)
}

let supportsFrench = await kit.supportsLocale(Locale(identifier: "fr_FR"))
print("French supported:", supportsFrench)
```

## Structured Responses

Use `generate` for the simple typed path, or `reply(to:as:)` if you also want per-turn metadata:

```swift
import FoundationModels
import LanguageModelContextKit

@Generable(description: "A compact project summary.")
struct ProjectSummary {
    var headline: String
    var openTasks: [String]
}

let summary = try await session.generate(
    "Summarize the current project state.",
    as: ProjectSummary.self
)

let reply = try await session.reply(
    to: "Summarize the current project state.",
    as: ProjectSummary.self
)

print(summary.headline)
print(reply.transcriptText)
print(reply.metadata.compaction?.summaryCreated ?? false)
```

Structured replies include:

- `value` for the typed payload
- `transcriptText` for the adapter-rendered transcript/debug view
- `compaction` and `bridge` metadata for the completed turn

## Streaming

The library streams both plain text and structured generation through the session. Partial events stream during generation, and one final completion event includes the persisted result plus `compaction` and `bridge` metadata. Assistant turns are only persisted on successful completion.

```swift
for try await event in session.stream("Write a short project status update.") {
    switch event {
    case .partial(let text):
        print("partial:", text)
    case .completed(let response):
        print("final:", response.text)
        print("bridged:", response.metadata.bridge != nil)
    }
}
```

```swift
for try await event in session.stream(
    "Summarize the project state.",
    as: ProjectSummary.self
) {
    switch event {
    case .partial(let content):
        print("partial headline:", content.headline)
    case .completed(let response):
        print("final tasks:", response.value.openTasks)
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

let session = try await kit.session(
    id: "project-thread",
    configuration: SessionConfiguration(
        instructions: "Track project facts, decisions, and open tasks."
    )
)

for prompt in [
    "Project: LanguageModelContextKit.",
    "We decided to use Swift concurrency actors.",
    "TODO: write integration tests.",
    "Summarize what still needs to be done."
] {
    let response = try await session.respond(prompt)
    print(response)
}
```

When the internal budget crosses the configured soft limit, the package compacts older context and bridges to a fresh Foundation Models session as needed.

## Manual Compaction

```swift
let report = try await session.maintenance.compact()
print(report.reducersApplied)
print(report.summaryCreated)
```

## Diagnostics

```swift
if let diagnostics = await session.inspection.diagnostics() {
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

You can bootstrap a session from app-owned history before the next model call:

```swift
let session = try await kit.session(
    id: "migrated-thread",
    configuration: SessionConfiguration(
        instructions: "Preserve prior user constraints and decisions."
    )
)

try await session.maintenance.importHistory(
    existingTurns,
    durableMemory: existingDurableMemory,
    replaceExisting: true
)
```

Imported turns are sorted by `createdAt`, existing `windowIndex` values are preserved, persisted durable memory is written through the configured memory store, and any live in-memory model session is invalidated so the next call rehydrates from imported state. With `replaceExisting: false`, imported state is merged into the existing session and repeated imports of the same turns or durable memories are deduplicated.

## External Mutations and Inspection

Apps can append externally produced context without going through `respond(...)`:

```swift
try await session.maintenance.appendTurns(toolTurns)
try await session.maintenance.appendMemory(memoryRecords)

let turns = try await session.inspection.history()
let memories = try await session.inspection.durableMemory()

print(turns.count)
print(memories.count)
```

Appending turns or memories does not trigger compaction. It updates persisted session state and invalidates any live model session so the next generation request rehydrates cleanly. `appendMemory` deduplicates by `kind + text` by default; pass `deduplicate: false` if you need exact duplicates preserved.

## Budgeting Notes

LMCK budgets internally before each request. When Foundation Models does not expose a runtime context-window value, LMCK uses `BudgetPolicy.defaultContextWindowTokens` as the window-size fallback for planning and diagnostics.

## Notes

- Recreate a session with the same `id` after app launch or resume for any persisted conversation that uses tools, because tool implementations are runtime-only.
- After relaunch, call `kit.session(id:configuration:)` again for persisted sessions so runtime configuration such as tools is reattached before the next model request.
- The library persists normalized turns and durable memories, not Foundation transcript objects.
- Exact budgeting still falls back to heuristics today because Foundation Models does not currently expose public token-count or context-window APIs that the package can bind to.
