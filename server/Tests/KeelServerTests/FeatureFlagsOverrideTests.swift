import Testing

@testable import KeelServer

/// The emergency override exists for the two moments when the table is not an option: it is
/// unreachable, or a flag has to be off *now*. Both are the worst possible time for the parser to
/// be strict, so most of this suite is about what it tolerates.
@Suite("Feature flags override")
struct FeatureFlagsOverrideTests {

    @Test("An absent or blank variable overrides nothing")
    func emptyValues() {
        #expect(FeatureFlagsOverride(environmentValue: nil) == .none)
        #expect(FeatureFlagsOverride(environmentValue: "") == .none)
        #expect(FeatureFlagsOverride(environmentValue: "   ") == .none)
        #expect(FeatureFlagsOverride.none.isEmpty)
    }

    @Test("The environment-variable format parses, spaces and all")
    func parsesCommaSeparatedPairs() {
        let override = FeatureFlagsOverride(
            environmentValue: "anniversary_cover=false, sleep_timer=1")
        #expect(override.values == ["anniversary_cover": false, "sleep_timer": true])
        #expect(override.malformedEntries.isEmpty)
    }

    @Test(
        "true/false/1/0 are accepted in any case",
        arguments: [
            ("a=true", true), ("a=TRUE", true), ("a=True", true), ("a=1", true),
            ("a=false", false), ("a=FALSE", false), ("a=0", false),
            ("a =  true  ", true),
        ])
    func parsesBooleans(entry: String, expected: Bool) {
        #expect(FeatureFlagsOverride(environmentValue: entry).values == ["a": expected])
    }

    @Test("A trailing or doubled comma is silently tolerated")
    func toleratesEmptyEntries() {
        let override = FeatureFlagsOverride(environmentValue: "a=true,,b=false,")
        #expect(override.values == ["a": true, "b": false])
        // Reported nothing on purpose: an operator does not need telling about a trailing comma,
        // and a list that reports it trains the reader to skip the list that reports real typos.
        #expect(override.malformedEntries.isEmpty)
    }

    @Test(
        "A real typo is dropped and reported rather than fatal",
        arguments: [
            "a", "a=", "a=yes", "=true", "  =true", "a=maybe", "a==true",
        ])
    func reportsMalformed(entry: String) {
        let override = FeatureFlagsOverride(environmentValue: entry)
        #expect(override.values.isEmpty)
        #expect(override.malformedEntries == [entry.trimmedForTest])
    }

    @Test("A malformed entry does not take the good ones with it")
    func malformedDoesNotPoisonTheRest() {
        let override = FeatureFlagsOverride(environmentValue: "good=true, bad, other=0")
        #expect(override.values == ["good": true, "other": false])
        #expect(override.malformedEntries == ["bad"])
    }

    @Test("A repeated name keeps the last occurrence, as a shell would")
    func lastAssignmentWins() {
        #expect(FeatureFlagsOverride(environmentValue: "a=true,a=false").values == ["a": false])
    }

    @Test("Overrides merge per flag rather than replacing the config's set")
    func mergesPerFlag() {
        let base = ["one": true, "two": true, "three": false]
        let override = FeatureFlagsOverride(environmentValue: "two=false, four=true")
        // The nineteen flags the config declares must survive overriding the twentieth.
        #expect(
            override.applied(to: base) == [
                "one": true, "two": false, "three": false, "four": true,
            ])
    }

    @Test("An empty override returns the base untouched")
    func emptyOverrideIsIdentity() {
        let base = ["one": true]
        #expect(FeatureFlagsOverride.none.applied(to: base) == base)
        #expect(FeatureFlagsOverride.none.applied(to: [:]).isEmpty)
    }

    @Test("A brand-new flag can be turned on with no config item at all")
    func addsUnknownFlags() {
        let override = FeatureFlagsOverride(environmentValue: "not_in_the_table=true")
        #expect(override.applied(to: [:]) == ["not_in_the_table": true])
    }

    @Test("The variable name is the one the CDK construct sets")
    func environmentKey() {
        #expect(FeatureFlagsOverride.environmentKey == "FEATURE_FLAGS")
    }
}

extension String {
    /// The parser reports a malformed entry trimmed, so the expectation has to match. Local to the
    /// test because trimming is not something `String` should grow for one assertion.
    fileprivate var trimmedForTest: String {
        var slice = self[...]
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return String(slice)
    }
}
