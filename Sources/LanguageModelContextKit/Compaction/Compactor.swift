import Foundation
import FoundationModels

struct ThreadCompactor: Sendable {
    let configuration: ContextManagerConfiguration
    let tokenCounterFactory: TokenCounterFactory
    let sessionDriver: any SessionDriving
    let logger: DiagnosticsLogger

    func compact(
        plan initialPlan: ContextPlan,
        threadConfiguration: ThreadConfiguration,
        options: CompactionOptions,
        contextWindowTokens: Int,
        exactBudgetEstimator: (any ExactBudgetEstimating)?
    ) async throws -> ContextPlan {
        let tokenCounter = tokenCounterFactory.make(
            preferExact: configuration.budget.exactCountingPreferred,
            exactEstimator: exactBudgetEstimator
        )
        var plan = initialPlan
        let originalBudget = initialPlan.budget
        plan.originalProjectedTotalTokens = originalBudget.projectedTotalTokens

        guard options.force || plan.budget.projectedTotalTokens > plan.budget.softLimitTokens else {
            return plan
        }

        for reducer in reducers(for: configuration.compaction.mode) {
            let changed = try await reducer.apply(
                to: &plan,
                configuration: configuration,
                threadConfiguration: threadConfiguration,
                sessionDriver: sessionDriver,
                options: options
            )
            guard changed else {
                continue
            }

            plan.reducersApplied.append(reducer.kind)
            plan.requiresBridge = true
            plan.budget = tokenCounter.estimate(
                snapshot: makeSnapshot(from: plan, threadConfiguration: threadConfiguration),
                budgetPolicy: configuration.budget,
                contextWindowTokens: contextWindowTokens
            )

            if plan.budget.projectedTotalTokens <= plan.budget.softLimitTokens {
                break
            }
        }

        let reducersDescription = plan.reducersApplied.map(\.rawValue).joined(separator: ",")
        logger.compaction(
            "before=\(originalBudget.projectedTotalTokens) after=\(plan.budget.projectedTotalTokens) reducers=\(reducersDescription) summary=\(plan.summaryCreated)"
        )

        return plan
    }

    private func reducers(for mode: CompactionMode) -> [any ContextReducer] {
        switch mode {
        case .slidingWindow:
            return [
                ToolPayloadDigesterReducer(),
                DropLowPriorityRetrievedMemoryReducer(),
                SlidingTailReducer(),
                EmergencyResetReducer()
            ]
        case .structuredSummary:
            return [
                ToolPayloadDigesterReducer(),
                DropLowPriorityRetrievedMemoryReducer(),
                StructuredSummaryReducer(),
                AggressiveSummaryReducer(),
                EmergencyResetReducer()
            ]
        case .hybrid:
            return [
                ToolPayloadDigesterReducer(),
                DropLowPriorityRetrievedMemoryReducer(),
                SlidingTailReducer(),
                StructuredSummaryReducer(),
                AggressiveSummaryReducer(),
                EmergencyResetReducer()
            ]
        }
    }

    private func makeSnapshot(
        from plan: ContextPlan,
        threadConfiguration: ThreadConfiguration
    ) -> ContextSnapshot {
        ContextSnapshot(
            instructions: plan.state.instructions,
            toolDescriptions: threadConfiguration.tools.map { ToolDescriptor.describe($0) },
            durableMemory: plan.durableMemory,
            retrievedMemory: plan.retrievedMemory,
            recentTail: plan.recentTail,
            currentPrompt: plan.currentPrompt,
            schemaDescription: plan.schemaDescription
        )
    }
}

protocol ContextReducer: Sendable {
    var kind: ReducerKind { get }
    func apply(
        to plan: inout ContextPlan,
        configuration: ContextManagerConfiguration,
        threadConfiguration: ThreadConfiguration,
        sessionDriver: any SessionDriving,
        options: CompactionOptions
    ) async throws -> Bool
}

struct ToolPayloadDigesterReducer: ContextReducer {
    let kind: ReducerKind = .toolPayloadDigester

