@testable import LanguageModelContextKit
import Foundation
import FoundationModels
import Testing

@Suite("LanguageModelContextKit")
struct LanguageModelContextKitTests {
    @Test("Availability and locale support APIs")
    func availabilityAndLocaleSupport() async throws {
        let unavailableKit = makeKit(
            driver: FakeSessionDriver(availabilityValue: .unavailable("model unavailable"))
        )
        let localeKit = makeKit(driver: FakeSessionDriver(localeSupported: false))

        let availability = await unavailableKit.availabilityStatus()
        let localeSupport = await localeKit.supportsLocale(Locale(identifier: "fr_FR"))

        #expect(availability == .unavailable(reason: "model unavailable"))
        #expect(localeSupport == false)
    }

    @Test("Open thread and estimate budget")
    func estimateBudget() async throws {
        let driver = FakeSessionDriver()
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-1",
            configuration: ThreadConfiguration(
                instructions: "You are a concise assistant.",
                locale: Locale(identifier: "en_US")
            )
        )

        let budget = try await kit.estimateBudget(
            for: "Summarize the architecture",
            threadID: "thread-1"
        )

        #expect(budget.estimatedInputTokens > 0)
        #expect(budget.projectedTotalTokens >= budget.reservedOutputTokens)
        #expect(budget.breakdown[.instructions] ?? 0 > 0)
    }

    @Test("Respond text persists turns and diagnostics")
    func respondText() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(textResponses: [.success("Hello back")])
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-2",
            configuration: ThreadConfiguration(instructions: "Respond plainly.")
        )

        let response = try await kit.respond(
            to: "Hello",
            threadID: "thread-2"
        )

        let diagnostics = await kit.diagnostics(threadID: "thread-2")
        #expect(response.text == "Hello back")
        #expect(diagnostics?.turnCount == 2)
        #expect(diagnostics?.lastBudget != nil)
    }

    @Test("Structured response path returns generated content")
    func respondStructured() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(
                    textResponses: [],
                    structuredResponses: ["Structured output"],
                    structuredTranscriptTexts: ["{\"value\":\"Structured output\"}"]
                )
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-3",
            configuration: ThreadConfiguration(instructions: "Generate strings.")
        )

        let value = try await kit.respond(
            to: "Return structured output",
            generating: String.self,
            threadID: "thread-3"
        )

        let diagnostics = await kit.diagnostics(threadID: "thread-3")
        #expect(value == "Structured output")
        #expect(diagnostics?.turnCount == 2)
    }

    @Test("Managed structured response returns metadata")
    func respondManagedMetadata() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(
                    structuredResponses: ["Structured output"],
                    structuredTranscriptTexts: ["{\"value\":\"Structured output\"}"]
                )
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-managed-response",
            configuration: ThreadConfiguration(instructions: "Generate structured responses.")
        )

        let response = try await kit.respondManaged(
            to: "Return structured output",
            generating: String.self,
            threadID: "thread-managed-response"
        )

        #expect(response.content == "Structured output")
        #expect(response.transcriptText == "{\"value\":\"Structured output\"}")
        #expect(response.budget.estimatedInputTokens > 0)
        #expect(response.compaction == nil)
        #expect(response.bridge == nil)
    }

    @Test("Structured persistence uses transcript renderer")
    func structuredTranscriptRendererPersistence() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(
                    structuredResponses: ["Structured output"],
                    structuredTranscriptTexts: ["{\"value\":\"Structured output\"}"]
                )
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-structured-renderer",
            configuration: ThreadConfiguration(instructions: "Render transcript text explicitly.")
        )

        _ = try await kit.respondManaged(
            to: "Return structured output",
            generating: String.self,
            threadID: "thread-structured-renderer",
            transcriptRenderer: { value in
                "Rendered: \(value)"
            }
        )

        let stateAfterResponse = try await kit.threadState(threadID: "thread-structured-renderer")
        #expect(stateAfterResponse.turns.last?.text == "Rendered: Structured output")
    }

    @Test("Managed structured streaming yields partial and final events")
    func streamManagedEvents() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(
                    structuredStreamScripts: [
                        ScriptedStructuredStream(
                            partials: ["Hel", "Hello"],
                            partialTranscriptTexts: ["\"Hel\"", "\"Hello\""],
                            partialRawContents: [GeneratedContent("Hel"), GeneratedContent("Hello")],
                            finalContent: "Hello",
                            finalTranscriptText: "\"Hello\""
                        )
                    ]
                )
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-structured-stream",
            configuration: ThreadConfiguration(instructions: "Stream structured responses.")
        )

        var partialTranscriptTexts: [String] = []
        var completedResponse: ManagedStructuredResponse<String>?

        for try await event in await kit.streamManaged(
            to: "Stream a response",
            generating: String.self,
            threadID: "thread-structured-stream"
        ) {
            switch event {
            case .partial(_, let transcriptText):
                partialTranscriptTexts.append(transcriptText)
            case .completed(let response):
                completedResponse = response
            }
        }

        let persisted = try await kit.threadState(threadID: "thread-structured-stream")
        #expect(partialTranscriptTexts == ["\"Hel\"", "\"Hello\""])
        #expect(completedResponse?.content == "Hello")
        #expect(completedResponse?.transcriptText == "\"Hello\"")
        #expect(completedResponse?.budget.estimatedInputTokens ?? 0 > 0)
        #expect(persisted.turns.count == 2)
        #expect(persisted.turns.last?.text == "\"Hello\"")
    }

    @Test("Stream cancellation does not persist completed assistant turn")
    func streamCancellation() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(
                    structuredStreamScripts: [
                        ScriptedStructuredStream(
                            partials: [GeneratedTextEnvelope(text: "Hel")],
                            partialTranscriptTexts: ["{\"text\":\"Hel\"}"],
                            partialRawContents: [try GeneratedContent(json: "{\"text\":\"Hel\"}")],
                            finalContent: GeneratedTextEnvelope(text: "Hello"),
                            finalTranscriptText: "{\"text\":\"Hello\"}",
                            stepDelayNanoseconds: 250_000_000
                        )
                    ]
                )
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-stream-cancel",
            configuration: ThreadConfiguration(instructions: "Stream plain text.")
        )

        let partialProbe = StreamProbe()
        let task = Task {
            do {
                for try await event in await kit.streamText(
                    to: "Stream text",
                    threadID: "thread-stream-cancel"
                ) {
                    if case .partial(let text) = event {
                        await partialProbe.record(text)
                    }
                }
            } catch {
                // Expected when the consumer cancels mid-stream.
            }
        }

        for _ in 0..<200 where await partialProbe.lastValue() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await partialProbe.lastValue() == "Hel")

        task.cancel()
        _ = await task.result

        let stateAfterCancellation = try await kit.threadState(threadID: "thread-stream-cancel")
        #expect(stateAfterCancellation.turns.isEmpty)
    }

    @Test("Overflow triggers bridge and retry")
    func bridgeAfterOverflow() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(textResponses: [.failure(.exceededContextWindowSize("overflow"))]),
                ScriptedSessionHandle(textResponses: [.success("Recovered")])
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-4",
            configuration: ThreadConfiguration(instructions: "Stay consistent.")
        )

        let response = try await kit.respond(
            to: "Continue",
            threadID: "thread-4"
        )

        let diagnostics = await kit.diagnostics(threadID: "thread-4")
        #expect(response.text == "Recovered")
        #expect(diagnostics?.windowIndex == 1)
        #expect(diagnostics?.lastBridge?.reason == "exceededContextWindowSize")
    }

    @Test("Reset clears persisted state")
    func resetThread() async throws {
        let driver = FakeSessionDriver()
        let threadStore = InMemoryThreadStore()
        let memoryStore = InMemoryMemoryStore()
        let blobStore = InMemoryBlobStore()
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                persistence: PersistencePolicy(
                    threads: threadStore,
                    memories: memoryStore,
                    blobs: blobStore
                )
            ),
            sessionDriver: driver
        )

        try await kit.openThread(
            id: "thread-5",
            configuration: ThreadConfiguration(instructions: "Reset me.")
        )
        try await kit.resetThread(threadID: "thread-5")

        let persisted = try await threadStore.load(threadID: "thread-5")
        let diagnostics = await kit.diagnostics(threadID: "thread-5")
        #expect(persisted == nil)
        #expect(diagnostics == nil)
    }

    @Test("Estimate budget does not write blobs")
    func estimateBudgetDoesNotWriteBlobs() async throws {
        let driver = FakeSessionDriver()
        let threadStore = InMemoryThreadStore()
        let memoryStore = InMemoryMemoryStore()
        let blobStore = InspectableBlobStore()
        let persisted = PersistedThreadState(
            threadID: "thread-budget",
            instructions: "Inspect prior tool output.",
            localeIdentifier: "en_US",
            model: .default,
            turns: [
                NormalizedTurn(
                    role: .tool,
                    text: String(repeating: "tool-output ", count: 400),
                    priority: 250,
                    tags: ["tool"],
                    windowIndex: 0
                )
            ]
        )
        try await threadStore.save(persisted, threadID: persisted.threadID)

        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                budget: BudgetPolicy(
                    reservedOutputTokens: 64,
                    preemptiveCompactionFraction: 0.10,
                    emergencyFraction: 0.20,
                    maxBridgeRetries: 1,
                    exactCountingPreferred: false,
                    heuristicSafetyMultiplier: 1.10,
                    defaultContextWindowTokens: 200
                ),
                memory: MemoryPolicy(
                    automaticallyExtractMemories: true,
                    retrievalLimit: 5,
                    inlineBlobByteLimit: 64
                ),
                persistence: PersistencePolicy(
                    threads: threadStore,
                    memories: memoryStore,
                    blobs: blobStore
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            ),
            sessionDriver: driver
        )

        try await kit.openThread(
            id: "thread-budget",
            configuration: ThreadConfiguration(instructions: "Inspect prior tool output.")
        )
        _ = try await kit.estimateBudget(for: "Summarize", threadID: "thread-budget")

        #expect(await blobStore.count() == 0)
    }

    @Test("Manual compaction forces reducer pass")
    func manualCompactionForcesReducers() async throws {
        let driver = FakeSessionDriver()
        let threadStore = InMemoryThreadStore()
        let memoryStore = InMemoryMemoryStore()
        let blobStore = InspectableBlobStore()
        let persisted = PersistedThreadState(
            threadID: "thread-compact",
            instructions: "Compact on demand.",
            localeIdentifier: "en_US",
            model: .default,
            turns: [
                NormalizedTurn(
                    role: .tool,
                    text: String(repeating: "tool-output ", count: 300),
                    priority: 250,
                    tags: ["tool"],
                    windowIndex: 0
                )
            ]
        )
        try await threadStore.save(persisted, threadID: persisted.threadID)

        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                budget: BudgetPolicy(
                    reservedOutputTokens: 64,
                    preemptiveCompactionFraction: 0.95,
                    emergencyFraction: 0.99,
                    maxBridgeRetries: 1,
                    exactCountingPreferred: false,
                    heuristicSafetyMultiplier: 1.10,
                    defaultContextWindowTokens: 8000
                ),
                memory: MemoryPolicy(
                    automaticallyExtractMemories: true,
                    retrievalLimit: 5,
                    inlineBlobByteLimit: 64
                ),
                persistence: PersistencePolicy(
                    threads: threadStore,
                    memories: memoryStore,
                    blobs: blobStore
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            ),
            sessionDriver: driver
        )

        try await kit.openThread(
            id: "thread-compact",
            configuration: ThreadConfiguration(instructions: "Compact on demand.")
        )

        let report = try await kit.compact(threadID: "thread-compact")
        let memories = try await memoryStore.load(threadID: "thread-compact")

        #expect(report.reducersApplied.contains(.toolPayloadDigester))
        #expect(await blobStore.count() == 1)
        #expect(memories.contains { $0.kind == .blobRef })
    }

    @Test("Reset deletes blobs")
    func resetDeletesBlobs() async throws {
        let driver = FakeSessionDriver()
        let threadStore = InMemoryThreadStore()
        let memoryStore = InMemoryMemoryStore()
        let blobStore = InspectableBlobStore()
        let blobID = try await blobStore.put(Data("blob".utf8))
        let persisted = PersistedThreadState(
            threadID: "thread-reset-blobs",
            instructions: "Cleanup blobs.",
            localeIdentifier: "en_US",
            model: .default,
            turns: [
                NormalizedTurn(
                    role: .assistant,
                    text: "Spilled content",
                    priority: 800,
                    tags: ["response"],
                    blobIDs: [blobID],
                    windowIndex: 0
                )
            ]
        )
        try await threadStore.save(persisted, threadID: persisted.threadID)
        try await memoryStore.save(
            [
                DurableMemoryRecord(
                    kind: .blobRef,
                    text: "Blob \(blobID.uuidString)",
                    priority: 250,
                    tags: ["blob"],
                    blobIDs: [blobID]
                )
            ],
            threadID: persisted.threadID
        )

        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                persistence: PersistencePolicy(
                    threads: threadStore,
                    memories: memoryStore,
                    blobs: blobStore
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            ),
            sessionDriver: driver
        )

        try await kit.openThread(
            id: "thread-reset-blobs",
            configuration: ThreadConfiguration(instructions: "Cleanup blobs.")
        )
        try await kit.resetThread(threadID: "thread-reset-blobs")

        #expect(await blobStore.count() == 0)
    }

    @Test("Structured compaction honors memory extraction policy")
    func memoryExtractionPolicy() async throws {
        let driver = FakeSessionDriver(summaryText: "summarized thread")
        let threadStore = InMemoryThreadStore()
        let memoryStore = InMemoryMemoryStore()
        let blobStore = InspectableBlobStore()
        let persisted = PersistedThreadState(
            threadID: "thread-no-memory",
            instructions: "Summarize without extracting durable memories.",
            localeIdentifier: "en_US",
            model: .default,
            turns: [
                NormalizedTurn(role: .user, text: "Project: Demo", priority: 950, tags: ["prompt"], windowIndex: 0),
                NormalizedTurn(role: .assistant, text: "We decided to use actors.", priority: 800, tags: ["response"], windowIndex: 0),
                NormalizedTurn(role: .user, text: "TODO: write docs.", priority: 950, tags: ["prompt"], windowIndex: 0)
            ]
        )
        try await threadStore.save(persisted, threadID: persisted.threadID)

        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                compaction: CompactionPolicy(mode: .structuredSummary, maxRecentTurns: 0),
                memory: MemoryPolicy(
                    automaticallyExtractMemories: false,
                    retrievalLimit: 5,
                    inlineBlobByteLimit: 128
                ),
                persistence: PersistencePolicy(
                    threads: threadStore,
                    memories: memoryStore,
                    blobs: blobStore
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            ),
            sessionDriver: driver
        )

        try await kit.openThread(
            id: "thread-no-memory",
            configuration: ThreadConfiguration(instructions: "Summarize without extracting durable memories.")
        )

        let report = try await kit.compact(threadID: "thread-no-memory")
        let memories = try await memoryStore.load(threadID: "thread-no-memory")

        #expect(report.summaryCreated)
        #expect(memories.isEmpty)
    }

    @Test("Structured compaction prefers model generated state")
    func structuredCompactionUsesModelState() async throws {
        let driver = FakeSessionDriver(
            summaryText: "summarized thread",
            structuredSummaryValue: ModelCompactionSummary(
                compactedState: CompactedState(
                    stableFacts: [StableFact(key: "Repository", value: "LanguageModelContextKit")],
                    userConstraints: ["Keep the README concise."],
                    openTasks: [OpenTask(description: "Polish API docs", status: "open")],
                    decisions: [Decision(summary: "Use actors for thread orchestration.")],
                    entities: [EntityRef(name: "LanguageModelContextKit", type: "module")],
                    blobReferences: [],
                    retrievalHints: ["README", "actors"]
                ),
                summaryText: "Repository and documentation decisions were preserved."
            )
        )
        let threadStore = InMemoryThreadStore()
        let memoryStore = InMemoryMemoryStore()
        let blobStore = InspectableBlobStore()
        let persisted = PersistedThreadState(
            threadID: "thread-model-summary",
            instructions: "Preserve durable project state.",
            localeIdentifier: "en_US",
            model: .default,
            turns: [
                NormalizedTurn(
                    role: .user,
                    text: "The repository name is LanguageModelContextKit.",
                    priority: 950,
                    tags: ["prompt"],
                    windowIndex: 0
                ),
                NormalizedTurn(
                    role: .assistant,
                    text: "We selected Swift actors for coordination.",
                    priority: 800,
                    tags: ["response"],
                    windowIndex: 0
                )
            ]
        )
        try await threadStore.save(persisted, threadID: persisted.threadID)

        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                compaction: CompactionPolicy(mode: .structuredSummary, maxRecentTurns: 0),
                persistence: PersistencePolicy(
                    threads: threadStore,
                    memories: memoryStore,
                    blobs: blobStore
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            ),
            sessionDriver: driver
        )

        try await kit.openThread(
            id: "thread-model-summary",
            configuration: ThreadConfiguration(instructions: "Preserve durable project state.")
        )

        let report = try await kit.compact(threadID: "thread-model-summary")
        let memories = try await memoryStore.load(threadID: "thread-model-summary")

        #expect(report.summaryCreated)
        #expect(memories.contains { $0.kind == .fact && $0.text == "Repository: LanguageModelContextKit" })
        #expect(memories.contains { $0.kind == .decision && $0.text == "Use actors for thread orchestration." })
    }

    @Test("Unavailable model maps to typed error")
    func unavailableModelError() async throws {
        let driver = FakeSessionDriver(availabilityValue: .unavailable("model unavailable"))
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-model-error",
            configuration: ThreadConfiguration(instructions: "Test unavailable model")
        )

        await #expect(throws: LanguageModelContextKitError.modelUnavailable("model unavailable")) {
            _ = try await kit.estimateBudget(for: "Hello", threadID: "thread-model-error")
        }
    }

    @Test("Unsupported locale maps to typed error")
    func unsupportedLocaleError() async throws {
        let driver = FakeSessionDriver(localeSupported: false)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-locale-error",
            configuration: ThreadConfiguration(
                instructions: "Test locale",
                locale: Locale(identifier: "fr_FR")
            )
        )

        await #expect(throws: LanguageModelContextKitError.unsupportedLocale("Locale fr_FR is unsupported")) {
            _ = try await kit.estimateBudget(for: "Bonjour", threadID: "thread-locale-error")
        }
    }

    @Test("Heuristic token counter reports approximate budget")
    func heuristicTokenCounter() {
        let counter = HeuristicTokenCounter()
        let snapshot = ContextSnapshot(
            instructions: "System instructions",
            toolDescriptions: ["lookup: searches records"],
            durableMemory: [],
            retrievedMemory: [],
            recentTail: [],
            currentPrompt: "Hello world",
            schemaDescription: nil
        )

        let budget = counter.estimate(
            snapshot: snapshot,
            budgetPolicy: .default,
            contextWindowTokens: 4096
        )
        #expect(budget.accuracy == .approximate)
        #expect(budget.estimatedInputTokens > 0)
    }

    @Test("Exact budget estimator and runtime window are honored")
    func exactBudgetEstimatorAndRuntimeWindow() async throws {
        let driver = FakeSessionDriver(
            contextWindowTokensValue: 3072,
            exactBudgetEstimatorValue: FixedExactBudgetEstimator(
                estimatedInputTokens: 333,
                breakdown: [.currentPrompt: 111, .instructions: 222]
            )
        )
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-exact-budget",
            configuration: ThreadConfiguration(instructions: "Use exact estimator.")
        )

        let budget = try await kit.estimateBudget(
            for: "Budget this prompt",
            threadID: "thread-exact-budget"
        )

        #expect(budget.accuracy == .exact)
        #expect(budget.contextWindowTokens == 3072)
        #expect(budget.estimatedInputTokens == 333)
    }

    @Test("Logical thread survives three bridged windows")
    func threeBridgedWindows() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(textResponses: [.failure(.exceededContextWindowSize("overflow-1"))]),
                ScriptedSessionHandle(textResponses: [.success("First ok"), .failure(.exceededContextWindowSize("overflow-2"))]),
                ScriptedSessionHandle(textResponses: [.success("Second ok"), .failure(.exceededContextWindowSize("overflow-3"))]),
                ScriptedSessionHandle(textResponses: [.success("Third ok")])
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-three-bridges",
            configuration: ThreadConfiguration(instructions: "Carry forward prior context between bridged windows.")
        )

        let first = try await kit.respond(to: "First prompt", threadID: "thread-three-bridges")
        let second = try await kit.respond(to: "Second prompt", threadID: "thread-three-bridges")
        let third = try await kit.respond(to: "Third prompt", threadID: "thread-three-bridges")

        let diagnostics = await kit.diagnostics(threadID: "thread-three-bridges")
        let seeds = await state.recordedSeeds()

        #expect(first.text == "First ok")
        #expect(second.text == "Second ok")
        #expect(third.text == "Third ok")
        #expect(diagnostics?.windowIndex == 3)
        #expect(diagnostics?.turnCount == 6)
        #expect(seeds.count == 4)
        #expect(seeds[2].instructions?.contains("First ok") == true)
        #expect(seeds[3].instructions?.contains("Second ok") == true)
    }

    @Test("Budget exhaustion reports in-flight bridge diagnostics")
    func budgetExhaustionUsesInflightDiagnostics() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(textResponses: [.failure(.exceededContextWindowSize("overflow-1"))]),
                ScriptedSessionHandle(textResponses: [.failure(.exceededContextWindowSize("overflow-2"))])
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                budget: BudgetPolicy(
                    reservedOutputTokens: 64,
                    preemptiveCompactionFraction: 0.78,
                    emergencyFraction: 0.90,
                    maxBridgeRetries: 1,
                    exactCountingPreferred: false,
                    heuristicSafetyMultiplier: 1.10,
                    defaultContextWindowTokens: 4096
                ),
                persistence: PersistencePolicy(
                    threads: InMemoryThreadStore(),
                    memories: InMemoryMemoryStore(),
                    blobs: InMemoryBlobStore()
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            ),
            sessionDriver: driver
        )

        try await kit.openThread(
            id: "thread-budget-exhaustion",
            configuration: ThreadConfiguration(instructions: "Keep responses brief.")
        )

        do {
            _ = try await kit.respond(
                to: "Oversized request",
                threadID: "thread-budget-exhaustion"
            )
            Issue.record("Expected budget exhaustion")
        } catch let error as LanguageModelContextKitError {
            switch error {
            case .budgetExhausted(let diagnostics):
                #expect(diagnostics.windowIndex == 1)
                #expect(diagnostics.lastBridge?.reason == "exceededContextWindowSize")
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Imported thread continues with respond")
    func importThreadContinuation() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(textResponses: [.success("Continued response")])
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)
        let importedTurns = [
            NormalizedTurn(
                role: .user,
                text: "Earlier question",
                createdAt: Date(timeIntervalSince1970: 10),
                priority: 950,
                windowIndex: 0
            ),
            NormalizedTurn(
                role: .assistant,
                text: "Earlier answer",
                createdAt: Date(timeIntervalSince1970: 20),
                priority: 800,
                windowIndex: 0
            )
        ]
        let importedMemories = [
            DurableMemoryRecord(
                kind: .fact,
                text: "Imported fact",
                priority: 900
            )
        ]

        try await kit.importThread(
            id: "thread-import",
            configuration: ThreadConfiguration(instructions: "Continue imported context."),
            turns: importedTurns,
            durableMemory: importedMemories,
            replaceExisting: true
        )

        let importedState = try await kit.threadState(threadID: "thread-import")
        #expect(importedState.turns.map(\.text) == ["Earlier question", "Earlier answer"])
        #expect(importedState.lastBudget == nil)
        #expect(importedState.lastCompaction == nil)
        #expect(importedState.lastBridge == nil)

        let response = try await kit.respond(
            to: "Follow up",
            threadID: "thread-import"
        )

        let seeds = await state.recordedSeeds()
        let finalState = try await kit.threadState(threadID: "thread-import")
        #expect(response.text == "Continued response")
        #expect(seeds.count == 1)
        #expect(seeds[0].instructions?.contains("Earlier answer") == true)
        #expect(finalState.turns.count == 4)
    }

    @Test("Appending turns invalidates live session and preserves continuity")
    func appendTurnsInvalidatesLiveSession() async throws {
        let state = FakeDriverState(
            sessions: [
                ScriptedSessionHandle(textResponses: [.success("First response")]),
                ScriptedSessionHandle(textResponses: [.success("Second response")])
            ]
        )
        let driver = FakeSessionDriver(state: state)
        let kit = makeKit(driver: driver)

        try await kit.openThread(
            id: "thread-append-turns",
            configuration: ThreadConfiguration(instructions: "Preserve continuity after external turns.")
        )

        _ = try await kit.respond(
            to: "First prompt",
            threadID: "thread-append-turns"
        )

        try await kit.appendTurns(
            [
                NormalizedTurn(
                    role: .tool,
                    text: "External tool result",
                    priority: 250,
                    tags: ["tool"],
                    windowIndex: 0
                )
            ],
            threadID: "thread-append-turns"
        )

        _ = try await kit.respond(
            to: "Second prompt",
            threadID: "thread-append-turns"
        )

        let seeds = await state.recordedSeeds()
        let finalState = try await kit.threadState(threadID: "thread-append-turns")
        #expect(seeds.count == 2)
        #expect(seeds[1].instructions?.contains("External tool result") == true)
        #expect(seeds[1].instructions?.contains("First response") == true)
        #expect(finalState.turns.count == 5)
    }

    @Test("Appending memories deduplicates by kind and text")
    func appendMemoriesDeduplicates() async throws {
        let kit = makeKit(driver: FakeSessionDriver())

        try await kit.openThread(
            id: "thread-append-memories",
            configuration: ThreadConfiguration(instructions: "Record durable memories.")
        )

        try await kit.appendMemories(
            [
                DurableMemoryRecord(kind: .fact, text: "Same fact", priority: 900),
                DurableMemoryRecord(kind: .decision, text: "Same fact", priority: 500)
            ],
            threadID: "thread-append-memories"
        )
        try await kit.appendMemories(
            [
                DurableMemoryRecord(kind: .fact, text: "Same fact", priority: 100),
                DurableMemoryRecord(kind: .fact, text: "New fact", priority: 400)
            ],
            threadID: "thread-append-memories"
        )

        let memories = try await kit.durableMemories(threadID: "thread-append-memories")
        #expect(memories.count == 3)
        #expect(memories.contains { $0.kind == .fact && $0.text == "Same fact" })
        #expect(memories.contains { $0.kind == .decision && $0.text == "Same fact" })
        #expect(memories.contains { $0.kind == .fact && $0.text == "New fact" })
    }

    @Test("Inspection APIs return persisted state")
    func inspectionApis() async throws {
        let kit = makeKit(driver: FakeSessionDriver())
        let importedTurns = [
            NormalizedTurn(
                role: .user,
                text: "Imported turn",
                createdAt: Date(timeIntervalSince1970: 1),
                priority: 950,
                windowIndex: 2
            )
        ]
        let importedMemories = [
            DurableMemoryRecord(
                kind: .fact,
                text: "Imported memory",
                priority: 900
            )
        ]

        try await kit.importThread(
            id: "thread-inspection",
            configuration: ThreadConfiguration(instructions: "Inspect imported state."),
            turns: importedTurns,
            durableMemory: importedMemories,
            replaceExisting: true
        )

        let state = try await kit.threadState(threadID: "thread-inspection")
        let memories = try await kit.durableMemories(threadID: "thread-inspection")
        #expect(state.turns.count == 1)
        #expect(state.activeWindowIndex == 2)
        #expect(memories.count == 1)
        #expect(memories.first?.text == "Imported memory")
    }

    @Test("Keyword retriever ranks overlapping memories")
    func keywordRetriever() async throws {
        let store = InMemoryMemoryStore()
        try await store.save(
            [
                DurableMemoryRecord(kind: .fact, text: "Uses Swift concurrency actors", priority: 900),
                DurableMemoryRecord(kind: .fact, text: "Uses JSON persistence", priority: 700),
                DurableMemoryRecord(kind: .fact, text: "Unrelated gardening note", priority: 100)
            ],
            threadID: "retrieval"
        )

        let retriever = KeywordRetriever(memoryStore: store)
        let results = try await retriever.retrieve(
            query: "Swift actors persistence",
            threadID: "retrieval",
            limit: 2
        )

        #expect(results.count == 2)
        #expect(results[0].text.contains("Swift"))
    }

    @Test("File-backed stores round trip")
    func fileStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let threadStore = FileThreadStore(directoryURL: root.appendingPathComponent("threads"))
        let memoryStore = FileMemoryStore(directoryURL: root.appendingPathComponent("memories"))
        let blobStore = FileBlobStore(directoryURL: root.appendingPathComponent("blobs"))

        let state = PersistedThreadState(
            threadID: "file-thread",
            instructions: "Persisted",
            localeIdentifier: "en_US",
            model: .default
        )
        let memory = DurableMemoryRecord(kind: .fact, text: "Persist this memory", priority: 900)
        let blobID = try await blobStore.put(Data("blob".utf8))

        try await threadStore.save(state, threadID: state.threadID)
        try await memoryStore.save([memory], threadID: state.threadID)

        let loadedState = try await threadStore.load(threadID: state.threadID)
        let loadedMemory = try await memoryStore.load(threadID: state.threadID)
        let loadedBlob = try await blobStore.get(blobID)

        #expect(loadedState?.threadID == state.threadID)
        #expect(loadedMemory.first?.text == memory.text)
        #expect(String(data: loadedBlob ?? Data(), encoding: .utf8) == "blob")
    }

    @Test("Fixture compaction preserves key state")
    func fixtureCompaction() throws {
        let bundle = Bundle.module
        let transcriptURL =
            bundle.url(forResource: "conversation", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "conversation", withExtension: "json")
        let expectedURL =
            bundle.url(forResource: "expected_compacted_state", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "expected_compacted_state", withExtension: "json")

        #expect(transcriptURL != nil)
        #expect(expectedURL != nil)

        let transcriptData = try Data(contentsOf: try #require(transcriptURL))
        let expectedData = try Data(contentsOf: try #require(expectedURL))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turns = try decoder.decode([NormalizedTurn].self, from: transcriptData)
        let expected = try decoder.decode(CompactedState.self, from: expectedData)

        let actual = SummaryReducerSupport.extractCompactedState(from: turns)
        #expect(actual.userConstraints == expected.userConstraints)
        #expect(actual.openTasks == expected.openTasks)
        #expect(Set(actual.stableFacts.map(\.key)) == Set(expected.stableFacts.map(\.key)))
        #expect(actual.blobReferences.isEmpty == false)
    }

    private func makeKit(driver: FakeSessionDriver) -> LanguageModelContextKit {
        LanguageModelContextKit(
            configuration: ContextManagerConfiguration(
                persistence: PersistencePolicy(
                    threads: InMemoryThreadStore(),
                    memories: InMemoryMemoryStore(),
                    blobs: InMemoryBlobStore()
                ),
                diagnostics: DiagnosticsPolicy(isEnabled: false, logToOSLog: false)
            ),
            sessionDriver: driver
        )
    }
}

private actor FakeDriverState {
    private var sessions: [any SessionHandle]
    private(set) var seeds: [SessionSeed] = []

    init(sessions: [any SessionHandle] = []) {
        self.sessions = sessions
    }

    func dequeue(seed: SessionSeed) -> (any SessionHandle)? {
        seeds.append(seed)
        guard !sessions.isEmpty else {
            return nil
        }
        return sessions.removeFirst()
    }

    func recordedSeeds() -> [SessionSeed] {
        seeds
    }
}

private struct FakeSessionDriver: SessionDriving {
    let availabilityValue: ModelAvailability
    let localeSupported: Bool
    let summaryText: String?
    let structuredSummaryValue: ModelCompactionSummary?
    let contextWindowTokensValue: Int?
    let exactBudgetEstimatorValue: (any ExactBudgetEstimating)?
    let state: FakeDriverState

    init(
        availabilityValue: ModelAvailability = .available,
        localeSupported: Bool = true,
        summaryText: String? = "summary",
        structuredSummaryValue: ModelCompactionSummary? = nil,
        contextWindowTokensValue: Int? = nil,
        exactBudgetEstimatorValue: (any ExactBudgetEstimating)? = nil,
        state: FakeDriverState = FakeDriverState()
    ) {
        self.availabilityValue = availabilityValue
        self.localeSupported = localeSupported
        self.summaryText = summaryText
        self.structuredSummaryValue = structuredSummaryValue
        self.contextWindowTokensValue = contextWindowTokensValue
        self.exactBudgetEstimatorValue = exactBudgetEstimatorValue
        self.state = state
    }

    func availability(for policy: ModelPolicy) -> ModelAvailability {
        availabilityValue
    }

    func supportsLocale(_ locale: Locale?, policy: ModelPolicy) -> Bool {
        localeSupported
    }

    func contextWindowTokens(for policy: ModelPolicy) -> Int? {
        contextWindowTokensValue
    }

    func exactBudgetEstimator(for policy: ModelPolicy) -> (any ExactBudgetEstimating)? {
        exactBudgetEstimatorValue
    }

    func makeSession(
        seed: SessionSeed,
        tools: [any Tool],
        policy: ModelPolicy
    ) async throws -> any SessionHandle {
        if let handle = await state.dequeue(seed: seed) {
            return handle
        }
        return ScriptedSessionHandle(textResponses: [.success("default response")])
    }

    func summarize(
        turns: [NormalizedTurn],
        policy: ModelPolicy,
        locale: Locale?,
        maximumResponseTokens: Int?
    ) async -> String? {
        summaryText
    }

    func summarizeStructured(
        turns: [NormalizedTurn],
        policy: ModelPolicy,
        locale: Locale?,
        maximumResponseTokens: Int?
    ) async -> ModelCompactionSummary? {
        structuredSummaryValue
    }
}

private actor ScriptedSessionHandle: SessionHandle {
    private var textResponses: [Result<String, SessionFailure>]
    private var structuredResponses: [Any]
    private var structuredTranscriptTexts: [String]
    private var structuredStreamScripts: [ScriptedStructuredStream]

    init(
        textResponses: [Result<String, SessionFailure>] = [],
        structuredResponses: [Any] = [],
        structuredTranscriptTexts: [String] = [],
        structuredStreamScripts: [ScriptedStructuredStream] = []
    ) {
        self.textResponses = textResponses
        self.structuredResponses = structuredResponses
        self.structuredTranscriptTexts = structuredTranscriptTexts
        self.structuredStreamScripts = structuredStreamScripts
    }

    func respondText(to prompt: String, maximumResponseTokens: Int?) async throws -> SessionTextResult {
        guard !textResponses.isEmpty else {
            return SessionTextResult(text: "default")
        }

        switch textResponses.removeFirst() {
        case .success(let value):
            return SessionTextResult(text: value)
        case .failure(let error):
            throw error
        }
    }

    func respondStructured<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        maximumResponseTokens: Int?
    ) async throws -> SessionStructuredResult<Content> {
        guard !structuredResponses.isEmpty else {
            throw SessionFailure.generationFailed("No structured response queued")
        }
        let value = structuredResponses.removeFirst()
        let transcript = structuredTranscriptTexts.isEmpty ? String(describing: value) : structuredTranscriptTexts.removeFirst()
        guard let typedValue = value as? Content else {
            throw SessionFailure.generationFailed("Type mismatch for structured response")
        }
        return SessionStructuredResult(content: typedValue, transcriptText: transcript)
    }

    func streamStructured<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        maximumResponseTokens: Int?
    ) async -> AsyncThrowingStream<SessionStructuredStreamEvent<Content>, Error> {
        let script = if structuredStreamScripts.isEmpty {
            ScriptedStructuredStream(
                finalContent: "default",
                finalTranscriptText: "\"default\""
            )
        } else {
            structuredStreamScripts.removeFirst()
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for (index, partial) in script.partials.enumerated() {
                        if script.stepDelayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: script.stepDelayNanoseconds)
                        }

                        let partialTranscriptText =
                            script.partialTranscriptTexts.indices.contains(index)
                            ? script.partialTranscriptTexts[index]
                            : String(describing: partial)
                        let partialRawContent =
                            script.partialRawContents.indices.contains(index)
                            ? script.partialRawContents[index]
                            : GeneratedContent(partialTranscriptText)
                        let partialContent: Content.PartiallyGenerated
                        if let typedPartial = partial as? Content.PartiallyGenerated {
                            partialContent = typedPartial
                        } else {
                            partialContent = try Content(partialRawContent).asPartiallyGenerated()
                        }

                        continuation.yield(
                            .partial(
                                SessionStructuredStreamPartial(
                                    content: partialContent,
                                    transcriptText: partialTranscriptText,
                                    rawContent: partialRawContent
                                )
                            )
                        )
                    }

                    if script.stepDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: script.stepDelayNanoseconds)
                    }

                    if let failure = script.failure {
                        continuation.finish(throwing: failure)
                        return
                    }

                    guard let finalContent = script.finalContent as? Content else {
                        throw SessionFailure.generationFailed("Type mismatch for streaming final content")
                    }

                    continuation.yield(
                        .completed(
                            SessionStructuredResult(
                                content: finalContent,
                                transcriptText: script.finalTranscriptText
                            )
                        )
                    )
                    continuation.finish()
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
}

