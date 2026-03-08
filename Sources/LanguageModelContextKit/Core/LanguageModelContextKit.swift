import Foundation
import FoundationModels

public actor LanguageModelContextKit {
    private let configuration: ContextManagerConfiguration
    private let sessionDriver: any SessionDriving
    private let tokenCounterFactory: TokenCounterFactory
    private let logger: DiagnosticsLogger
    private let bridgeSeedBuilder = BridgeSeedBuilder()

    private var threads: [String: LogicalThread] = [:]
    private var liveSessions: [String: WindowSession] = [:]

    public init(configuration: ContextManagerConfiguration = .default) {
        self.configuration = configuration
        self.sessionDriver = AppleSessionDriver()
        self.tokenCounterFactory = TokenCounterFactory()
        self.logger = DiagnosticsLogger(policy: configuration.diagnostics)
    }

    init(
        configuration: ContextManagerConfiguration,
        sessionDriver: any SessionDriving,
        tokenCounterFactory: TokenCounterFactory = TokenCounterFactory()
    ) {
        self.configuration = configuration
        self.sessionDriver = sessionDriver
        self.tokenCounterFactory = tokenCounterFactory
        self.logger = DiagnosticsLogger(policy: configuration.diagnostics)
    }

    public func availabilityStatus(for policy: ModelPolicy = .default) async -> AvailabilityStatus {
        sessionDriver.availability(for: policy).publicStatus
    }

    public func supportsLocale(
        _ locale: Locale?,
        policy: ModelPolicy = .default
    ) async -> Bool {
        sessionDriver.supportsLocale(locale, policy: policy)
    }

    public func openThread(
        id: String,
        configuration threadConfiguration: ThreadConfiguration
    ) async throws {
        let persisted = try await self.configuration.persistence.threads.load(threadID: id)
        let state = persisted ?? PersistedThreadState(
            threadID: id,
            instructions: threadConfiguration.instructions,
            localeIdentifier: threadConfiguration.locale?.identifier,
            model: threadConfiguration.model
        )

        var updatedState = state
        updatedState.instructions = threadConfiguration.instructions
        updatedState.localeIdentifier = threadConfiguration.locale?.identifier
        updatedState.model = threadConfiguration.model
        updatedState.updatedAt = Date()

        threads[id] = LogicalThread(state: updatedState, configuration: threadConfiguration)
        liveSessions.removeValue(forKey: id)
        try await self.configuration.persistence.threads.save(updatedState, threadID: id)
    }

    public func importThread(
        id: String,
        configuration threadConfiguration: ThreadConfiguration,
        turns: [NormalizedTurn],
        durableMemory: [DurableMemoryRecord],
        replaceExisting: Bool = false
    ) async throws {
        let existingState = try await loadedThreadState(threadID: id)
        let existingMemories = replaceExisting ? [] : try await configuration.persistence.memories.load(threadID: id)
        let combinedTurns = replaceExisting ? turns : (existingState?.turns ?? []) + turns
        let sortedTurns = deduplicatedImportedTurns(combinedTurns)
        let createdAt = existingState?.createdAt ?? Date()
        let activeWindowIndex = max(
            existingState?.activeWindowIndex ?? 0,
            sortedTurns.map(\.windowIndex).max() ?? 0
        )
        let state = PersistedThreadState(
            threadID: id,
            instructions: threadConfiguration.instructions,
            localeIdentifier: threadConfiguration.locale?.identifier,
            model: threadConfiguration.model,
            activeWindowIndex: activeWindowIndex,
            turns: sortedTurns,
            lastBudget: nil,
            lastCompaction: nil,
            lastBridge: nil,
            createdAt: createdAt,
            updatedAt: Date()
        )
        let logicalThread = LogicalThread(state: state, configuration: threadConfiguration)
        let mergedMemories = deduplicatedMemories(
            replaceExisting ? durableMemory : existingMemories + durableMemory
        )

        threads[id] = logicalThread
        liveSessions.removeValue(forKey: id)
        try await persist(thread: logicalThread, durableMemory: mergedMemories)
    }

    public func appendTurns(
        _ turns: [NormalizedTurn],
        threadID: String
    ) async throws {
        var state = try await requireThreadState(threadID: threadID)
        state.turns.append(contentsOf: turns)
        state.turns.sort(by: Self.sortTurnsByCreatedAt)
        state.activeWindowIndex = max(
            state.activeWindowIndex,
            turns.map(\.windowIndex).max() ?? state.activeWindowIndex
        )
        state.updatedAt = Date()

        try await saveThreadState(state, threadID: threadID)
        liveSessions.removeValue(forKey: threadID)
    }

    public func appendMemories(
        _ records: [DurableMemoryRecord],
        threadID: String,
        deduplicate: Bool = true
    ) async throws {
        var state = try await requireThreadState(threadID: threadID)
        let existingMemories = try await configuration.persistence.memories.load(threadID: threadID)
        let combinedMemories = deduplicate
            ? deduplicatedMemories(existingMemories + records)
            : existingMemories + records

        state.updatedAt = Date()

        try await saveThreadState(state, threadID: threadID)
        try await saveMemories(combinedMemories, threadID: threadID)
        liveSessions.removeValue(forKey: threadID)
    }

    public func threadState(
        threadID: String
    ) async throws -> PersistedThreadState {
        try await requireThreadState(threadID: threadID)
    }

    public func durableMemories(
        threadID: String
    ) async throws -> [DurableMemoryRecord] {
        _ = try await requireThreadState(threadID: threadID)
        return try await configuration.persistence.memories.load(threadID: threadID)
    }

    public func estimateBudget(
        for prompt: String,
        threadID: String
    ) async throws -> BudgetReport {
        let logicalThread = try await requireThread(threadID)
        try await validateAvailability(for: logicalThread)
        return try await calculateBudget(
            for: logicalThread,
            prompt: prompt,
            schemaDescription: nil
        )
    }

    public func respond(
        to prompt: String,
        threadID: String
    ) async throws -> ManagedTextResponse {
        let logicalThread = try await requireThread(threadID)
        try await validateAvailability(for: logicalThread)
        var prepared = try await preparePlan(
            for: logicalThread,
            prompt: prompt,
            schemaDescription: nil,
            compactionOptions: .standard(memoryPolicy: configuration.memory)
        )

        var bridge = prepared.bridge
        var attempts = 0

        while true {
            do {
                let session = try await session(
                    for: prepared.thread,
                    durableMemory: prepared.plan.durableMemory,
                    recentTail: prepared.plan.recentTail,
                    forceBridge: prepared.plan.requiresBridge || bridge != nil
                )

                let result = try await session.respondText(
                    to: prompt,
                    maximumResponseTokens: configuration.budget.reservedOutputTokens
                )

                return try await finalizeTextResponse(
                    prompt: prompt,
                    text: result.text,
                    prepared: &prepared,
                    bridge: bridge
                )
            } catch let failure as SessionFailure {
                switch failure {
                case .exceededContextWindowSize:
                    guard attempts < configuration.budget.maxBridgeRetries else {
                        let diagnostics = makeDiagnostics(
                            threadID: threadID,
                            state: prepared.thread.state,
                            durableMemory: prepared.plan.durableMemory,
                            budget: prepared.plan.budget,
                            compaction: makeCompactionReport(from: prepared.plan),
                            bridge: bridge
                        )
                        throw LanguageModelContextKitError.budgetExhausted(diagnostics)
                    }
                    attempts += 1
                    prepared.plan.requiresBridge = true
                    prepared.thread.state.activeWindowIndex += 1
                    bridge = BridgeReport(
                        fromWindowIndex: max(0, prepared.thread.state.activeWindowIndex - 1),
                        toWindowIndex: prepared.thread.state.activeWindowIndex,
                        reason: "exceededContextWindowSize",
                        carriedTurnCount: prepared.plan.recentTail.count,
                        summaryUsed: prepared.plan.summaryCreated
                    )
                    liveSessions.removeValue(forKey: threadID)
                    continue
                case .unsupportedLocale(let message):
                    throw LanguageModelContextKitError.unsupportedLocale(message)
                case .refusal(let message):
                    throw LanguageModelContextKitError.refusal(message)
                case .generationFailed(let message):
                    throw LanguageModelContextKitError.generationFailed(message)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelContextKitError {
                throw error
            } catch {
                throw LanguageModelContextKitError.generationFailed(error.localizedDescription)
            }
        }
    }

    public func respondManaged<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        threadID: String,
        includeSchemaInPrompt: Bool? = nil,
        transcriptRenderer: (@Sendable (Content) -> String)? = nil
    ) async throws -> ManagedStructuredResponse<Content> {
        let logicalThread = try await requireThread(threadID)
        try await validateAvailability(for: logicalThread)
        let schemaDescription = String(describing: Content.self)
        var prepared = try await preparePlan(
            for: logicalThread,
            prompt: prompt,
            schemaDescription: schemaDescription,
            compactionOptions: .standard(memoryPolicy: configuration.memory)
        )

        var bridge = prepared.bridge
        var attempts = 0

        while true {
            do {
                let session = try await session(
                    for: prepared.thread,
                    durableMemory: prepared.plan.durableMemory,
                    recentTail: prepared.plan.recentTail,
                    forceBridge: prepared.plan.requiresBridge || bridge != nil
                )

                let result = try await session.respondStructured(
                    to: prompt,
                    generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt ?? true,
                    maximumResponseTokens: configuration.budget.reservedOutputTokens
                )

                return try await finalizeStructuredResponse(
                    prompt: prompt,
                    result: result,
                    prepared: &prepared,
                    bridge: bridge,
                    transcriptRenderer: transcriptRenderer
                )
            } catch let failure as SessionFailure {
                switch failure {
                case .exceededContextWindowSize:
                    guard attempts < configuration.budget.maxBridgeRetries else {
                        let diagnostics = makeDiagnostics(
                            threadID: threadID,
                            state: prepared.thread.state,
                            durableMemory: prepared.plan.durableMemory,
                            budget: prepared.plan.budget,
                            compaction: makeCompactionReport(from: prepared.plan),
                            bridge: bridge
                        )
                        throw LanguageModelContextKitError.budgetExhausted(diagnostics)
                    }
                    attempts += 1
                    prepared.plan.requiresBridge = true
                    prepared.thread.state.activeWindowIndex += 1
                    bridge = BridgeReport(
                        fromWindowIndex: max(0, prepared.thread.state.activeWindowIndex - 1),
                        toWindowIndex: prepared.thread.state.activeWindowIndex,
                        reason: "exceededContextWindowSize",
                        carriedTurnCount: prepared.plan.recentTail.count,
                        summaryUsed: prepared.plan.summaryCreated
                    )
                    liveSessions.removeValue(forKey: threadID)
                    continue
                case .unsupportedLocale(let message):
                    throw LanguageModelContextKitError.unsupportedLocale(message)
                case .refusal(let message):
                    throw LanguageModelContextKitError.refusal(message)
                case .generationFailed(let message):
                    throw LanguageModelContextKitError.generationFailed(message)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelContextKitError {
                throw error
            } catch {
                throw LanguageModelContextKitError.generationFailed(error.localizedDescription)
            }
        }
    }

    public func respond<T: Generable>(
        to prompt: String,
        generating type: T.Type,
        threadID: String,
        includeSchemaInPrompt: Bool? = nil,
        transcriptRenderer: (@Sendable (T) -> String)? = nil
    ) async throws -> T {
        try await respondManaged(
            to: prompt,
            generating: type,
            threadID: threadID,
            includeSchemaInPrompt: includeSchemaInPrompt,
            transcriptRenderer: transcriptRenderer
        ).content
    }

    public func streamText(
        to prompt: String,
        threadID: String
    ) -> AsyncThrowingStream<ManagedTextStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamText(
                        to: prompt,
                        threadID: threadID,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func streamManaged<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        threadID: String,
        includeSchemaInPrompt: Bool? = nil,
        transcriptRenderer: (@Sendable (Content) -> String)? = nil
    ) -> AsyncThrowingStream<ManagedStructuredStreamEvent<Content>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamManaged(
                        to: prompt,
                        generating: type,
                        threadID: threadID,
                        includeSchemaInPrompt: includeSchemaInPrompt,
                        transcriptRenderer: transcriptRenderer,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func compact(
        threadID: String
    ) async throws -> CompactionReport {
        let logicalThread = try await requireThread(threadID)
        var prepared = try await preparePlan(
            for: logicalThread,
            prompt: "Manual compaction request",
            schemaDescription: nil,
            compactionOptions: .manual(memoryPolicy: configuration.memory)
        )
        prepared.plan.requiresBridge = true
        let report = makeCompactionReport(from: prepared.plan)
            ?? CompactionReport(
                mode: configuration.compaction.mode,
                tokensBefore: prepared.plan.budget.projectedTotalTokens,
                tokensAfter: prepared.plan.budget.projectedTotalTokens,
                reducersApplied: [],
                summaryCreated: false,
                spilledBlobCount: 0
            )
        prepared.thread.state.lastCompaction = report
        try await persist(thread: prepared.thread, durableMemory: prepared.plan.durableMemory)
        threads[threadID] = prepared.thread
        liveSessions.removeValue(forKey: threadID)
        return report
    }

    public func diagnostics(
        threadID: String
    ) async -> ThreadDiagnostics? {
        guard let logicalThread = threads[threadID] else {
            guard let persisted = try? await configuration.persistence.threads.load(threadID: threadID) else {
                return nil
            }
            let memories = (try? await configuration.persistence.memories.load(threadID: threadID)) ?? []
            return ThreadDiagnostics(
                threadID: threadID,
                windowIndex: persisted.activeWindowIndex,
                lastBudget: persisted.lastBudget,
                lastCompaction: persisted.lastCompaction,
                lastBridge: persisted.lastBridge,
                turnCount: persisted.turns.count,
                durableMemoryCount: memories.count,
                blobCount: uniqueBlobCount(in: persisted.turns, memories: memories)
            )
        }

        let memories = (try? await configuration.persistence.memories.load(threadID: threadID)) ?? []
        return ThreadDiagnostics(
            threadID: threadID,
            windowIndex: logicalThread.state.activeWindowIndex,
            lastBudget: logicalThread.state.lastBudget,
            lastCompaction: logicalThread.state.lastCompaction,
            lastBridge: logicalThread.state.lastBridge,
            turnCount: logicalThread.state.turns.count,
            durableMemoryCount: memories.count,
            blobCount: uniqueBlobCount(in: logicalThread.state.turns, memories: memories)
        )
    }

    public func resetThread(
        threadID: String
    ) async throws {
        let persisted = try await configuration.persistence.threads.load(threadID: threadID)
        guard threads[threadID] != nil || persisted != nil else {
            throw LanguageModelContextKitError.threadNotFound(threadID)
        }
        let currentState = threads[threadID]?.state ?? persisted
        let memories = (try? await configuration.persistence.memories.load(threadID: threadID)) ?? []
        if let currentState {
            try await deleteBlobs(ids: Set(currentState.turns.flatMap(\.blobIDs) + memories.flatMap(\.blobIDs)))
        }
        threads.removeValue(forKey: threadID)
        liveSessions.removeValue(forKey: threadID)
        try await configuration.persistence.threads.delete(threadID: threadID)
        try await configuration.persistence.memories.deleteAll(threadID: threadID)
    }

    private func loadedThreadState(
        threadID: String
    ) async throws -> PersistedThreadState? {
        if let thread = threads[threadID] {
            return thread.state
        }
        return try await configuration.persistence.threads.load(threadID: threadID)
    }

    private func requireThreadState(
        threadID: String
    ) async throws -> PersistedThreadState {
        guard let state = try await loadedThreadState(threadID: threadID) else {
            throw LanguageModelContextKitError.threadNotFound(threadID)
        }
        return state
    }

    private func finalizeTextResponse(
        prompt: String,
        text: String,
        prepared: inout PreparedRequest,
        bridge: BridgeReport?
    ) async throws -> ManagedTextResponse {
        try Task.checkCancellation()
        let compaction = makeCompactionReport(from: prepared.plan)
        let response = ManagedTextResponse(
            text: text,
            budget: prepared.plan.budget,
            compaction: compaction,
            bridge: bridge
        )

        capture(
            prompt: prompt,
            responseText: text,
            thread: &prepared.thread,
            budget: prepared.plan.budget,
            compaction: compaction,
            bridge: bridge
        )
        try await persist(thread: prepared.thread, durableMemory: prepared.plan.durableMemory)
        return response
    }

    private func finalizeStructuredResponse<Content: Generable>(
        prompt: String,
        result: SessionStructuredResult<Content>,
        prepared: inout PreparedRequest,
        bridge: BridgeReport?,
        transcriptRenderer: (@Sendable (Content) -> String)?
    ) async throws -> ManagedStructuredResponse<Content> {
        try Task.checkCancellation()
        let compaction = makeCompactionReport(from: prepared.plan)
        let response = ManagedStructuredResponse(
            content: result.content,
            transcriptText: result.transcriptText,
            budget: prepared.plan.budget,
            compaction: compaction,
            bridge: bridge
        )

        capture(
            prompt: prompt,
            responseText: persistedAssistantText(
                content: result.content,
                transcriptText: result.transcriptText,
                transcriptRenderer: transcriptRenderer
            ),
            thread: &prepared.thread,
            budget: prepared.plan.budget,
            compaction: compaction,
            bridge: bridge
        )
        try await persist(thread: prepared.thread, durableMemory: prepared.plan.durableMemory)
        return response
    }

    private func streamText(
        to prompt: String,
        threadID: String,
        continuation: AsyncThrowingStream<ManagedTextStreamEvent, Error>.Continuation
    ) async throws {
        let logicalThread = try await requireThread(threadID)
        try await validateAvailability(for: logicalThread)
        var prepared = try await preparePlan(
            for: logicalThread,
            prompt: prompt,
            schemaDescription: String(describing: GeneratedTextEnvelope.self),
            compactionOptions: .standard(memoryPolicy: configuration.memory)
        )

        var bridge = prepared.bridge
        var attempts = 0

        while true {
            try Task.checkCancellation()

            do {
                let session = try await session(
                    for: prepared.thread,
                    durableMemory: prepared.plan.durableMemory,
                    recentTail: prepared.plan.recentTail,
                    forceBridge: prepared.plan.requiresBridge || bridge != nil
                )

                let stream = await session.streamStructured(
                    to: prompt,
                    generating: GeneratedTextEnvelope.self,
                    includeSchemaInPrompt: true,
                    maximumResponseTokens: configuration.budget.reservedOutputTokens
                )

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .partial(let partial):
                        guard let text = generatedText(from: partial.rawContent) else {
                            continue
                        }
                        continuation.yield(.partial(text: text))
                    case .completed(let result):
                        let response = try await finalizeStructuredResponse(
                            prompt: prompt,
                            result: result,
                            prepared: &prepared,
                            bridge: bridge,
                            transcriptRenderer: { $0.text }
                        )
                        continuation.yield(.completed(managedTextResponse(from: response)))
                        return
                    }
                }

                throw LanguageModelContextKitError.generationFailed("Streaming finished without completion")
            } catch let failure as SessionFailure {
                switch failure {
                case .exceededContextWindowSize:
                    guard attempts < configuration.budget.maxBridgeRetries else {
                        let diagnostics = makeDiagnostics(
                            threadID: threadID,
                            state: prepared.thread.state,
                            durableMemory: prepared.plan.durableMemory,
                            budget: prepared.plan.budget,
                            compaction: makeCompactionReport(from: prepared.plan),
                            bridge: bridge
                        )
                        throw LanguageModelContextKitError.budgetExhausted(diagnostics)
                    }
                    attempts += 1
                    prepared.plan.requiresBridge = true
                    prepared.thread.state.activeWindowIndex += 1
                    bridge = BridgeReport(
                        fromWindowIndex: max(0, prepared.thread.state.activeWindowIndex - 1),
                        toWindowIndex: prepared.thread.state.activeWindowIndex,
                        reason: "exceededContextWindowSize",
                        carriedTurnCount: prepared.plan.recentTail.count,
                        summaryUsed: prepared.plan.summaryCreated
                    )
                    liveSessions.removeValue(forKey: threadID)
                    continue
                case .unsupportedLocale(let message):
                    throw LanguageModelContextKitError.unsupportedLocale(message)
                case .refusal(let message):
                    throw LanguageModelContextKitError.refusal(message)
                case .generationFailed(let message):
                    throw LanguageModelContextKitError.generationFailed(message)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelContextKitError {
                throw error
            } catch {
                throw LanguageModelContextKitError.generationFailed(error.localizedDescription)
            }
        }
    }

    private func streamManaged<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        threadID: String,
        includeSchemaInPrompt: Bool?,
        transcriptRenderer: (@Sendable (Content) -> String)?,
        continuation: AsyncThrowingStream<ManagedStructuredStreamEvent<Content>, Error>.Continuation
    ) async throws {
        let logicalThread = try await requireThread(threadID)
        try await validateAvailability(for: logicalThread)
        var prepared = try await preparePlan(
            for: logicalThread,
            prompt: prompt,
            schemaDescription: String(describing: Content.self),
            compactionOptions: .standard(memoryPolicy: configuration.memory)
        )

        var bridge = prepared.bridge
        var attempts = 0

        while true {
            try Task.checkCancellation()

            do {
                let session = try await session(
                    for: prepared.thread,
                    durableMemory: prepared.plan.durableMemory,
                    recentTail: prepared.plan.recentTail,
                    forceBridge: prepared.plan.requiresBridge || bridge != nil
                )

                let stream = await session.streamStructured(
                    to: prompt,
                    generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt ?? true,
                    maximumResponseTokens: configuration.budget.reservedOutputTokens
                )

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .partial(let partial):
                        continuation.yield(
                            .partial(
                                content: partial.content,
                                transcriptText: partial.transcriptText
                            )
                        )
                    case .completed(let result):
                        let response = try await finalizeStructuredResponse(
                            prompt: prompt,
                            result: result,
                            prepared: &prepared,
                            bridge: bridge,
                            transcriptRenderer: transcriptRenderer
                        )
                        continuation.yield(.completed(response))
                        return
                    }
                }

                throw LanguageModelContextKitError.generationFailed("Streaming finished without completion")
            } catch let failure as SessionFailure {
                switch failure {
                case .exceededContextWindowSize:
                    guard attempts < configuration.budget.maxBridgeRetries else {
                        let diagnostics = makeDiagnostics(
                            threadID: threadID,
                            state: prepared.thread.state,
                            durableMemory: prepared.plan.durableMemory,
                            budget: prepared.plan.budget,
                            compaction: makeCompactionReport(from: prepared.plan),
                            bridge: bridge
                        )
                        throw LanguageModelContextKitError.budgetExhausted(diagnostics)
                    }
                    attempts += 1
                    prepared.plan.requiresBridge = true
                    prepared.thread.state.activeWindowIndex += 1
                    bridge = BridgeReport(
                        fromWindowIndex: max(0, prepared.thread.state.activeWindowIndex - 1),
                        toWindowIndex: prepared.thread.state.activeWindowIndex,
                        reason: "exceededContextWindowSize",
                        carriedTurnCount: prepared.plan.recentTail.count,
                        summaryUsed: prepared.plan.summaryCreated
                    )
                    liveSessions.removeValue(forKey: threadID)
                    continue
                case .unsupportedLocale(let message):
                    throw LanguageModelContextKitError.unsupportedLocale(message)
                case .refusal(let message):
                    throw LanguageModelContextKitError.refusal(message)
                case .generationFailed(let message):
                    throw LanguageModelContextKitError.generationFailed(message)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelContextKitError {
                throw error
            } catch {
                throw LanguageModelContextKitError.generationFailed(error.localizedDescription)
            }
        }
    }

    private func calculateBudget(
        for logicalThread: LogicalThread,
        prompt: String,
        schemaDescription: String?
    ) async throws -> BudgetReport {
        let durableMemory = try await configuration.persistence.memories.load(threadID: logicalThread.state.threadID)
        let retrievedMemory = try await configuration.persistence.retriever?.retrieve(
            query: prompt,
            threadID: logicalThread.state.threadID,
            limit: configuration.memory.retrievalLimit
        ) ?? []
        let snapshot = ContextSnapshot(
            instructions: logicalThread.state.instructions,
            toolDescriptions: logicalThread.configuration.tools.map { ToolDescriptor.describe($0) },
            durableMemory: durableMemory,
            retrievedMemory: retrievedMemory,
            recentTail: recentTail(from: logicalThread.state.turns),
            currentPrompt: prompt,
            schemaDescription: schemaDescription
        )
        let tokenCounter = tokenCounterFactory.make(
            preferExact: configuration.budget.exactCountingPreferred,
            exactEstimator: sessionDriver.exactBudgetEstimator(for: logicalThread.configuration.model)
        )
        return tokenCounter.estimate(
            snapshot: snapshot,
            budgetPolicy: configuration.budget,
            contextWindowTokens: resolvedContextWindowTokens(for: logicalThread.configuration.model)
        )
    }

    private func requireThread(_ threadID: String) async throws -> LogicalThread {
        if let thread = threads[threadID] {
            return thread
        }
        throw LanguageModelContextKitError.threadNotFound(threadID)
    }

    private func preparePlan(
        for logicalThread: LogicalThread,
        prompt: String,
        schemaDescription: String?,
        compactionOptions: CompactionOptions
    ) async throws -> PreparedRequest {
        var thread = logicalThread
        var durableMemory = try await configuration.persistence.memories.load(threadID: thread.state.threadID)
        let retrievedMemory = try await configuration.persistence.retriever?.retrieve(
            query: prompt,
            threadID: thread.state.threadID,
            limit: configuration.memory.retrievalLimit
        ) ?? []
        let recentTail = recentTail(from: thread.state.turns)
        let exactBudgetEstimator = sessionDriver.exactBudgetEstimator(for: thread.configuration.model)
        let contextWindowTokens = resolvedContextWindowTokens(for: thread.configuration.model)
        let tokenCounter = tokenCounterFactory.make(
            preferExact: configuration.budget.exactCountingPreferred,
            exactEstimator: exactBudgetEstimator
        )
        let snapshot = ContextSnapshot(
            instructions: thread.state.instructions,
            toolDescriptions: thread.configuration.tools.map { ToolDescriptor.describe($0) },
            durableMemory: durableMemory,
            retrievedMemory: retrievedMemory,
            recentTail: recentTail,
            currentPrompt: prompt,
            schemaDescription: schemaDescription
        )
        var plan = ContextPlan(
            state: thread.state,
            durableMemory: durableMemory,
            retrievedMemory: retrievedMemory,
            recentTail: recentTail,
            currentPrompt: prompt,
            schemaDescription: schemaDescription,
            budget: tokenCounter.estimate(
                snapshot: snapshot,
                budgetPolicy: configuration.budget,
                contextWindowTokens: contextWindowTokens
            ),
            originalProjectedTotalTokens: nil
        )

        let compactor = ThreadCompactor(
            configuration: configuration,
            tokenCounterFactory: tokenCounterFactory,
            sessionDriver: sessionDriver,
            logger: logger
        )
        plan = try await compactor.compact(
            plan: plan,
            threadConfiguration: thread.configuration,
            options: compactionOptions,
            contextWindowTokens: contextWindowTokens,
            exactBudgetEstimator: exactBudgetEstimator
        )
        durableMemory = plan.durableMemory
        thread.state = plan.state

        var bridge: BridgeReport?
        if liveSessions[thread.state.threadID] == nil && (!thread.state.turns.isEmpty || !durableMemory.isEmpty) {
            bridge = BridgeReport(
                fromWindowIndex: max(0, thread.state.activeWindowIndex - 1),
                toWindowIndex: thread.state.activeWindowIndex,
                reason: "rehydrate",
                carriedTurnCount: plan.recentTail.count,
                summaryUsed: plan.summaryCreated
            )
            plan.requiresBridge = true
        }

        return PreparedRequest(thread: thread, plan: plan, bridge: bridge)
    }

    private func validateAvailability(for logicalThread: LogicalThread) async throws {
        switch sessionDriver.availability(for: logicalThread.configuration.model) {
        case .available:
            break
        case .unavailable(let reason):
            throw LanguageModelContextKitError.modelUnavailable(reason)
        }

        if !sessionDriver.supportsLocale(logicalThread.configuration.locale, policy: logicalThread.configuration.model) {
            throw LanguageModelContextKitError.unsupportedLocale(
                "Locale \(logicalThread.configuration.locale?.identifier ?? Locale.current.identifier) is unsupported"
            )
        }
    }

    private func session(
        for thread: LogicalThread,
        durableMemory: [DurableMemoryRecord],
        recentTail: [NormalizedTurn],
        forceBridge: Bool
    ) async throws -> any SessionHandle {
        if !forceBridge, let existing = liveSessions[thread.state.threadID] {
            return existing.handle
        }

        let seed = bridgeSeedBuilder.makeSeed(
            for: thread.state,
            durableMemory: durableMemory,
            recentTail: recentTail
        )
        let handle = try await sessionDriver.makeSession(
            seed: seed,
            tools: thread.configuration.tools,
            policy: thread.configuration.model
        )
        liveSessions[thread.state.threadID] = WindowSession(
            windowIndex: thread.state.activeWindowIndex,
            handle: handle
        )
        return handle
    }

    private func recentTail(from turns: [NormalizedTurn]) -> [NormalizedTurn] {
        let visible = turns.filter { !$0.compacted || $0.role == .summary }
        return Array(visible.suffix(configuration.compaction.maxRecentTurns))
    }

    private func makeDiagnostics(
        threadID: String,
        state: PersistedThreadState,
        durableMemory: [DurableMemoryRecord],
        budget: BudgetReport?,
        compaction: CompactionReport?,
        bridge: BridgeReport?
    ) -> ThreadDiagnostics {
        ThreadDiagnostics(
            threadID: threadID,
            windowIndex: state.activeWindowIndex,
            lastBudget: budget,
            lastCompaction: compaction,
            lastBridge: bridge,
            turnCount: state.turns.count,
            durableMemoryCount: durableMemory.count,
            blobCount: uniqueBlobCount(in: state.turns, memories: durableMemory)
        )
    }

    private func capture(
        prompt: String,
        responseText: String,
        thread: inout LogicalThread,
        budget: BudgetReport,
        compaction: CompactionReport?,
        bridge: BridgeReport?
    ) {
        let windowIndex = thread.state.activeWindowIndex
        thread.state.turns.append(
            NormalizedTurn(
                role: .user,
                text: prompt,
                priority: 950,
                tags: ["prompt"],
                windowIndex: windowIndex
            )
        )
        thread.state.turns.append(
            NormalizedTurn(
                role: .assistant,
                text: responseText,
                priority: 800,
                tags: ["response"],
                windowIndex: windowIndex
            )
        )
        thread.state.lastBudget = budget
        thread.state.lastCompaction = compaction
        thread.state.lastBridge = bridge
        thread.state.updatedAt = Date()

        threads[thread.state.threadID] = thread
    }

    private func persist(
        thread: LogicalThread,
        durableMemory: [DurableMemoryRecord]
    ) async throws {
        try await saveThreadState(thread.state, threadID: thread.state.threadID)
        try await saveMemories(durableMemory, threadID: thread.state.threadID)
    }

    private func saveThreadState(
        _ state: PersistedThreadState,
        threadID: String
    ) async throws {
        do {
            try await configuration.persistence.threads.save(state, threadID: threadID)
            if var thread = threads[threadID] {
                thread.state = state
                threads[threadID] = thread
            }
        } catch {
            logger.error("persist failed for thread \(threadID): \(error.localizedDescription)")
            throw LanguageModelContextKitError.persistenceFailed(error.localizedDescription)
        }
    }

    private func saveMemories(
        _ durableMemory: [DurableMemoryRecord],
        threadID: String
    ) async throws {
        do {
            try await configuration.persistence.memories.save(durableMemory, threadID: threadID)
        } catch {
            logger.error("persist failed for thread \(threadID): \(error.localizedDescription)")
            throw LanguageModelContextKitError.persistenceFailed(error.localizedDescription)
        }
    }

    private func deduplicatedMemories(
        _ records: [DurableMemoryRecord]
    ) -> [DurableMemoryRecord] {
        var seen: Set<String> = []
        var unique: [DurableMemoryRecord] = []

        for record in records {
            let key = "\(record.kind.rawValue)\u{1F}\(record.text)"
            guard seen.insert(key).inserted else {
                continue
            }
            unique.append(record)
        }

        return unique
    }

    private func deduplicatedImportedTurns(
        _ turns: [NormalizedTurn]
    ) -> [NormalizedTurn] {
        var seenIDs: Set<UUID> = []
        var seenKeys: Set<ImportedTurnKey> = []
        var unique: [NormalizedTurn] = []

        for turn in turns.sorted(by: Self.sortTurnsByCreatedAt) {
            let key = ImportedTurnKey(turn: turn)
            guard seenIDs.insert(turn.id).inserted, seenKeys.insert(key).inserted else {
                continue
            }
            unique.append(turn)
        }

        return unique
    }

    private func persistedAssistantText<Content: Generable>(
        content: Content,
        transcriptText: String,
        transcriptRenderer: (@Sendable (Content) -> String)?
    ) -> String {
        transcriptRenderer?(content) ?? transcriptText
    }

    private func managedTextResponse(
        from response: ManagedStructuredResponse<GeneratedTextEnvelope>
    ) -> ManagedTextResponse {
        ManagedTextResponse(
            text: response.content.text,
            budget: response.budget,
            compaction: response.compaction,
            bridge: response.bridge
        )
    }

    private func generatedText(from rawContent: GeneratedContent) -> String? {
        rawContent.stringValue(forProperty: "text")
    }

    private func makeCompactionReport(from plan: ContextPlan) -> CompactionReport? {
        guard !plan.reducersApplied.isEmpty else {
            return nil
        }
        return CompactionReport(
            mode: configuration.compaction.mode,
            tokensBefore: plan.originalProjectedTotalTokens ?? plan.budget.projectedTotalTokens,
            tokensAfter: plan.budget.projectedTotalTokens,
            reducersApplied: plan.reducersApplied,
            summaryCreated: plan.summaryCreated,
            spilledBlobCount: plan.spilledBlobCount
        )
    }

    private func uniqueBlobCount(
        in turns: [NormalizedTurn],
        memories: [DurableMemoryRecord]
    ) -> Int {
        let ids = Set(turns.flatMap(\.blobIDs) + memories.flatMap(\.blobIDs))
        return ids.count
    }

    private func deleteBlobs(ids: Set<UUID>) async throws {
        for id in ids {
            try await configuration.persistence.blobs.delete(id)
        }
    }

    private func resolvedContextWindowTokens(for policy: ModelPolicy) -> Int {
        sessionDriver.contextWindowTokens(for: policy) ?? configuration.budget.defaultContextWindowTokens
    }

    private static func sortTurnsByCreatedAt(
        lhs: NormalizedTurn,
        rhs: NormalizedTurn
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct ImportedTurnKey: Hashable {
    let role: NormalizedTurn.Role
    let text: String
    let createdAt: Date
    let priority: Int
    let tags: [String]
    let blobIDs: [UUID]
    let windowIndex: Int
    let compacted: Bool

    init(turn: NormalizedTurn) {
        role = turn.role
        text = turn.text
        createdAt = turn.createdAt
        priority = turn.priority
        tags = turn.tags
        blobIDs = turn.blobIDs
        windowIndex = turn.windowIndex
        compacted = turn.compacted
    }
}

private extension GeneratedContent {
    var stringValue: String? {
        guard case .string(let value) = kind else {
            return nil
        }
        return value
    }

    func stringValue(forProperty property: String) -> String? {
        guard case .structure(let properties, _) = kind else {
            return nil
        }
        return properties[property]?.stringValue
    }
}