    func apply(
        to plan: inout ContextPlan,
        configuration: ContextManagerConfiguration,
        threadConfiguration _: ThreadConfiguration,
        sessionDriver _: any SessionDriving,
        options _: CompactionOptions
    ) async throws -> Bool {
        var changed = false
        var updatedTurns: [NormalizedTurn] = []
        var newBlobRecords: [DurableMemoryRecord] = []

        for turn in plan.state.turns {
            guard turn.blobIDs.isEmpty else {
                updatedTurns.append(turn)
                continue
            }

            let bytes = turn.text.lengthOfBytes(using: .utf8)
            guard bytes > configuration.memory.inlineBlobByteLimit || turn.role == .tool else {
                updatedTurns.append(turn)
                continue
            }

            let blobID = try await configuration.persistence.blobs.put(Data(turn.text.utf8))
            let digest = String(turn.text.prefix(240))
            updatedTurns.append(
                NormalizedTurn(
                    id: turn.id,
                    role: turn.role,
                    text: "[spilled blob \(blobID.uuidString)] \(digest)",
                    createdAt: turn.createdAt,
                    priority: turn.priority,
                    tags: turn.tags,
                    blobIDs: [blobID],
                    windowIndex: turn.windowIndex,
                    compacted: turn.compacted
                )
            )
            newBlobRecords.append(
                DurableMemoryRecord(
                    kind: .blobRef,
                    text: "Blob \(blobID.uuidString) from \(turn.role.rawValue) turn",
                    priority: 250,
                    tags: ["blob"],
                    blobIDs: [blobID],
                    pinned: false
                )
            )
            changed = true
        }

        if changed {
            plan.state.turns = updatedTurns
            plan.durableMemory.append(contentsOf: newBlobRecords)
            plan.spilledBlobCount += newBlobRecords.count
        }

        return changed
    }
}

struct DropLowPriorityRetrievedMemoryReducer: ContextReducer {
    let kind: ReducerKind = .dropLowPriorityRetrievedMemory

    func apply(
        to plan: inout ContextPlan,
        configuration _: ContextManagerConfiguration,
        threadConfiguration _: ThreadConfiguration,
        sessionDriver _: any SessionDriving,
        options _: CompactionOptions
    ) async throws -> Bool {
        guard !plan.retrievedMemory.isEmpty else {
            return false
        }
        plan.retrievedMemory = []
        return true
    }
}

struct SlidingTailReducer: ContextReducer {
    let kind: ReducerKind = .slidingTail

    func apply(
        to plan: inout ContextPlan,
        configuration _: ContextManagerConfiguration,
        threadConfiguration _: ThreadConfiguration,
        sessionDriver _: any SessionDriving,
        options _: CompactionOptions
    ) async throws -> Bool {
        guard plan.recentTail.count > 4 else {
            return false
        }
        let reducedCount = max(4, plan.recentTail.count / 2)
        plan.recentTail = Array(plan.recentTail.suffix(reducedCount))
        return true
    }
}

struct StructuredSummaryReducer: ContextReducer {
    let kind: ReducerKind = .structuredSummary

    func apply(
        to plan: inout ContextPlan,
        configuration: ContextManagerConfiguration,
        threadConfiguration: ThreadConfiguration,
        sessionDriver: any SessionDriving,
        options: CompactionOptions
    ) async throws -> Bool {
        let tailIDs = Set(plan.recentTail.map(\.id))
        let candidates = plan.state.turns.filter { !tailIDs.contains($0.id) && !$0.compacted }
        guard !candidates.isEmpty else {
            return false
        }

        let summary = try await SummaryReducerSupport.makeSummary(
            from: candidates,
            state: plan.state,
            policy: threadConfiguration.model,
            locale: plan.state.locale,
            sessionDriver: sessionDriver,
            maximumDepth: configuration.compaction.maxMergeDepth,
            chunkTargetTokens: configuration.compaction.chunkTargetTokens,
            chunkSummaryTargetTokens: configuration.compaction.chunkSummaryTargetTokens
        )

        plan.state.turns = plan.state.turns.map { turn in
            guard candidates.contains(where: { $0.id == turn.id }) else {
                return turn
            }
            return turn.markedCompacted()
        }
        plan.state.turns.append(
            NormalizedTurn(
                role: .summary,
                text: SummaryReducerSupport.renderSummary(summary.compactedState, summaryText: summary.summaryText),
                priority: 500,
                tags: ["summary"],
                windowIndex: plan.state.activeWindowIndex,
                compacted: false
            )
        )
        if options.allowMemoryExtraction {
            plan.durableMemory = SummaryReducerSupport.merge(
                summary.compactedState,
                into: plan.durableMemory
            )
        }
        plan.latestCompactedState = summary.compactedState
        plan.summaryCreated = true
        return true
    }
}

