import Crypto
import Foundation
import SwiftASN1
import X509

@testable import KeelIAP

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

    static let rootKey = P256.Signing.PrivateKey()
    static let rootName = fixture {
        try DistinguishedName {
            CountryName("US")
            OrganizationName("keel test")
            CommonName("Keel Test Root")
        }
    }

    static let root: Certificate = fixture {
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

    static let leafKey = P256.Signing.PrivateKey()

    static let leaf: Certificate = fixture {
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

    /// A second, unrelated root — for asserting that a chain anchored elsewhere fails.
    static let strangerKey = P256.Signing.PrivateKey()
    static let strangerName = fixture {
        try DistinguishedName {
            CommonName("Some Other Root")
        }
    }

    static let strangerRoot: Certificate = fixture {
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
