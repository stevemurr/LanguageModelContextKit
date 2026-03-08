import Foundation
import FoundationModels

struct AppleSessionDriver: SessionDriving {
    func availability(for policy: ModelPolicy) -> ModelAvailability {
        let model = makeModel(policy: policy)
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("Device not eligible for Foundation Models")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Apple Intelligence is not enabled")
            case .modelNotReady:
                return .unavailable("Foundation Models assets are not ready")
            @unknown default:
                return .unavailable("Foundation Models is unavailable")
            }
        @unknown default:
            return .unavailable("Foundation Models is unavailable")
        }
    }

    func supportsLocale(_ locale: Locale?, policy: ModelPolicy) -> Bool {
        guard let locale else {
            return true
        }
        return makeModel(policy: policy).supportsLocale(locale)
    }

    func contextWindowTokens(for policy: ModelPolicy) -> Int? {
        4096
    }

    func exactBudgetEstimator(for policy: ModelPolicy) -> (any ExactBudgetEstimating)? {
        nil
    }

    func makeSession(
        seed: SessionSeed,
        tools: [any Tool],
        policy: ModelPolicy
    ) async throws -> any SessionHandle {
        let model = makeModel(policy: policy)
        let session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: seed.instructions
        )
        return AppleSessionHandle(session: session)
    }

    func summarize(
        turns: [NormalizedTurn],
        policy: ModelPolicy,
        locale _: Locale?,
        maximumResponseTokens: Int?
    ) async -> String? {
        guard case .available = availability(for: policy), !turns.isEmpty else {
            return nil
        }

        let seed = SessionSeed(
            instructions: """
            Summarize conversation history conservatively. Preserve stable facts, user constraints, decisions, unresolved work, named entities, and tool conclusions. Do not invent facts.
            """
        )

        do {
            let handle = try await makeSession(seed: seed, tools: [], policy: policy)
            let prompt = turns.map { "\($0.role.rawValue.capitalized): \($0.text)" }.joined(separator: "\n")
            let result = try await handle.respondText(
                to: prompt,
                maximumResponseTokens: maximumResponseTokens ?? 256
            )
            return result.text
        } catch {
            return nil
        }
    }

    private func makeModel(policy: ModelPolicy) -> SystemLanguageModel {
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
}

actor AppleSessionHandle: SessionHandle {
    private let session: LanguageModelSession

    init(session: LanguageModelSession) {
        self.session = session
    }

    func respondText(to prompt: String, maximumResponseTokens: Int?) async throws -> SessionTextResult {
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(maximumResponseTokens: maximumResponseTokens)
            )
            return SessionTextResult(text: response.content)
        } catch let error as LanguageModelSession.GenerationError {
            throw map(error)
        } catch {
            throw SessionFailure.generationFailed(error.localizedDescription)
        }
    }

    func respondStructured<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        maximumResponseTokens: Int?
    ) async throws -> SessionStructuredResult<Content> {
        do {
            let response = try await session.respond(
                to: prompt,
                generating: type,
                includeSchemaInPrompt: includeSchemaInPrompt,
                options: GenerationOptions(maximumResponseTokens: maximumResponseTokens)
            )
            return SessionStructuredResult(
                content: response.content,
                transcriptText: String(describing: response.rawContent)
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw map(error)
        } catch {
            throw SessionFailure.generationFailed(error.localizedDescription)
        }
    }

    private func map(_ error: LanguageModelSession.GenerationError) -> SessionFailure {
        switch error {
        case .exceededContextWindowSize(let context):
            return .exceededContextWindowSize(context.debugDescription)
        case .unsupportedLanguageOrLocale(let context):
            return .unsupportedLocale(context.debugDescription)
        case .refusal(_, let context):
            return .refusal(context.debugDescription)
        default:
            return .generationFailed(error.localizedDescription)
        }
    }
}