struct AggressiveSummaryReducer: ContextReducer {
    let kind: ReducerKind = .aggressiveSummary

    func apply(
        to plan: inout ContextPlan,
        configuration: ContextManagerConfiguration,
        threadConfiguration: ThreadConfiguration,
        sessionDriver: any SessionDriving,
        options: CompactionOptions
    ) async throws -> Bool {
        let keep = Set(plan.state.turns.suffix(2).map(\.id))
        let candidates = plan.state.turns.filter { !keep.contains($0.id) }
        guard !candidates.isEmpty else {
            return false
        }

        let summary = try await SummaryReducerSupport.makeSummary(
            from: candidates,
            state: plan.state,
            policy: threadConfiguration.model,
            locale: plan.state.locale,
            sessionDriver: sessionDriver,
            maximumDepth: configuration.compaction.maxMergeDepth,
            chunkTargetTokens: max(200, configuration.compaction.chunkTargetTokens / 2),
            chunkSummaryTargetTokens: configuration.compaction.chunkSummaryTargetTokens
        )

        plan.state.turns = plan.state.turns.map { keep.contains($0.id) ? $0 : $0.markedCompacted() }
        plan.recentTail = Array(plan.state.turns.suffix(2))
        if options.allowMemoryExtraction {
            plan.durableMemory = SummaryReducerSupport.merge(summary.compactedState, into: plan.durableMemory)
        }
        plan.latestCompactedState = summary.compactedState
        plan.summaryCreated = true
        return true
    }
}

struct EmergencyResetReducer: ContextReducer {
    let kind: ReducerKind = .emergencyReset

    func apply(
        to plan: inout ContextPlan,
        configuration _: ContextManagerConfiguration,
        threadConfiguration _: ThreadConfiguration,
        sessionDriver _: any SessionDriving,
        options _: CompactionOptions
    ) async throws -> Bool {
        let currentPrompt = plan.currentPrompt
        let reducedMemory = plan.durableMemory.filter { $0.pinned || $0.priority >= 900 }
        let reducedTail = Array(plan.state.turns.suffix(2))
        let changed = reducedMemory.count != plan.durableMemory.count || reducedTail.count != plan.recentTail.count
        plan.durableMemory = reducedMemory
        plan.retrievedMemory = []
        plan.recentTail = reducedTail
        plan.currentPrompt = currentPrompt
        return changed
    }
}

enum SummaryReducerSupport {
    struct Result: Sendable {
        var compactedState: CompactedState
        var summaryText: String?
    }

    static func makeSummary(
        from turns: [NormalizedTurn],
        state: PersistedThreadState,
        policy: ModelPolicy,
        locale: Locale?,
        sessionDriver: any SessionDriving,
        maximumDepth: Int,
        chunkTargetTokens: Int,
        chunkSummaryTargetTokens: Int
    ) async throws -> Result {
        let chunks = chunk(turns: turns, targetSize: chunkTargetTokens)
        var chunkResults: [Result] = []
        chunkResults.reserveCapacity(chunks.count)

        for chunk in chunks {
            chunkResults.append(
                await summarizeChunk(
                    chunk,
                    policy: policy,
                    locale: locale,
                    sessionDriver: sessionDriver,
                    maximumResponseTokens: chunkSummaryTargetTokens
                )
            )
        }

        let mergedState = merge(chunkResults.map(\.compactedState))
        let chunkSummaryTurns = chunkResults.enumerated().map { index, result in
            return NormalizedTurn(
                role: .summary,
                text: "Chunk \(index + 1): " + renderSummary(result.compactedState, summaryText: result.summaryText),
                priority: 500,
                tags: ["chunk-summary"],
                windowIndex: state.activeWindowIndex,
                compacted: false
            )
        }
        let turnsForSummary = chunkSummaryTurns.count > 1 ? chunkSummaryTurns : turns
        let preferredSummary = chunkResults.count == 1 ? chunkResults.first?.summaryText : nil
        let modelSummary = await recursiveSummary(
            turns: turnsForSummary,
            policy: policy,
            locale: locale,
            sessionDriver: sessionDriver,
            maximumDepth: maximumDepth,
            chunkTargetTokens: chunkTargetTokens,
            chunkSummaryTargetTokens: chunkSummaryTargetTokens,
            preferredSummary: preferredSummary
        )
        return Result(compactedState: mergedState, summaryText: modelSummary)
    }

