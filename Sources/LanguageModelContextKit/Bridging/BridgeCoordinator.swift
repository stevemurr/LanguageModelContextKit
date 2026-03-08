import Foundation

struct BridgeSeedBuilder: Sendable {
    func makeSeed(
        for thread: PersistedThreadState,
        durableMemory: [DurableMemoryRecord],
        recentTail: [NormalizedTurn]
    ) -> SessionSeed {
        guard !durableMemory.isEmpty || !recentTail.isEmpty else {
            return SessionSeed(instructions: thread.instructions)
        }

        let memoryText = durableMemory
            .sorted { lhs, rhs in lhs.priority > rhs.priority }
            .prefix(12)
            .map { "[\($0.kind.rawValue)] \($0.text)" }
            .joined(separator: "\n")

        let tailText = recentTail
            .map { "\($0.role.rawValue.capitalized): \($0.text)" }
            .joined(separator: "\n")

        let bridgeInstructions = """
        \(thread.instructions ?? "")

        Prior logical thread context:
        Pinned and durable memory:
        \(memoryText.isEmpty ? "None" : memoryText)

        Recent turns:
        \(tailText.isEmpty ? "None" : tailText)
        """

        return SessionSeed(instructions: bridgeInstructions.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
