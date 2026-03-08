import Foundation
import OSLog

struct DiagnosticsLogger: Sendable {
    private let policy: DiagnosticsPolicy
    private let subsystem = "LanguageModelContextKit"

    init(policy: DiagnosticsPolicy) {
        self.policy = policy
    }

    func budget(_ message: String) {
        log(category: "budget", message: message)
    }

    func compaction(_ message: String) {
        log(category: "compaction", message: message)
    }

    func bridge(_ message: String) {
        log(category: "bridge", message: message)
    }

    func memory(_ message: String) {
        log(category: "memory", message: message)
    }

    func error(_ message: String) {
        log(category: "errors", message: message)
    }

    private func log(category: String, message: String) {
        guard policy.isEnabled, policy.logToOSLog else {
            return
        }
        let logger = Logger(subsystem: subsystem, category: category)
        logger.log("\(message, privacy: .public)")
    }
}
