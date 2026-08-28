import Crypto
import SwiftASN1
@_spi(FixedExpiryValidationTime) import X509

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Every failure mode of App Store JWS verification, shared by the transaction and
/// notification verifiers.
public enum JWSVerificationError: Error, Sendable, Equatable {
    case malformed
    case unsupportedAlgorithm
    case missingCertificateChain
    case untrustedCertificateChain
    case badSignature
    case wrongBundleId
    case unknownProduct
}

/// The shared JWS mechanics: x5c chain validation against a pinned root, then ES256 over
/// `header.payload`, and only then are the payload bytes handed back to be believed.
///
/// Lifted from odvpn's `AppStoreJWSVerifier` (its production-proven half) and shared
/// between the two verifier types instead of being duplicated into both. The pinned root
/// is injectable so tests verify against their own self-signed PKI instead of Apple's —
/// which is what makes chain validation unit-testable at all.
struct JWSCore: Sendable {
    let rootCertificates: CertificateStore

    /// Validation time for chain expiry; nil means "now" (production). Injectable so a
    /// test chain with fixed validity verifies deterministically.
    let validationTime: Date?

    /// Verifies structure, chain, and signature; returns the now-trusted payload bytes.
    func verify(_ jws: String) async throws(JWSVerificationError) -> Data {
        let segments = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw .malformed }
        let headerSegment = segments[0]
        let payloadSegment = segments[1]
        let signatureSegment = segments[2]

        let header = try Self.decodeJSON(Header.self, from: headerSegment)
        guard header.alg == "ES256" else { throw .unsupportedAlgorithm }
        guard let x5c = header.x5c, !x5c.isEmpty else { throw .missingCertificateChain }

        // The x5c DER chain: leaf first, then intermediates, then (Apple's) root.
        var chain: [Certificate] = []
        for base64 in x5c {
            guard let der = Data(base64Encoded: base64),
                let certificate = try? Certificate(derEncoded: Array(der))
            else {
                throw .malformed
            }
            chain.append(certificate)
        }
        let leaf = chain[0]
        let intermediates = CertificateStore(chain.dropFirst())

        var verifier = Verifier(rootCertificates: rootCertificates) {
            if let validationTime {
                RFC5280Policy(fixedExpiryValidationTime: validationTime)
            } else {
                RFC5280Policy()
            }
        }
        let result = await verifier.validate(leaf: leaf, intermediates: intermediates)
        guard case .validCertificate = result else { throw .untrustedCertificateChain }

        // The leaf's P256 signature over the raw `header.payload` ASCII.
        let signingInput = Data("\(headerSegment).\(payloadSegment)".utf8)
        guard
            let leafKey = try? P256.Signing.PublicKey(
                x963Representation: leaf.publicKey.subjectPublicKeyInfoBytes)
        else {
            throw .untrustedCertificateChain
        }
        let signatureBytes = try Self.decodeBase64URL(signatureSegment)
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        else {
            throw .badSignature
        }
        guard leafKey.isValidSignature(signature, for: signingInput) else {
            throw .badSignature
        }

        // Only now is the payload trusted.
        return try Self.decodeBase64URL(payloadSegment)
    }

    private struct Header: Decodable {
        let alg: String
        let x5c: [String]?
    }

    static func decodeJSON<T: Decodable>(
        _ type: T.Type, from segment: Substring
    ) throws(JWSVerificationError) -> T {
        let data = try decodeBase64URL(segment)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw .malformed
        }
        return decoded
    }

    static func decodeJSON<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws(JWSVerificationError) -> T {
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw .malformed
        }
        return decoded
    }

    static func decodeBase64URL(_ segment: Substring) throws(JWSVerificationError) -> Data {
        guard let data = Base64URL.decode(String(segment)) else { throw .malformed }
        return data
    }

    // MARK: - Pinned Apple Root CA G3

    /// Apple Root CA - G3 (serial 2DC5FC88D2C54B95, CN "Apple Root CA - G3"), fetched
    /// from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer and embedded
    /// as DER (base64) — the trust anchor for every StoreKit-2 JWS chain. Valid to 2039.
    static let appleRootCAG3Base64 = """
        MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vd\
        CBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECg\
        wKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjB\
        nMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRp\
        b24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49A\
        gEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7\
        YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQY\
        DVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQD\
        AgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOw\
        gPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6B\
        gD56KyKA==
        """

    static let appleRootCAG3: Certificate = {
        // The literal's `\` continuations join its lines, so it is already one line; the
        // filter is a guard against a future edit un-joining them.
        let compact = String(appleRootCAG3Base64.filter { !$0.isNewline })
        guard let der = Data(base64Encoded: compact),
            let certificate = try? Certificate(derEncoded: Array(der))
        else {
            fatalError("Embedded Apple Root CA G3 DER failed to parse")
        }
        return certificate
    }()
}
