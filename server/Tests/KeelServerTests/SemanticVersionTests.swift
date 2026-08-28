import Testing

@testable import KeelServer

/// The gate is the most destructive thing the framework can do — a wrong comparison here blocks
/// every install of a shipped build, and no client-side change can undo it. So this suite is
/// deliberately heavier than the type's 80 lines suggest, and every "rejected" case below is one
/// the parser must refuse rather than guess at.
@Suite("Semantic version")
struct SemanticVersionTests {

    @Test(
        "Two to four dotted numbers parse",
        arguments: [
            ("1", [1]),
            ("1.4", [1, 4]),
            ("2.1.0", [2, 1, 0]),
            ("1.2.3.4", [1, 2, 3, 4]),
            ("10.0.20", [10, 0, 20]),
            ("0.0.1", [0, 0, 1]),
            // Leading zeros are a store's business, not ours: `01.4` is what `01.4` sorts as.
            ("01.4", [1, 4]),
        ])
    func parses(text: String, components: [Int]) throws {
        let version = try #require(SemanticVersion(text))
        #expect(version.components == components)
    }

    @Test("Surrounding whitespace is tolerated")
    func trimsWhitespace() throws {
        #expect(try #require(SemanticVersion("  2.1.0 ")).components == [2, 1, 0])
        #expect(try #require(SemanticVersion("\t1.4\n")).components == [1, 4])
    }

    @Test(
        "Anything that is not dotted digits is rejected rather than guessed at",
        arguments: [
            "",
            " ",
            "1.4-beta",
            "1.4.0-rc.1",
            // `Int("+4")` succeeds, so the digit check is what rejects this — reading `1.+4` as
            // `1.4` would silently reinterpret a string somebody typed wrong.
            "1.+4",
            "1.-4",
            "v1.4",
            "1.4.0 (build 77)",
            "1..0",
            "1.",
            ".1",
            "1.4.0.0.1",  // Deeper than any store goes.
            "٣.٤",  // Digits by Unicode, not by ASCII.
            "1½",
        ])
    func rejects(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test("Absent components are zero, so 1.4 and 1.4.0 are the same version")
    func zeroExtension() throws {
        let short = try #require(SemanticVersion("1.4"))
        let long = try #require(SemanticVersion("1.4.0"))
        let longer = try #require(SemanticVersion("1.4.0.0"))
        #expect(short == long)
        #expect(long == longer)
        #expect(!(short < long))
        #expect(!(long < short))
        // An operator types `1.4`; `Bundle` reports `1.4.0`. If these compared unequal, raising
        // the minimum to `1.4` would block the build that is already at 1.4.
        #expect(short.component(at: 2) == 0)
        #expect(short.component(at: 99) == 0)
    }

    @Test(
        "Ordering is component-wise, most significant first",
        arguments: [
            ("1.4.0", "1.4.1"),
            ("1.4.9", "1.5.0"),
            ("1.9.0", "2.0.0"),
            // The one a string comparison gets wrong, and the reason this type exists.
            ("2.9.0", "2.10.0"),
            ("9.0", "10.0"),
            ("1.4", "1.4.1"),
            ("0.9.9", "1.0.0"),
        ])
    func ordersAscending(lower: String, higher: String) throws {
        let low = try #require(SemanticVersion(lower))
        let high = try #require(SemanticVersion(higher))
        #expect(low < high)
        #expect(!(high < low))
        #expect(low != high)
    }

    @Test("Description reports what was parsed, keeping its own depth")
    func describesItself() throws {
        #expect(try #require(SemanticVersion("1.4")).description == "1.4")
        #expect(try #require(SemanticVersion("2.1.0")).description == "2.1.0")
        #expect(try #require(SemanticVersion(" 01.4 ")).description == "1.4")
    }

    @Test("Sorting a mixed list puts them in release order")
    func sorts() throws {
        let versions = ["2.10.0", "1.4", "2.9.0", "10.0", "1.4.1", "2.1.0"]
            .compactMap(SemanticVersion.init)
        #expect(versions.count == 6)
        #expect(
            versions.sorted().map(\.description) == [
                "1.4", "1.4.1", "2.1.0", "2.9.0", "2.10.0", "10.0",
            ])
    }
}
