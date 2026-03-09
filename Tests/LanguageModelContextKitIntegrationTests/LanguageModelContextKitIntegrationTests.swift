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
            let session = try await kit.session(
                id: "policy-\(name)",
                configuration: SessionConfiguration(
                    instructions: "Return concise labels.",
                    locale: Locale(identifier: "en_US"),
                    model: policy
                )
            )

            let textResponse = try await session.reply(
                to: "Label this text in one or two words: Fresh green apple."
            )
            #expect(
                textResponse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "Expected text response for \(name)"
            )

            let diagnostics = await session.inspection.diagnostics()
            #expect(diagnostics?.turnCount == 2, "Expected persisted turns for \(name)")
        }
    }

    @Test("Short thread integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func shortThread() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        let session = try await kit.session(
            id: "integration-thread",
            configuration: SessionConfiguration(instructions: "Reply with exactly one short sentence.")
        )

        let response = try await session.respond("Say hello")

        #expect(response.isEmpty == false)
    }

    @Test("Structured response integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func structuredResponse() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        let session = try await kit.session(
            id: "integration-structured-thread",
            configuration: SessionConfiguration(instructions: "Return concise structured content.")
        )

        let payload = try await session.generate(
            "Return a short greeting in the message field.",
            as: GreetingPayload.self
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

        let session = try await kit.session(
            id: "integration-structured-stream-thread",
            configuration: SessionConfiguration(instructions: "Return concise structured content.")
        )

        var sawPartial = false
        var completed: GeneratedReply<GreetingPayload>?

        for try await event in session.stream(
            "Return a greeting of six to ten words in the message field.",
            as: GreetingPayload.self
        ) {
            switch event {
            case .partial:
                sawPartial = true
            case .completed(let response):
                completed = response
            }
        }

        let history = try await session.inspection.history()
        #expect(sawPartial)
        #expect(completed?.value.message.isEmpty == false)
        #expect(history.count == 2)
    }

    @Test("Text streaming integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func textStreaming() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        let session = try await kit.session(
            id: "integration-text-stream-thread",
            configuration: SessionConfiguration(instructions: "Reply with one short sentence.")
        )

        var sawPartial = false
        var completed: TextReply?

        for try await event in session.stream(
            "Say hello in one short sentence."
        ) {
            switch event {
            case .partial(let text):
                sawPartial = sawPartial || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .completed(let response):
                completed = response
            }
        }

        let history = try await session.inspection.history()
        #expect(sawPartial)
        #expect(completed?.text.isEmpty == false)
        #expect(history.count == 2)
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

        let session = try await kit.session(
            id: "integration-compaction-thread",
            configuration: SessionConfiguration(
                instructions: "Answer briefly and preserve decisions, tasks, and constraints."
            )
        )

        _ = try await session.respond("We decided to use actors. Keep the README concise. TODO: polish diagnostics docs.")
        _ = try await session.respond("Reminder: keep examples short and preserve the project name LanguageModelContextKit.")

        let report = try await session.maintenance.compact()
        let diagnostics = await session.inspection.diagnostics()

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

        let session = try await kit.session(
            id: "integration-unsupported-locale",
            configuration: SessionConfiguration(
                instructions: "Respond briefly.",
                locale: locale
            )
        )

        do {
            _ = try await session.respond("Bonjour")
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

        let session = try await kit.session(
            id: "integration-overflow-thread",
            configuration: SessionConfiguration(
                instructions: "If possible, answer in one short sentence."
            )
        )

        let oversizedPrompt = Array(
            repeating: "context-window-overflow-check repeated filler text",
            count: 2500
        ).joined(separator: " ")

        do {
            _ = try await session.respond(oversizedPrompt)
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

        let session = try await kit.session(
            id: "integration-import-thread",
            configuration: SessionConfiguration(
                instructions: "Answer with the imported workspace label only."
            )
        )

        try await session.maintenance.importHistory(
            [
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

        let response = try await session.respond(
            "What is the workspace label? Reply with only the label."
        )

        let history = try await session.inspection.history()
        #expect(response.contains("Lattice Harbor"))
        #expect(history.count == 4)
    }

    @Test("Append turns continuity integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func appendTurnsContinuity() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        let session = try await kit.session(
            id: "integration-append-turns-thread",
            configuration: SessionConfiguration(
                instructions: "Answer with the stored workspace label only."
            )
        )

        try await session.maintenance.appendTurns(
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
            ]
        )

        let response = try await session.respond(
            "What is the workspace label? Reply with only the label."
        )

        let history = try await session.inspection.history()
        #expect(response.contains("Harbor Mint"))
        #expect(history.count == 4)
    }

    @Test("Append memories continuity integration", .disabled(if: !SystemLanguageModel.default.isAvailable))
    func appendMemoriesContinuity() async throws {
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            )
        )

        let session = try await kit.session(
            id: "integration-append-memories-thread",
            configuration: SessionConfiguration(
                instructions: "Answer with the stored workspace label only."
            )
        )

        try await session.maintenance.appendMemory(
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
            ]
        )

        let response = try await session.respond(
            "What is the workspace label? Reply with only the label."
        )

        let memories = try await session.inspection.durableMemory()
        #expect(response.contains("Harbor Mint"))
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

        let session = try await kit.session(
            id: "integration-overflow-imported-thread",
            configuration: SessionConfiguration(
                instructions: "If possible, answer in one short sentence."
            )
        )

        try await session.maintenance.importHistory(
            [
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
        try await session.maintenance.appendTurns(
            [
                NormalizedTurn(
                    role: .tool,
                    text: "Appended external tool output before overflow.",
                    priority: 250,
                    tags: ["tool"],
                    windowIndex: 0
                )
            ]
        )

        let oversizedPrompt = Array(
            repeating: "context-window-overflow-check repeated filler text",
            count: 2500
        ).joined(separator: " ")

        do {
            _ = try await session.respond(oversizedPrompt)
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
