@testable import LanguageModelContextKit
import Foundation
import FoundationModels
import Testing

@Suite("LanguageModelContextKit")
struct LanguageModelContextKitTests {
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

        let budget = counter.estimate(snapshot: snapshot, budgetPolicy: .default)
        #expect(budget.accuracy == .approximate)
        #expect(budget.estimatedInputTokens > 0)
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
}

private struct FakeSessionDriver: SessionDriving {
    let availabilityValue: ModelAvailability
    let localeSupported: Bool
    let summaryText: String?
    let state: FakeDriverState

    init(
        availabilityValue: ModelAvailability = .available,
        localeSupported: Bool = true,
        summaryText: String? = "summary",
        state: FakeDriverState = FakeDriverState()
    ) {
        self.availabilityValue = availabilityValue
        self.localeSupported = localeSupported
        self.summaryText = summaryText
        self.state = state
    }

    func availability(for policy: ModelPolicy) -> ModelAvailability {
        availabilityValue
    }

    func supportsLocale(_ locale: Locale?, policy: ModelPolicy) -> Bool {
        localeSupported
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
        locale: Locale?
    ) async -> String? {
        summaryText
    }
}

private actor ScriptedSessionHandle: SessionHandle {
    private var textResponses: [Result<String, SessionFailure>]
    private var structuredResponses: [Any]
    private var structuredTranscriptTexts: [String]

    init(
        textResponses: [Result<String, SessionFailure>] = [],
        structuredResponses: [Any] = [],
        structuredTranscriptTexts: [String] = []
    ) {
        self.textResponses = textResponses
        self.structuredResponses = structuredResponses
        self.structuredTranscriptTexts = structuredTranscriptTexts
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
}
