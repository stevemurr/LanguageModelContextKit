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

@Generable(description: "A short greeting payload.")
private struct GreetingPayload {
    var message: String
}

@Suite("LanguageModelContextKitIntegration")
struct LanguageModelContextKitIntegrationTests {
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
}
