import Foundation
import FoundationModels
import LanguageModelContextKit
import Testing

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
}
