import Foundation
import Testing

@testable import KeelIAP

/// Every rejection path of the transaction verifier, against the injected test PKI. The
/// order of checks is part of the contract: cryptography first, identity claims after.
@Suite("App Store JWS verifier")
struct JWSVerifierTests {

    private func verifier(
        bundleId: String = "com.example.app",
        products: Set<String> = ["unlock_pro", "sub_monthly"]
    ) -> AppStoreJWSVerifier {
        AppStoreJWSVerifier(
            expectedBundleId: bundleId,
            knownProductIds: products,
            pinnedRoots: [TestPKI.root],
            validationTime: TestPKI.start)
    }

    @Test("A known-good JWS verifies and decodes its payload")
    func goodJWS() async throws {
        let transaction = try await verifier().verify(TestPKI.transactionJWS())
        #expect(transaction.bundleId == "com.example.app")
        #expect(transaction.productId == "unlock_pro")
        #expect(transaction.transactionId == "2000000000000001")
        #expect(transaction.originalTransactionId == "2000000000000000")
        #expect(transaction.environment == "Production")
        // StoreKit epochs are milliseconds; a seconds reading would land in 55855 CE.
        #expect(Int(transaction.purchaseDate.timeIntervalSince1970) == 1_700_000_500)
        #expect(transaction.expiresDate == nil)
    }

    @Test("A subscription's expiresDate survives verification")
    func expiresDate() async throws {
        let transaction = try await verifier().verify(
            TestPKI.transactionJWS(
                productId: "sub_monthly", expiresDateMillis: 1_702_592_500_000))
        #expect(Int(transaction.expiresDate?.timeIntervalSince1970 ?? 0) == 1_702_592_500)
    }

    @Test("A tampered payload is rejected as a bad signature")
    func tamperedPayload() async {
        await #expect(throws: JWSVerificationError.badSignature) {
            _ = try await verifier().verify(TestPKI.transactionJWS(tamper: true))
        }
    }

    @Test("A chain anchored at a different root is untrusted")
    func wrongRoot() async {
        let stranger = AppStoreJWSVerifier(
            expectedBundleId: "com.example.app",
            knownProductIds: ["unlock_pro"],
            pinnedRoots: [TestPKI.strangerRoot],
            validationTime: TestPKI.start)
        // The whole point of pinning: a valid chain to the *wrong* trust anchor fails
        // identically to a forged one.
        await #expect(throws: JWSVerificationError.untrustedCertificateChain) {
            _ = try await stranger.verify(TestPKI.transactionJWS())
        }
    }

    @Test("The wrong bundle is rejected after the cryptography passed")
    func wrongBundle() async {
        await #expect(throws: JWSVerificationError.wrongBundleId) {
            _ = try await verifier().verify(TestPKI.transactionJWS(bundleId: "com.other.app"))
        }
    }

    @Test("An unknown product is rejected — a valid receipt for a SKU we never sold")
    func unknownProduct() async {
        await #expect(throws: JWSVerificationError.unknownProduct) {
            _ = try await verifier().verify(TestPKI.transactionJWS(productId: "invented"))
        }
    }

    @Test("Anything but ES256 is refused before certificates are even parsed")
    func wrongAlgorithm() async {
        // `alg: none` is the classic JWS downgrade; StoreKit only ever signs ES256.
        let jws = TestPKI.makeJWS(
            claims: ["bundleId": "com.example.app"], algorithm: "none")
        await #expect(throws: JWSVerificationError.unsupportedAlgorithm) {
            _ = try await verifier().verify(jws)
        }
    }

    @Test(
        "Structural garbage is malformed, not a crash",
        arguments: ["", "a.b", "not-a-jws", "a.b.c.d", "!!!.###.$$$"])
    func malformed(input: String) async {
        await #expect(throws: JWSVerificationError.malformed) {
            _ = try await verifier().verify(input)
        }
    }

    @Test("The pinned Apple root parses — the embedded DER is load-bearing")
    func appleRootParses() {
        _ = JWSCore.appleRootCAG3
    }
}