    private static func summarizeChunk(
        _ turns: [NormalizedTurn],
        policy: ModelPolicy,
        locale: Locale?,
        sessionDriver: any SessionDriving,
        maximumResponseTokens: Int
    ) async -> Result {
        if let structured = await sessionDriver.summarizeStructured(
            turns: turns,
            policy: policy,
            locale: locale,
            maximumResponseTokens: maximumResponseTokens
        ) {
            return Result(
                compactedState: mergeBlobReferences(from: turns, into: structured.compactedState),
                summaryText: structured.summaryText
            )
        }

        let compactedState = extractCompactedState(from: turns)
        let summaryText =
            await sessionDriver.summarize(
                turns: turns,
                policy: policy,
                locale: locale,
                maximumResponseTokens: maximumResponseTokens
            )
            ?? renderSummary(compactedState, summaryText: nil)
        return Result(compactedState: compactedState, summaryText: summaryText)
    }

    private static func recursiveSummary(
        turns: [NormalizedTurn],
        policy: ModelPolicy,
        locale: Locale?,
        sessionDriver: any SessionDriving,
        maximumDepth: Int,
        chunkTargetTokens: Int,
        chunkSummaryTargetTokens: Int,
        preferredSummary: String? = nil
    ) async -> String? {
        guard !turns.isEmpty else {
            return nil
        }

        let chunks = chunk(turns: turns, targetSize: chunkTargetTokens)
        if maximumDepth <= 1 || chunks.count <= 1 {
            if let preferredSummary {
                return preferredSummary
            }
            return await sessionDriver.summarize(
                turns: turns,
                policy: policy,
                locale: locale,
                maximumResponseTokens: chunkSummaryTargetTokens
            )
        }

        var higherLevelTurns: [NormalizedTurn] = []
        higherLevelTurns.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let summaryText =
                await sessionDriver.summarize(
                    turns: chunk,
                    policy: policy,
                    locale: locale,
                    maximumResponseTokens: chunkSummaryTargetTokens
                )
                ?? renderSummary(extractCompactedState(from: chunk), summaryText: nil)

            higherLevelTurns.append(
                NormalizedTurn(
                    role: .summary,
                    text: "Level summary \(index + 1): \(summaryText)",
                    priority: 500,
                    tags: ["hierarchical-summary"],
                    windowIndex: chunk.last?.windowIndex ?? 0,
                    compacted: false
                )
            )
        }

