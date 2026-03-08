import Foundation

public actor KeywordRetriever: Retriever {
    private let memoryStore: any MemoryStore

    public init(memoryStore: any MemoryStore) {
        self.memoryStore = memoryStore
    }

    public func retrieve(
        query: String,
        threadID: String,
        limit: Int
    ) async throws -> [DurableMemoryRecord] {
        let queryTerms = Set(Self.tokenize(query))
        guard !queryTerms.isEmpty else {
            return []
        }

        let records = try await memoryStore.load(threadID: threadID)
        let scored: [(record: DurableMemoryRecord, score: Int)] = records.map { record in
            let recordTerms = Set(Self.tokenize(record.text))
            let score = queryTerms.intersection(recordTerms).count
            return (record: record, score: score)
        }

        return scored
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.record.priority > rhs.record.priority
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map(\.record)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
