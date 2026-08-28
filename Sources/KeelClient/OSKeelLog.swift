public import KeelCore
import os

/// `KeelLog` over `os.Logger` — the production adapter for Apple platforms.
public struct OSKeelLog: KeelLog {
    let logger: os.Logger

    public init(subsystem: String = "tools.keel", category: String = "keel") {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}
