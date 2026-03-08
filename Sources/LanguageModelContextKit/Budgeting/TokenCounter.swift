import Foundation

protocol TokenCounter: Sendable {
    func estimate(
        snapshot: ContextSnapshot,
        budgetPolicy: BudgetPolicy
    ) -> BudgetReport
}

struct HeuristicTokenCounter: TokenCounter {
    let perMessageOverhead: Int

    init(perMessageOverhead: Int = 6) {
        self.perMessageOverhead = perMessageOverhead
    }

    func estimate(
        snapshot: ContextSnapshot,
        budgetPolicy: BudgetPolicy
    ) -> BudgetReport {
        var breakdown: [BudgetComponent: Int] = [:]
        breakdown[.instructions] = tokenEstimate(for: snapshot.instructions ?? "", safetyMultiplier: budgetPolicy.heuristicSafetyMultiplier)
        breakdown[.tools] = tokenEstimate(for: snapshot.toolDescriptions.joined(separator: "\n"), safetyMultiplier: budgetPolicy.heuristicSafetyMultiplier)
        breakdown[.durableMemory] = estimate(records: snapshot.durableMemory, safetyMultiplier: budgetPolicy.heuristicSafetyMultiplier)
        breakdown[.retrievedMemory] = estimate(records: snapshot.retrievedMemory, safetyMultiplier: budgetPolicy.heuristicSafetyMultiplier)
        breakdown[.recentTail] = estimate(turns: snapshot.recentTail, safetyMultiplier: budgetPolicy.heuristicSafetyMultiplier)
        breakdown[.currentPrompt] = tokenEstimate(for: snapshot.currentPrompt, safetyMultiplier: budgetPolicy.heuristicSafetyMultiplier)
        breakdown[.schema] = tokenEstimate(for: snapshot.schemaDescription ?? "", safetyMultiplier: budgetPolicy.heuristicSafetyMultiplier)
        breakdown[.outputReserve] = budgetPolicy.reservedOutputTokens

        let inputTokens = breakdown
            .filter { $0.key != .outputReserve }
            .map(\.value)
            .reduce(0, +)
        let projected = inputTokens + budgetPolicy.reservedOutputTokens
        let contextWindowTokens = budgetPolicy.defaultContextWindowTokens

        return BudgetReport(
            accuracy: .approximate,
            contextWindowTokens: contextWindowTokens,
            estimatedInputTokens: inputTokens,
            reservedOutputTokens: budgetPolicy.reservedOutputTokens,
            projectedTotalTokens: projected,
            softLimitTokens: Int(Double(contextWindowTokens) * budgetPolicy.preemptiveCompactionFraction),
            emergencyLimitTokens: Int(Double(contextWindowTokens) * budgetPolicy.emergencyFraction),
            breakdown: breakdown
        )
    }

    func tokenEstimate(
        for text: String,
        safetyMultiplier: Double
    ) -> Int {
        guard !text.isEmpty else {
            return 0
        }

        let utf8ByteCount = text.lengthOfBytes(using: .utf8)
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let base = max(
            Int(ceil(Double(utf8ByteCount) / 4.0)),
            Int(ceil(Double(wordCount) * 1.35))
        )
        return Int(ceil(Double(base + perMessageOverhead) * safetyMultiplier))
    }

    private func estimate(
        turns: [NormalizedTurn],
        safetyMultiplier: Double
    ) -> Int {
        turns.reduce(0) { partialResult, turn in
            partialResult + tokenEstimate(for: turn.text, safetyMultiplier: safetyMultiplier)
        }
    }

    private func estimate(
        records: [DurableMemoryRecord],
        safetyMultiplier: Double
    ) -> Int {
        records.reduce(0) { partialResult, record in
            partialResult + tokenEstimate(for: record.text, safetyMultiplier: safetyMultiplier)
        }
    }
}

struct AppleExactTokenCounter: TokenCounter {
    private let fallback: HeuristicTokenCounter

    init(fallback: HeuristicTokenCounter = HeuristicTokenCounter()) {
        self.fallback = fallback
    }

    func estimate(
        snapshot: ContextSnapshot,
        budgetPolicy: BudgetPolicy
    ) -> BudgetReport {
        fallback.estimate(snapshot: snapshot, budgetPolicy: budgetPolicy)
    }
}

struct TokenCounterFactory: Sendable {
    let heuristicCounter: HeuristicTokenCounter
    let exactCounter: AppleExactTokenCounter

    init(
        heuristicCounter: HeuristicTokenCounter = HeuristicTokenCounter(),
        exactCounter: AppleExactTokenCounter = AppleExactTokenCounter()
    ) {
        self.heuristicCounter = heuristicCounter
        self.exactCounter = exactCounter
    }

    func make(preferExact: Bool) -> any TokenCounter {
        preferExact ? exactCounter : heuristicCounter
    }
}
