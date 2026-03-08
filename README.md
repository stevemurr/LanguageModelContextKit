# LanguageModelContextKit

`LanguageModelContextKit` is a Swift package that wraps Apple Foundation Models with a logical-thread API. It budgets prompts, compacts context, bridges across session windows, persists normalized state, and exposes diagnostics without making the app manage raw `LanguageModelSession` history directly.

## Requirements

- Swift 6.2
- macOS 26.0, iOS 26.0, or visionOS 26.0
- Foundation Models availability on the target device for real generation

## Installation

Add the package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/stevemurr/language-model-context-kit", branch: "main")
```

Then depend on the product:

```swift
.product(name: "LanguageModelContextKit", package: "language-model-context-kit")
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

## Notes

- Call `openThread` after app launch or resume for any thread that uses tools, because tool implementations are runtime-only.
- The library persists normalized turns and durable memories, not Foundation transcript objects.
- Heuristic token counting is active by default; the exact-counting seam is present for future SDK support.
