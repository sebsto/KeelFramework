/// The logging seam for the portable layer.
///
/// `KeelCore` cannot import `os.Logger` (Skip) nor `swift-log` (this package ships zero
/// dependencies, deliberately), so the few places worth a log line speak this protocol.
/// `KeelClient` adapts it to `os.Logger`; a Skip app adapts it to `android.util.Log`; tests
/// capture it; the default is silence.
///
/// Two levels only. The portable layer has nothing to say at error level — its policy is
/// grace-first, so failures degrade instead of erroring — and a richer taxonomy here would
/// just be a third logging API for adopters to learn.
public protocol KeelLog: Sendable {
    /// Development detail: cache decisions, degraded fetches.
    func debug(_ message: String)

    /// Something an operator or developer should eventually see: a malformed response, a
    /// schema rejection.
    func warning(_ message: String)
}

/// The default: no output at all.
public struct SilentKeelLog: KeelLog {
    public init() {}
    public func debug(_ message: String) {}
    public func warning(_ message: String) {}
}
