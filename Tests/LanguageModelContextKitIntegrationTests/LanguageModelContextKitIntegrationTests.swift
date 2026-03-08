import Foundation
import FoundationModels
import LanguageModelContextKit
import Testing

private let unsupportedLocaleForIntegration = [
    Locale(identifier: "tlh"),
    Locale(identifier: "zxx"),
    Locale(identifier: "art-x-klingon"),
    Locale(identifier: "qya")
].first { !SystemLanguageModel.default.supportsLocale($0) }

private let liveModelPolicies: [(name: String, policy: ModelPolicy)] = [
    ("general-default", ModelPolicy(useCase: .general, guardrails: .default)),
    (
        "general-permissive",
        ModelPolicy(useCase: .general, guardrails: .permissiveContentTransformations)
    ),
    ("content-tagging-default", ModelPolicy(useCase: .contentTagging, guardrails: .default)),
    (
        "content-tagging-permissive",
        ModelPolicy(useCase: .contentTagging, guardrails: .permissiveContentTransformations)
    )
]

@Generable(description: "A short greeting payload.")
private struct GreetingPayload {
    var message: String
}

@Suite("LanguageModelContextKitIntegration")
struct LanguageModelContextKitIntegrationTests {
    @Test("Foundation Models policy matrix", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func foundationModelsPolicyMatrix() async throws {
        for (name, policy) in liveModelPolicies {
            let model = makeSystemLanguageModel(for: policy)
            #expect(model.isAvailable)

            let session = LanguageModelSession(
                model: model,
                instructions: "Return exactly one short label."
            )
            let response = try await session.respond(
                to: "Label this text in one or two words: Fresh green apple.",
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: 24
                )
            )

            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.isEmpty == false, "Expected non-empty response for \(name)")
        }
    }

    @Test("Context kit policy matrix", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func contextKitPolicyMatrix() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        for (name, policy) in liveModelPolicies {
            let threadID = "policy-\(name)"
            try await kit.openThread(
                id: threadID,
                configuration: ThreadConfiguration(
                    instructions: "Return concise labels.",
                    locale: Locale(identifier: "en_US"),
                    model: policy
                )
            )

            let budget = try await kit.estimateBudget(
                for: "Label this text in one or two words: Fresh green apple.",
                threadID: threadID
            )
            #expect(budget.estimatedInputTokens > 0, "Expected budget for \(name)")

            let textResponse = try await kit.respond(
                to: "Label this text in one or two words: Fresh green apple.",
                threadID: threadID
            )
            #expect(
                textResponse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "Expected text response for \(name)"
            )

            let diagnostics = await kit.diagnostics(threadID: threadID)
            #expect(diagnostics?.lastBudget != nil, "Expected diagnostics budget for \(name)")
        }
    }

    @Test("Short thread integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func shortThread() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-thread",
            configuration: ThreadConfiguration(instructions: "Reply with exactly one short sentence.")
        )

        let response = try await kit.respond(
            to: "Say hello",
            threadID: "integration-thread"
        )

        #expect(response.text.isEmpty == false)
    }

    @Test("Structured response integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func structuredResponse() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-structured-thread",
            configuration: ThreadConfiguration(instructions: "Return concise structured content.")
        )

        let payload = try await kit.respond(
            to: "Return a short greeting in the message field.",
            generating: GreetingPayload.self,
            threadID: "integration-structured-thread"
        )

        #expect(payload.message.isEmpty == false)
    }

    @Test("Structured streaming integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func structuredStreaming() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-structured-stream-thread",
            configuration: ThreadConfiguration(instructions: "Return concise structured content.")
        )

        var sawPartial = false
        var completed: ManagedStructuredResponse<GreetingPayload>?

        for try await event in await kit.streamManaged(
            to: "Return a greeting of six to ten words in the message field.",
            generating: GreetingPayload.self,
            threadID: "integration-structured-stream-thread"
        ) {
            switch event {
            case .partial:
                sawPartial = true
            case .completed(let response):
                completed = response
            }
        }

        let state = try await kit.threadState(threadID: "integration-structured-stream-thread")
        #expect(sawPartial)
        #expect(completed?.content.message.isEmpty == false)
        #expect(completed?.budget.estimatedInputTokens ?? 0 > 0)
        #expect(state.turns.count == 2)
    }

    @Test("Text streaming integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func textStreaming() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-text-stream-thread",
            configuration: ThreadConfiguration(instructions: "Reply with one short sentence.")
        )

        var sawPartial = false
        var completed: ManagedTextResponse?

        for try await event in await kit.streamText(
            to: "Say hello in one short sentence.",
            threadID: "integration-text-stream-thread"
        ) {
            switch event {
            case .partial(let text):
                sawPartial = sawPartial || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .completed(let response):
                completed = response
            }
        }

        let state = try await kit.threadState(threadID: "integration-text-stream-thread")
        #expect(sawPartial)
        #expect(completed?.text.isEmpty == false)
        #expect(completed?.budget.estimatedInputTokens ?? 0 > 0)
        #expect(state.turns.count == 2)
    }

    @Test("Manual compaction integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func manualCompaction() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                budget: BudgetPolicy(
                    reservedOutputTokens: 128,
                    preemptiveCompactionFraction: 0.50,
                    emergencyFraction: 0.75,
                    maxBridgeRetries: 1,
                    exactCountingPreferred: true,
                    heuristicSafetyMultiplier: 1.10,
                    defaultContextWindowTokens: 256
                ),
                compaction: CompactionPolicy(
                    mode: .structuredSummary,
                    maxRecentTurns: 0,
                    chunkTargetTokens: 128,
                    chunkSummaryTargetTokens: 96,
                    maxMergeDepth: 2
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-compaction-thread",
            configuration: ThreadConfiguration(
                instructions: "Answer briefly and preserve decisions, tasks, and constraints."
            )
        )

        _ = try await kit.respond(
            to: "We decided to use actors. Keep the README concise. TODO: polish diagnostics docs.",
            threadID: "integration-compaction-thread"
        )
        _ = try await kit.respond(
            to: "Reminder: keep examples short and preserve the project name LanguageModelContextKit.",
            threadID: "integration-compaction-thread"
        )

        let report = try await kit.compact(threadID: "integration-compaction-thread")
        let diagnostics = await kit.diagnostics(threadID: "integration-compaction-thread")

        #expect(report.summaryCreated)
        #expect(report.reducersApplied.contains(.structuredSummary))
        #expect(diagnostics?.lastCompaction?.summaryCreated == true)
    }

    @Test(
        "Unsupported locale integration",
        .disabled(if: !SystemLanguageModel.default.isAvailable || unsupportedLocaleForIntegration == nil)
    )
    func unsupportedLocale() async throws {
        let locale = try #require(unsupportedLocaleForIntegration)
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-unsupported-locale",
            configuration: ThreadConfiguration(
                instructions: "Respond briefly.",
                locale: locale
            )
        )

        do {
            _ = try await kit.estimateBudget(
                for: "Bonjour",
                threadID: "integration-unsupported-locale"
            )
            Issue.record("Expected unsupported locale error for \(locale.identifier)")
        } catch let error as LanguageModelContextKitError {
            switch error {
            case .unsupportedLocale(let message):
                #expect(message.contains(locale.identifier))
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Overflow retry integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func overflowRetry() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                budget: BudgetPolicy(
                    reservedOutputTokens: 64,
                    preemptiveCompactionFraction: 0.95,
                    emergencyFraction: 0.99,
                    maxBridgeRetries: 1,
                    exactCountingPreferred: true,
                    heuristicSafetyMultiplier: 1.10,
                    defaultContextWindowTokens: 4096
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-overflow-thread",
            configuration: ThreadConfiguration(
                instructions: "If possible, answer in one short sentence."
            )
        )

        let oversizedPrompt = Array(
            repeating: "context-window-overflow-check repeated filler text",
            count: 2500
        ).joined(separator: " ")

        do {
            _ = try await kit.respond(
                to: oversizedPrompt,
                threadID: "integration-overflow-thread"
            )
            Issue.record("Expected budget exhaustion after overflow retry")
        } catch let error as LanguageModelContextKitError {
            switch error {
            case .budgetExhausted(let diagnostics):
                #expect(diagnostics.windowIndex >= 1)
                #expect(diagnostics.lastBridge?.reason == "exceededContextWindowSize")
            case .exceededBudget(let budget):
                #expect(budget.projectedTotalTokens > budget.contextWindowTokens)
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Imported thread continuity integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func importedThreadContinuity() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.importThread(
            id: "integration-import-thread",
            configuration: ThreadConfiguration(
                instructions: "Answer with the imported workspace label only."
            ),
            turns: [
                NormalizedTurn(
                    role: .user,
                    text: "Workspace label: Lattice Harbor.",
                    createdAt: Date(timeIntervalSince1970: 10),
                    priority: 950,
                    windowIndex: 0
                ),
                NormalizedTurn(
                    role: .assistant,
                    text: "Stored: workspace label is Lattice Harbor.",
                    createdAt: Date(timeIntervalSince1970: 20),
                    priority: 800,
                    windowIndex: 0
                )
            ],
            durableMemory: [
                DurableMemoryRecord(
                    kind: .fact,
                    text: "Workspace label: Lattice Harbor",
                    priority: 900
                )
            ],
            replaceExisting: true
        )

        let response = try await kit.respond(
            to: "What is the workspace label? Reply with only the label.",
            threadID: "integration-import-thread"
        )

        let state = try await kit.threadState(threadID: "integration-import-thread")
        #expect(response.text.contains("Lattice Harbor"))
        #expect(state.turns.count == 4)
    }

    @Test("Append turns continuity integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func appendTurnsContinuity() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-append-turns-thread",
            configuration: ThreadConfiguration(
                instructions: "Answer with the stored workspace label only."
            )
        )

        try await kit.appendTurns(
            [
                NormalizedTurn(
                    role: .user,
                    text: "Workspace label: Harbor Mint.",
                    createdAt: Date(timeIntervalSince1970: 10),
                    priority: 950,
                    windowIndex: 0
                ),
                NormalizedTurn(
                    role: .assistant,
                    text: "Stored: workspace label is Harbor Mint.",
                    createdAt: Date(timeIntervalSince1970: 20),
                    priority: 800,
                    windowIndex: 0
                )
            ],
            threadID: "integration-append-turns-thread"
        )

        let response = try await kit.respond(
            to: "What is the workspace label? Reply with only the label.",
            threadID: "integration-append-turns-thread"
        )

        let state = try await kit.threadState(threadID: "integration-append-turns-thread")
        #expect(response.text.contains("Harbor Mint"))
        #expect(state.turns.count == 4)
    }

    @Test("Append memories continuity integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func appendMemoriesContinuity() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.openThread(
            id: "integration-append-memories-thread",
            configuration: ThreadConfiguration(
                instructions: "Answer with the stored workspace label only."
            )
        )

        try await kit.appendMemories(
            [
                DurableMemoryRecord(
                    kind: .fact,
                    text: "Workspace label: Harbor Mint",
                    priority: 900
                ),
                DurableMemoryRecord(
                    kind: .fact,
                    text: "Workspace label: Harbor Mint",
                    priority: 200
                )
            ],
            threadID: "integration-append-memories-thread"
        )

        let response = try await kit.respond(
            to: "What is the workspace label? Reply with only the label.",
            threadID: "integration-append-memories-thread"
        )

        let memories = try await kit.durableMemories(threadID: "integration-append-memories-thread")
        #expect(response.text.contains("Harbor Mint"))
        #expect(memories.count == 1)
    }

    @Test("Overflow retry after imported and appended state", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func overflowRetryAfterImportedAndAppendedState() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                budget: BudgetPolicy(
                    reservedOutputTokens: 64,
                    preemptiveCompactionFraction: 0.95,
                    emergencyFraction: 0.99,
                    maxBridgeRetries: 1,
                    exactCountingPreferred: true,
                    heuristicSafetyMultiplier: 1.10,
                    defaultContextWindowTokens: 4096
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        try await kit.importThread(
            id: "integration-overflow-imported-thread",
            configuration: ThreadConfiguration(
                instructions: "If possible, answer in one short sentence."
            ),
            turns: [
                NormalizedTurn(
                    role: .user,
                    text: "Imported context before overflow.",
                    createdAt: Date(timeIntervalSince1970: 10),
                    priority: 950,
                    windowIndex: 0
                )
            ],
            durableMemory: [
                DurableMemoryRecord(
                    kind: .fact,
                    text: "Imported fact before overflow",
                    priority: 900
                )
            ],
            replaceExisting: true
        )
        try await kit.appendTurns(
            [
                NormalizedTurn(
                    role: .tool,
                    text: "Appended external tool output before overflow.",
                    priority: 250,
                    tags: ["tool"],
                    windowIndex: 0
                )
            ],
            threadID: "integration-overflow-imported-thread"
        )

        let oversizedPrompt = Array(
            repeating: "context-window-overflow-check repeated filler text",
            count: 2500
        ).joined(separator: " ")

        do {
            _ = try await kit.respond(
                to: oversizedPrompt,
                threadID: "integration-overflow-imported-thread"
            )
            Issue.record("Expected budget exhaustion after overflow retry with imported state")
        } catch let error as LanguageModelContextKitError {
            switch error {
            case .budgetExhausted(let diagnostics):
                #expect(diagnostics.windowIndex >= 1)
                #expect(diagnostics.lastBridge?.reason == "exceededContextWindowSize")
            case .exceededBudget(let budget):
                #expect(budget.projectedTotalTokens > budget.contextWindowTokens)
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}

private func makeSystemLanguageModel(for policy: ModelPolicy) -> SystemLanguageModel {
    let useCase: SystemLanguageModel.UseCase = switch policy.useCase {
    case .general:
        .general
    case .contentTagging:
        .contentTagging
    }

    let guardrails: SystemLanguageModel.Guardrails = switch policy.guardrails {
    case .default:
        .default
    case .permissiveContentTransformations:
        .permissiveContentTransformations
    }

    return SystemLanguageModel(useCase: useCase, guardrails: guardrails)
}
