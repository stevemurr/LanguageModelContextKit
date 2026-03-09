# LanguageModelContextKit

`LanguageModelContextKit` gives you a session-style API on top of Apple Foundation Models.

You create a session, send prompts to it, and LMCK handles the hard parts for you:

- keeping context within the model window
- compacting older conversation state
- bridging to fresh underlying model sessions when needed
- persisting turns and durable memory

The goal is simple: callers should talk to a `session`, not manage context windows.

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

## Mental Model

- `LanguageModelContextKit` is the factory and configuration object.
- `ContextSession` is what your app talks to.
- Use `respond`, `generate`, or `stream` for normal model work.
- Use `inspection` and `maintenance` only for debugging, import, reset, or manual compaction.

## Quick Start

```swift
import Foundation
import LanguageModelContextKit

let kit = LanguageModelContextKit()

let session = try await kit.session(
    id: "demo",
    configuration: SessionConfiguration(
        instructions: "Reply concisely and preserve explicit user constraints.",
        locale: Locale(identifier: "en_US")
    )
)

let text = try await session.respond("Summarize the current task.")
print(text)
```

That is the main API. In most apps, this is the path you use most often.

## Typed Output

Use `generate` when you want structured output:

```swift
import FoundationModels
import LanguageModelContextKit

@Generable(description: "A compact project summary.")
struct ProjectSummary {
    var headline: String
    var openTasks: [String]
}

let summary = try await session.generate(
    "Summarize the project state.",
    as: ProjectSummary.self
)

print(summary.headline)
```

If you also want per-turn metadata, use `reply`:

```swift
let reply = try await session.reply(
    to: "Summarize the project state.",
    as: ProjectSummary.self
)

print(reply.value.headline)
print(reply.transcriptText)
print(reply.metadata.compaction?.summaryCreated ?? false)
```

## Streaming

Text streaming:

```swift
for try await event in session.stream("Write a short project update.") {
    switch event {
    case .partial(let text):
        print("partial:", text)
    case .completed(let reply):
        print("final:", reply.text)
    }
}
```

Structured streaming:

```swift
for try await event in session.stream(
    "Summarize the project state.",
    as: ProjectSummary.self
) {
    switch event {
    case .partial(let partial):
        print("partial headline:", partial.headline)
    case .completed(let reply):
        print("final tasks:", reply.value.openTasks)
    }
}
```

Assistant turns are only persisted after a successful completion.

## Availability

You can check whether Foundation Models is ready before creating a session:

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

## Persistence

By default, LMCK uses in-memory storage.

If you want durable storage, pass file-backed stores when creating the kit:

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

Recreate a session with the same `id` after app relaunch and LMCK will rehydrate persisted state.

```swift
let session = try await kit.session(
    id: "demo",
    configuration: SessionConfiguration(
        instructions: "Reply concisely.",
        tools: tools
    )
)
```

## Importing Existing History

If your app already has turns and durable memory, you can import them into a session:

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

## Inspection And Maintenance

Most apps do not need this day to day, but it is available when you do.

Inspection:

```swift
if let diagnostics = await session.inspection.diagnostics() {
    print("Window:", diagnostics.windowIndex)
    print("Turns:", diagnostics.turnCount)
    print("Durable memories:", diagnostics.durableMemoryCount)
}

let turns = try await session.inspection.history()
let memories = try await session.inspection.durableMemory()
```

Maintenance:

```swift
let report = try await session.maintenance.compact()
print(report.reducersApplied)

try await session.maintenance.appendTurns(toolTurns)
try await session.maintenance.appendMemory(memoryRecords)

try await session.maintenance.reset()
```

## Configuration

You can tune LMCK through `ContextManagerConfiguration`.

Most apps can start with the default configuration. Reach for custom configuration when you need to adjust compaction behavior, memory retrieval, persistence, or diagnostics.

```swift
let kit = LanguageModelContextKit(
    configuration: ContextManagerConfiguration(
        compaction: CompactionPolicy(mode: .hybrid, maxRecentTurns: 8),
        memory: MemoryPolicy(automaticallyExtractMemories: true),
        diagnostics: DiagnosticsPolicy(isEnabled: true, logToOSLog: true)
    )
)
```

## Notes

- LMCK manages context length internally. Callers do not need to manually trim transcript history before normal requests.
- If a session uses tools, recreate it with the same `id` and tool configuration after app relaunch.
- LMCK persists normalized turns and durable memories, not Foundation transcript objects.
- Exact budgeting still falls back to heuristics today because Foundation Models does not currently expose all token-count and context-window APIs needed for a purely exact implementation.
