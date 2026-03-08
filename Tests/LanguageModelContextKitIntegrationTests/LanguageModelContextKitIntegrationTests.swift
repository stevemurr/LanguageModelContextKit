import Foundation
import FoundationModels
import LanguageModelContextKit
import Testing

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
}
