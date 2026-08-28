// No Foundation import: everything here is stdlib (`Duration` included). Files in this
// target that do need it use the `FoundationEssentials`-first form, because this target has
// to compile on Linux and through Skip — see README.md in this directory.

/// Framework-wide constants.
///
/// `schemaVersion` is the one number the client and the server must agree on: it is the
/// `schemaVersion` field of every response envelope (`docs/ARCHITECTURE.md` §3). The server
/// declares the same value in `KeelServer.Keel`, and the CDK package in
/// `cdk/lib/contract.ts`. Three copies, because the three artifacts must not depend on each
/// other; the golden-JSON fixtures in both test suites are what keep them equal.
public enum Keel {
    /// Version of the JSON envelope this build speaks.
    ///
    /// A client MUST tolerate a *higher* value from the server — an unknown field is
    /// ignored, and the response still decodes. It refuses only a lower one, which would
    /// mean a server rolled back past a field the client requires.
    public static let schemaVersion = 1

    /// Version of the framework itself. Informational; sent in no request.
    public static let version = "0.1.0"

    /// The canonical route paths. Duplicated in `KeelServer.Keel.Route` and in
    /// `cdk/lib/contract.ts`; an app's own routes live outside this enum.
    public enum Route: String, Sendable, CaseIterable {
        case bootstrap = "/v1/bootstrap"
        case ping = "/v1/ping"
        case stats = "/v1/stats"
    }

    /// Grace-first network budget (`docs/ARCHITECTURE.md` §1). Nothing Keel does may keep a
    /// launch or a view waiting longer than this, whatever the transport.
    public static let requestTimeout: Duration = .seconds(3)
}