        return await recursiveSummary(
            turns: higherLevelTurns,
            policy: policy,
            locale: locale,
            sessionDriver: sessionDriver,
            maximumDepth: maximumDepth - 1,
            chunkTargetTokens: chunkTargetTokens,
            chunkSummaryTargetTokens: chunkSummaryTargetTokens
        )
    }

    static func renderSummary(_ state: CompactedState, summaryText: String?) -> String {
        if let summaryText, !summaryText.isEmpty {
            return summaryText
        }

        var lines: [String] = []
        if !state.stableFacts.isEmpty {
            lines.append("Facts: " + state.stableFacts.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        }
        if !state.userConstraints.isEmpty {
            lines.append("Constraints: " + state.userConstraints.joined(separator: "; "))
        }
        if !state.decisions.isEmpty {
            lines.append("Decisions: " + state.decisions.map(\.summary).joined(separator: "; "))
        }
        if !state.openTasks.isEmpty {
            lines.append("Open tasks: " + state.openTasks.map { "\($0.description) [\($0.status)]" }.joined(separator: "; "))
        }
        if !state.entities.isEmpty {
            lines.append("Entities: " + state.entities.map { "\($0.name) (\($0.type))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    static func merge(
        _ compactedState: CompactedState,
        into records: [DurableMemoryRecord]
    ) -> [DurableMemoryRecord] {
        var merged = records
        let additions: [DurableMemoryRecord] =
            compactedState.stableFacts.map {
                DurableMemoryRecord(
                    kind: .fact,
                    text: "\($0.key): \($0.value)",
                    priority: 900,
                    tags: ["fact"],
                    pinned: true
                )
            }
            + compactedState.userConstraints.map {
                DurableMemoryRecord(
                    kind: .constraint,
                    text: $0,
                    priority: 900,
                    tags: ["constraint"],
                    pinned: true
                )
            }
            + compactedState.decisions.map {
                DurableMemoryRecord(
                    kind: .decision,
                    text: $0.summary,
                    priority: 860,
                    tags: ["decision"],
                    pinned: true
                )
            }
            + compactedState.openTasks.map {
                DurableMemoryRecord(
                    kind: .openTask,
                    text: "\($0.description) [\($0.status)]",
                    priority: 860,
                    tags: ["open-task"],
                    pinned: true
                )
            }
            + compactedState.blobReferences.map {
                DurableMemoryRecord(
                    kind: .blobRef,
                    text: "Blob \($0.id.uuidString): \($0.reason)",
                    priority: 250,
                    tags: ["blob"],
                    blobIDs: [$0.id],
                    pinned: false
                )
            }

        for record in additions {
            if !merged.contains(where: { $0.kind == record.kind && $0.text == record.text }) {
                merged.append(record)
            }
        }

        return merged
    }

    static func extractCompactedState(from turns: [NormalizedTurn]) -> CompactedState {
        var facts: [StableFact] = []
        var constraints: [String] = []
        var decisions: [Decision] = []
        var openTasks: [OpenTask] = []
        var entities: [EntityRef] = []
        var blobReferences: [BlobReference] = []

        for turn in turns {
            let sentences = splitSentences(turn.text)
            for sentence in sentences {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    continue
                }

                if let fact = parseFact(trimmed) {
                    facts.append(fact)
                }
                if looksLikeConstraint(trimmed) {
                    constraints.append(trimmed)
                }
                if looksLikeDecision(trimmed) {
                    decisions.append(Decision(summary: trimmed))
                }
                if looksLikeOpenTask(trimmed) {
                    openTasks.append(OpenTask(description: trimmed, status: "open"))
                }
                entities.append(contentsOf: extractEntities(from: trimmed))
            }

            blobReferences.append(contentsOf: turn.blobIDs.map { BlobReference(id: $0, reason: "Referenced from \(turn.role.rawValue) turn") })
        }

        return CompactedState(
            stableFacts: deduplicate(facts) { "\($0.key)=\($0.value)" },
            userConstraints: deduplicate(constraints),
            openTasks: deduplicate(openTasks) { "\($0.description)|\($0.status)" },
            decisions: deduplicate(decisions) { $0.summary },
            entities: deduplicate(entities) { "\($0.name)|\($0.type)" },
            blobReferences: deduplicate(blobReferences) { "\($0.id.uuidString)|\($0.reason)" },
            retrievalHints: deduplicate(entities.map(\.name))
        )
    }

    private static func parseFact(_ text: String) -> StableFact? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            return nil
        }
        let normalizedKey = key.lowercased()
        guard normalizedKey != "todo", normalizedKey != "open", normalizedKey != "next step" else {
            return nil
        }
        return StableFact(key: key, value: value)
    }

    private static func looksLikeConstraint(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("must")
            || lowercased.contains("should")
            || lowercased.contains("prefer")
            || lowercased.contains("do not")
            || lowercased.contains("don't")
    }

    private static func looksLikeDecision(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("decided")
            || lowercased.contains("will use")
            || lowercased.contains("chosen")
            || lowercased.contains("we will")
    }

    private static func looksLikeOpenTask(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("todo")
            || lowercased.contains("need to")
            || lowercased.contains("follow up")
            || lowercased.contains("next step")
            || lowercased.hasPrefix("open:")
    }

    private static func extractEntities(from text: String) -> [EntityRef] {
        let codeMatches = text.matches(pattern: "`([^`]+)`").map {
            EntityRef(name: $0, type: "identifier")
        }
        let capitalized = text
            .split(separator: " ")
            .map(String.init)
            .filter { word in
                guard let first = word.first else { return false }
                return first.isUppercase && word.count > 1
            }
            .map { EntityRef(name: $0.trimmingCharacters(in: .punctuationCharacters), type: "name") }
        return codeMatches + capitalized
    }

    private static func splitSentences(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\n", with: ". ")
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func chunk(turns: [NormalizedTurn], targetSize: Int) -> [[NormalizedTurn]] {
        guard targetSize > 0 else {
            return [turns]
        }
        var chunks: [[NormalizedTurn]] = []
        var current: [NormalizedTurn] = []
        var currentSize = 0

        for turn in turns {
            let size = max(1, turn.text.count / 4)
            if !current.isEmpty && currentSize + size > targetSize {
                chunks.append(current)
                current = []
                currentSize = 0
            }
            current.append(turn)
            currentSize += size
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private static func merge(_ states: [CompactedState]) -> CompactedState {
        let merged = states.reduce(into: CompactedState()) { partialResult, state in
            partialResult.stableFacts.append(contentsOf: state.stableFacts)
            partialResult.userConstraints.append(contentsOf: state.userConstraints)
            partialResult.openTasks.append(contentsOf: state.openTasks)
            partialResult.decisions.append(contentsOf: state.decisions)
            partialResult.entities.append(contentsOf: state.entities)
            partialResult.blobReferences.append(contentsOf: state.blobReferences)
            partialResult.retrievalHints.append(contentsOf: state.retrievalHints)
        }
        return CompactedState(
            stableFacts: deduplicate(merged.stableFacts) { "\($0.key)=\($0.value)" },
            userConstraints: deduplicate(merged.userConstraints),
            openTasks: deduplicate(merged.openTasks) { "\($0.description)|\($0.status)" },
            decisions: deduplicate(merged.decisions) { $0.summary },
            entities: deduplicate(merged.entities) { "\($0.name)|\($0.type)" },
            blobReferences: deduplicate(merged.blobReferences) { "\($0.id.uuidString)|\($0.reason)" },
            retrievalHints: deduplicate(merged.retrievalHints)
        )
    }

    private static func mergeBlobReferences(
        from turns: [NormalizedTurn],
        into state: CompactedState
    ) -> CompactedState {
        var merged = state
        merged.blobReferences = deduplicate(
            state.blobReferences + turns.flatMap { turn in
                turn.blobIDs.map { BlobReference(id: $0, reason: "Referenced from \(turn.role.rawValue) turn") }
            }
        ) { "\($0.id.uuidString)|\($0.reason)" }
        return merged
    }

    private static func deduplicate<T>(
        _ values: [T],
        key: (T) -> String
    ) -> [T] {
        var seen: Set<String> = []
        return values.filter { value in
            let valueKey = key(value)
            return seen.insert(valueKey).inserted
        }
    }

    private static func deduplicate(_ values: [String]) -> [String] {
        deduplicate(values, key: { $0 })
    }
}

extension NormalizedTurn {
    fileprivate func markedCompacted() -> NormalizedTurn {
        NormalizedTurn(
            id: id,
            role: role,
            text: text,
            createdAt: createdAt,
            priority: priority,
            tags: tags,
            blobIDs: blobIDs,
            windowIndex: windowIndex,
            compacted: true
        )
    }
}

enum ToolDescriptor {
    static func describe(_ tool: any Tool) -> String {
        "\(tool.name): \(tool.description)"
    }
}

extension String {
    fileprivate func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: self) else {
                return nil
            }
            return String(self[range])
        }
    }
}
