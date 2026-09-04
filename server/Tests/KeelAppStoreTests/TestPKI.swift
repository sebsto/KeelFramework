import Crypto
import Foundation
import SwiftASN1
import Synchronization
import X509

@testable import KeelAppStore

/// A minimal self-signed root → leaf PKI plus JWS builders, so verification is tested
/// against an *injected* pinned root — the design that makes it testable — rather than
/// Apple's live PKI. Adapted from odvpn's `JWSTestPKI`.
enum TestPKI {
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Test-fixture construction cannot recover from a failure, so every `try` here
    /// funnels through this: a broken fixture aborts the run with the reason.
    private static func fixture<T>(_ build: () throws -> T) -> T {
        do {
            return try build()
        } catch {
            fatalError("Test PKI fixture failed to build: \(error)")
        }
    }

    /// The keys and certificates are built once and held together. On Apple platforms
    /// `P256.Signing.PrivateKey` and `Certificate` are `Sendable`, but under swift-crypto
    /// on Linux they are not, so a bare `static let` of them trips Swift 6 strict
    /// concurrency. The whole PKI is deterministic and must share one set of keys (a JWS
    /// signed by `leafKey` has to verify against `leaf`/`root`), so it is built exactly
    /// once and held in a `Mutex`, which is `Sendable` regardless of its contents — no
    /// `nonisolated(unsafe)` and no other concurrency opt-out.
    private struct Storage {
        let rootKey: P256.Signing.PrivateKey
        let root: Certificate
        let leafKey: P256.Signing.PrivateKey
        let leaf: Certificate
        let strangerKey: P256.Signing.PrivateKey
        let strangerRoot: Certificate
    }

    private static let storage = Mutex(build())

    private static func build() -> Storage {
        let rootKey = P256.Signing.PrivateKey()
        let rootName = fixture {
            try DistinguishedName {
                CountryName("US")
                OrganizationName("keel test")
                CommonName("Keel Test Root")
            }
        }
        let root: Certificate = fixture {
            try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: .init(rootKey.publicKey),
                notValidBefore: start - 86_400,
                notValidAfter: start + 86_400 * 365,
                issuer: rootName,
                subject: rootName,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                },
                issuerPrivateKey: .init(rootKey))
        }

        let leafKey = P256.Signing.PrivateKey()
        let leaf: Certificate = fixture {
            try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: .init(leafKey.publicKey),
                notValidBefore: start - 86_400,
                notValidAfter: start + 86_400 * 30,
                issuer: rootName,
                subject: try DistinguishedName {
                    CountryName("US")
                    OrganizationName("keel test")
                    CommonName("Keel Test Leaf")
                },
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                },
                issuerPrivateKey: .init(rootKey))
        }

        let strangerKey = P256.Signing.PrivateKey()
        let strangerName = fixture {
            try DistinguishedName {
                CommonName("Some Other Root")
            }
        }
        let strangerRoot: Certificate = fixture {
            try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: .init(strangerKey.publicKey),
                notValidBefore: start - 86_400,
                notValidAfter: start + 86_400 * 365,
                issuer: strangerName,
                subject: strangerName,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                },
                issuerPrivateKey: .init(strangerKey))
        }

        return Storage(
            rootKey: rootKey, root: root,
            leafKey: leafKey, leaf: leaf,
            strangerKey: strangerKey, strangerRoot: strangerRoot)
    }

    static var rootKey: P256.Signing.PrivateKey { storage.withLock { $0.rootKey } }
    static var root: Certificate { storage.withLock { $0.root } }
    static var leafKey: P256.Signing.PrivateKey { storage.withLock { $0.leafKey } }
    static var leaf: Certificate { storage.withLock { $0.leaf } }
    static var strangerKey: P256.Signing.PrivateKey { storage.withLock { $0.strangerKey } }
    static var strangerRoot: Certificate { storage.withLock { $0.strangerRoot } }

    static func derBase64(_ certificate: Certificate) -> String {
        fixture {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return Data(serializer.serializedBytes).base64EncodedString()
        }
    }

    /// A signed ES256 JWS over arbitrary claims, chained [leaf, root].
    static func makeJWS(
        claims: [String: Any],
        tamper: Bool = false,
        algorithm: String = "ES256"
    ) -> String {
        let header: [String: Any] = [
            "alg": algorithm, "x5c": [derBase64(leaf), derBase64(root)],
        ]
        let headerData = fixture {
            try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        }
        let claimsData = fixture {
            try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        }

        let headerSegment = Base64URL.encode(headerData)
        let claimsSegment = Base64URL.encode(claimsData)
        let signature = fixture {
            try leafKey.signature(for: Data("\(headerSegment).\(claimsSegment)".utf8))
        }
        let signatureSegment = Base64URL.encode(signature.rawRepresentation)

        if tamper {
            // Re-encode the claims with an extra field AFTER signing, so the signature
            // no longer covers the payload.
            var tampered = claims
            tampered["transactionId"] = "9999999999999999"
            let tamperedData = fixture {
                try JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
            }
            return "\(headerSegment).\(Base64URL.encode(tamperedData)).\(signatureSegment)"
        }
        return "\(headerSegment).\(claimsSegment).\(signatureSegment)"
    }

    /// A StoreKit-shaped transaction JWS.
    static func transactionJWS(
        bundleId: String = "com.example.app",
        productId: String = "unlock_pro",
        transactionId: String = "2000000000000001",
        originalTransactionId: String = "2000000000000000",
        purchaseDateMillis: Int64 = 1_700_000_500_000,
        expiresDateMillis: Int64? = nil,
        environment: String = "Production",
        tamper: Bool = false
    ) -> String {
        var claims: [String: Any] = [
            "bundleId": bundleId,
            "productId": productId,
            "transactionId": transactionId,
            "originalTransactionId": originalTransactionId,
            "purchaseDate": purchaseDateMillis,
            "environment": environment,
        ]
        if let expiresDateMillis { claims["expiresDate"] = expiresDateMillis }
        return makeJWS(claims: claims, tamper: tamper)
    }

    /// An App Store Server Notification v2 envelope whose inner transaction is also
    /// signed by the test PKI.
    static func notificationJWS(
        type: String,
        subtype: String? = nil,
        bundleId: String = "com.example.app",
        productId: String = "unlock_pro",
        originalTransactionId: String = "2000000000000000",
        revocationDateMillis: Int64? = nil,
        includeTransaction: Bool = true
    ) -> String {
        var transaction: [String: Any] = [
            "transactionId": "2000000000000001",
            "originalTransactionId": originalTransactionId,
            "productId": productId,
            "bundleId": bundleId,
            "environment": "Production",
        ]
        if let revocationDateMillis { transaction["revocationDate"] = revocationDateMillis }

        var data: [String: Any] = ["bundleId": bundleId, "environment": "Production"]
        if includeTransaction {
            data["signedTransactionInfo"] = makeJWS(claims: transaction)
        }
        var envelope: [String: Any] = [
            "notificationType": type,
            "notificationUUID": "b1c9b1c9-0000-4000-8000-000000000000",
            "data": data,
        ]
        if let subtype { envelope["subtype"] = subtype }
        return makeJWS(claims: envelope)
    }
}
