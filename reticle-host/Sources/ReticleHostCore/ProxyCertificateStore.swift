import Crypto
import Foundation
import NIOSSL
import SwiftASN1
import X509

/// Owns the local Reticle MITM CA and dynamically-issued host certificates.
final class ProxyCertificateStore: @unchecked Sendable {
    let directory: URL
    let caCertificateDER: URL
    let caCertificatePEM: URL

    private let caKeyPEM: URL
    private let leafDirectory: URL
    private let lock = NSLock()
    private var contextCache: [String: NIOSSLContext] = [:]

    /// Creates a certificate store rooted at `directory`.
    init(directory: URL) {
        self.directory = directory
        caCertificateDER = directory.appendingPathComponent("reticle-ca.cer")
        caCertificatePEM = directory.appendingPathComponent("reticle-ca.pem")
        caKeyPEM = directory.appendingPathComponent("reticle-ca-key.pem")
        leafDirectory = directory.appendingPathComponent("leaf", isDirectory: true)
    }

    /// Ensures the Reticle CA exists, generating it on first use.
    func validate() throws {
        try ensureCA()
    }

    /// Loads or creates a TLS context for the requested host.
    func serverContext(host: String) throws -> NIOSSLContext {
        try lock.withLock {
            if let cached = contextCache[host] { return cached }
            try ensureCA()
            let material = try ensureLeaf(host: host)
            let configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: try NIOSSLCertificate.fromPEMFile(material.cert.path).map { .certificate($0) },
                privateKey: try .privateKey(.init(file: material.key.path, format: .pem))
            )
            let context = try NIOSSLContext(configuration: configuration)
            contextCache[host] = context
            return context
        }
    }

    private func ensureCA() throws {
        if FileManager.default.fileExists(atPath: caCertificateDER.path),
           FileManager.default.fileExists(atPath: caCertificatePEM.path),
           FileManager.default.fileExists(atPath: caKeyPEM.path) {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateKey = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(privateKey)
        let subject = try DistinguishedName { CommonName("Reticle Local Debug CA") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365 * 3),
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: key
        )
        let der = try derBytes(certificate)
        try Data(der).write(to: caCertificateDER, options: .atomic)
        try pem(label: "CERTIFICATE", der: der).write(to: caCertificatePEM, atomically: true, encoding: .utf8)
        try key.serializeAsPEM().pemString.write(to: caKeyPEM, atomically: true, encoding: .utf8)
    }

    private func ensureLeaf(host: String) throws -> (cert: URL, key: URL) {
        try FileManager.default.createDirectory(at: leafDirectory, withIntermediateDirectories: true)
        let safe = safeHost(host)
        let cert = leafDirectory.appendingPathComponent("\(safe).pem")
        let keyURL = leafDirectory.appendingPathComponent("\(safe)-key.pem")
        if FileManager.default.fileExists(atPath: cert.path), FileManager.default.fileExists(atPath: keyURL.path) {
            return (cert, keyURL)
        }
        let ca = try loadCA()
        let leafPrivateKey = P256.Signing.PrivateKey()
        let leafKey = Certificate.PrivateKey(leafPrivateKey)
        let subject = try DistinguishedName { CommonName(host) }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: leafKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 90),
            issuer: ca.certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyAgreement: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([generalName(host)])
            },
            issuerPrivateKey: ca.key
        )
        try pem(label: "CERTIFICATE", der: derBytes(certificate)).write(to: cert, atomically: true, encoding: .utf8)
        try leafKey.serializeAsPEM().pemString.write(to: keyURL, atomically: true, encoding: .utf8)
        return (cert, keyURL)
    }

    private func loadCA() throws -> (certificate: Certificate, key: Certificate.PrivateKey) {
        let cert = try Certificate(derEncoded: Array(Data(contentsOf: caCertificateDER)))
        let keyText = try String(contentsOf: caKeyPEM, encoding: .utf8)
        return (cert, try Certificate.PrivateKey(pemEncoded: keyText))
    }

    private func generalName(_ host: String) -> GeneralName {
        let parts = host.split(separator: ".")
        if parts.count == 4, let bytes = ipv4Bytes(parts) {
            return .ipAddress(ASN1OctetString(contentBytes: bytes[...]))
        }
        return .dnsName(host)
    }

    private func ipv4Bytes(_ parts: [Substring]) -> [UInt8]? {
        let values = parts.compactMap { UInt8($0) }
        return values.count == 4 ? values : nil
    }

    private func derBytes(_ certificate: Certificate) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    private func pem(label: String, der: [UInt8]) -> String {
        let base64 = Data(der).base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { index in
            let start = base64.index(base64.startIndex, offsetBy: index)
            let end = base64.index(start, offsetBy: min(64, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start..<end])
        }
        return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----\n"
    }

    private func safeHost(_ host: String) -> String {
        host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.map(String.init).joined()
    }
}
