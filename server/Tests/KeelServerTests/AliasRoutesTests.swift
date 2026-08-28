import Testing

@testable import KeelServer

/// The retrofit lever: `/station` keeps answering while new builds move to `/v1/bootstrap`.
/// Parsing is strict where `FEATURE_FLAGS` is lenient, because the failure it guards against is
/// louder — a mis-parsed alias is a shipped client's route answering 404.
@Suite("Alias routes")
struct AliasRoutesTests {

    @Test("Absent and blank both mean no aliases")
    func absentIsNone() {
        #expect(AliasRoutes(environmentValue: nil) == .none)
        #expect(AliasRoutes(environmentValue: "  ") == .none)
        #expect(AliasRoutes(environmentValue: nil).isEmpty)
    }

    @Test("Maxi80's declaration parses to its two aliases")
    func parsesTheMotivatingCase() {
        let routes = AliasRoutes(environmentValue: "/station=bootstrap.flattened, /usage=stats")
        #expect(
            routes.aliases == [
                AliasRoutes.Alias(path: "/station", target: .bootstrap, envelope: .flattened),
                AliasRoutes.Alias(path: "/usage", target: .stats, envelope: .standard),
            ])
        #expect(routes.malformedEntries.isEmpty)
    }

    @Test("Every canonical route can be aliased plainly")
    func plainTargets() {
        let routes = AliasRoutes(environmentValue: "/b=bootstrap,/p=ping,/s=stats")
        #expect(routes.aliases.map(\.target) == [.bootstrap, .ping, .stats])
        #expect(routes.aliases.allSatisfy { $0.envelope == .standard })
    }

    @Test(
        "A malformed entry is dropped and reported",
        arguments: [
            "station=bootstrap",  // no leading slash
            "/station=teleport",  // unknown target
            "/station=ping.flattened",  // flattened is bootstrap-only: nothing else has `app`
            "/station=bootstrap.squashed",  // unknown envelope
            "/station",  // no target at all
            "/=bootstrap",  // an empty path segment
            "/v1/bootstrap=stats",  // shadowing a canonical route
        ])
    func malformedIsDroppedAndReported(entry: String) {
        let routes = AliasRoutes(environmentValue: entry)
        #expect(routes.aliases.isEmpty)
        #expect(routes.malformedEntries == [entry])
    }

    @Test("A malformed entry does not poison the valid ones around it")
    func malformedDoesNotPoison() {
        let routes = AliasRoutes(environmentValue: "/station=bootstrap, bogus, /usage=stats")
        #expect(routes.aliases.map(\.path) == ["/station", "/usage"])
        #expect(routes.malformedEntries == ["bogus"])
    }

    @Test("Trailing and doubled commas are tolerated silently")
    func tolerantOfCommaNoise() {
        let routes = AliasRoutes(environmentValue: "/station=bootstrap,,")
        #expect(routes.aliases.count == 1)
        #expect(routes.malformedEntries.isEmpty)
    }

    @Test("A repeated path keeps the last declaration")
    func lastDeclarationWins() {
        let routes = AliasRoutes(environmentValue: "/station=stats, /station=bootstrap.flattened")
        // One handler per path — two would be a registration-order coin flip in the router.
        #expect(
            routes.aliases == [
                AliasRoutes.Alias(path: "/station", target: .bootstrap, envelope: .flattened)
            ])
    }

    @Test("The environment key is the documented one")
    func environmentKey() {
        #expect(AliasRoutes.environmentKey == "ALIAS_ROUTES")
    }
}
