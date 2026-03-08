import Foundation
import FoundationModels

@Generable(description: "Conservative structured compaction of conversation history. Keep arrays empty when information is absent. Do not invent facts.")
private struct GeneratedCompactionEnvelope {
    var summaryText: String
    var stableFacts: [GeneratedCompactionFact]
    var userConstraints: [String]
    var openTasks: [GeneratedCompactionTask]
    var decisions: [String]
    var entities: [GeneratedCompactionEntity]
    var retrievalHints: [String]
}

@Generable(description: "A durable factual key-value pair stated directly or strongly implied by the conversation.")
private struct GeneratedCompactionFact {
    var key: String
    var value: String
}

@Generable(description: "An unresolved task that should survive context compaction.")
private struct GeneratedCompactionTask {
    var description: String
    var status: String
}

@Generable(description: "An important named entity, code identifier, component, person, file, or concept.")
private struct GeneratedCompactionEntity {
    var name: String
    var type: String
}

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

        let session = LanguageModelSession(
            model: makeModel(policy: policy),
            tools: [],
            instructions: """
            Summarize conversation history conservatively. Preserve stable facts, user constraints, decisions, unresolved work, named entities, and tool conclusions. Do not invent facts.
            """
        )

        do {
            let prompt = turns.map { "\($0.role.rawValue.capitalized): \($0.text)" }.joined(separator: "\n")
            let result = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: maximumResponseTokens ?? 256
                )
            )
            return result.content
        } catch {
            return nil
        }
    }

    func summarizeStructured(
        turns: [NormalizedTurn],
        policy: ModelPolicy,
        locale: Locale?,
        maximumResponseTokens: Int?
    ) async -> ModelCompactionSummary? {
        guard case .available = availability(for: policy), !turns.isEmpty else {
            return nil
        }

        let session = LanguageModelSession(
            model: makeModel(policy: policy),
            tools: [],
            instructions: """
            Compact conversation history conservatively into structured memory.
            Preserve only durable information grounded in the transcript.
            Keep arrays empty when information is absent.
            Do not invent facts, tasks, entities, or decisions.
            Produce a short summaryText that can seed a future bridge.
            """
        )

        let localeClause = locale.map { "Target locale for wording: \($0.identifier)." } ?? ""
        let prompt = """
        \(localeClause)
        Transcript:
        \(turns.map { "\($0.role.rawValue.capitalized): \($0.text)" }.joined(separator: "\n"))
        """

        do {
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedCompactionEnvelope.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: maximumResponseTokens ?? 256
                )
            )
            return response.content.modelSummary
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
                transcriptText: response.rawContent.jsonString
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw map(error)
        } catch {
            throw SessionFailure.generationFailed(error.localizedDescription)
        }
    }

    func streamStructured<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        maximumResponseTokens: Int?
    ) async -> AsyncThrowingStream<SessionStructuredStreamEvent<Content>, Error> {
        AsyncThrowingStream { continuation in
            let stream = session.streamResponse(
                to: prompt,
                generating: type,
                includeSchemaInPrompt: includeSchemaInPrompt,
                options: GenerationOptions(maximumResponseTokens: maximumResponseTokens)
            )

            let task = Task {
                do {
                    var finalRawContent: GeneratedContent?

                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        finalRawContent = snapshot.rawContent
                        continuation.yield(
                            .partial(
                                SessionStructuredStreamPartial(
                                    content: snapshot.content,
                                    transcriptText: snapshot.rawContent.jsonString,
                                    rawContent: snapshot.rawContent
                                )
                            )
                        )
                    }

                    guard let finalRawContent, finalRawContent.isComplete else {
                        throw SessionFailure.generationFailed("Streaming finished without final content")
                    }

                    continuation.yield(
                        .completed(
                            SessionStructuredResult(
                                content: try Content(finalRawContent),
                                transcriptText: finalRawContent.jsonString
                            )
                        )
                    )
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: map(error))
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as SessionFailure {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: SessionFailure.generationFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
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

private extension GeneratedCompactionEnvelope {
    var modelSummary: ModelCompactionSummary {
        ModelCompactionSummary(
            compactedState: CompactedState(
                stableFacts: stableFacts.map { StableFact(key: $0.key, value: $0.value) },
                userConstraints: userConstraints,
                openTasks: openTasks.map { OpenTask(description: $0.description, status: $0.status) },
                decisions: decisions.map(Decision.init(summary:)),
                entities: entities.map { EntityRef(name: $0.name, type: $0.type) },
                blobReferences: [],
                retrievalHints: retrievalHints
            ),
            summaryText: summaryText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