private struct ScriptedStructuredStream: @unchecked Sendable {
    var partials: [Any] = []
    var partialTranscriptTexts: [String] = []
    var partialRawContents: [GeneratedContent] = []
    var finalContent: Any
    var finalTranscriptText: String
    var failure: SessionFailure? = nil
    var stepDelayNanoseconds: UInt64 = 0
}

private actor StreamProbe {
    private var value: String?

    func record(_ value: String) {
        self.value = value
    }

    func lastValue() -> String? {
        value
    }
}

private actor InspectableBlobStore: BlobStore {
    private var storage: [UUID: Data] = [:]

    func put(_ data: Data) async throws -> UUID {
        let id = UUID()
        storage[id] = data
        return id
    }

    func get(_ id: UUID) async throws -> Data? {
        storage[id]
    }

    func delete(_ id: UUID) async throws {
        storage.removeValue(forKey: id)
    }

    func count() -> Int {
        storage.count
    }
}

private struct FixedExactBudgetEstimator: ExactBudgetEstimating {
    let estimatedInputTokens: Int
    let breakdown: [BudgetComponent: Int]

    func estimate(
        snapshot: ContextSnapshot,
        budgetPolicy: BudgetPolicy,
        contextWindowTokens: Int
    ) -> BudgetReport? {
        BudgetReport(
            accuracy: .exact,
            contextWindowTokens: contextWindowTokens,
            estimatedInputTokens: estimatedInputTokens,
            reservedOutputTokens: budgetPolicy.reservedOutputTokens,
            projectedTotalTokens: estimatedInputTokens + budgetPolicy.reservedOutputTokens,
            softLimitTokens: Int(Double(contextWindowTokens) * budgetPolicy.preemptiveCompactionFraction),
            emergencyLimitTokens: Int(Double(contextWindowTokens) * budgetPolicy.emergencyFraction),
            breakdown: breakdown.merging([.outputReserve: budgetPolicy.reservedOutputTokens]) { current, _ in current }
        )
    }
}
