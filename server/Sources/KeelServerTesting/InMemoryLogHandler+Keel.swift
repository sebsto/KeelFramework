public import InMemoryLogging
public import Logging

extension InMemoryLogHandler {
    /// A `Logger` that writes here at `trace`.
    ///
    /// The level is the whole reason this exists. `InMemoryLogHandler` defaults to `.info`, and
    /// several of `KeelServer`'s promises are kept at `debug` — "telemetry is disabled server-side;
    /// wrote nothing" is the kill switch's only observable effect when it works. Left at the
    /// default, a test asserting that line fails for a reason that has nothing to do with the code
    /// under test.
    ///
    /// Handlers share their storage by reference, so the handler you built and the logger you
    /// handed to a handler both see the same `entries`.
    public var logger: Logger {
        var logger = Logger(label: "keel.test") { _ in self }
        logger.logLevel = .trace
        return logger
    }

    /// Whether any entry at `level` or worse mentions `fragment`.
    ///
    /// Substring rather than equality on purpose: the assertion that matters is "the operator was
    /// told about the dropped dimension", not the exact wording, and pinning full messages turns
    /// every reworded log line into a failing test.
    public func hasEntry(atLeast level: Logger.Level, containing fragment: String) -> Bool {
        entries.contains {
            $0.level >= level && $0.message.description.contains(fragment)
        }
    }
}
