import CryptoKit
import Foundation
import Security

/// The developer's "Apple Development" identities, which the project signs
/// with. A test user has none of its own, so `session add` copies them into
/// each test user's login keychain: built with one, the app keeps its
/// signature from build to build, and with it the permissions macOS gave it.
enum SigningIdentity {
    /// What `CODE_SIGN_IDENTITY = "Apple Development"` picks among.
    static let prefix = "Apple Development:"

    struct Found {
        let identity: SecIdentity
        let name: String
        /// SHA-1 of the certificate, upper-case hex, as `security find-identity` prints it.
        let hash: String
    }

    /// This user's valid identities, each once (a keychain can list one twice).
    static func development() -> [Found] {
        let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll,
                                      kSecReturnRef: true, kSecMatchValidOnDate: Date()]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return [] }
        var seen: Set<String> = []
        return identities.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let name = SecCertificateCopySubjectSummary(certificate) as String?, name.hasPrefix(prefix) else { return nil }
            let hash = sha1Hex(SecCertificateCopyData(certificate) as Data)
            guard seen.insert(hash).inserted else { return nil }
            return Found(identity: identity, name: name, hash: hash)
        }
    }

    /// Whether this user can sign as the project asks, from `security
    /// find-identity`'s listing.
    static func hasDevelopment(findIdentityOutput: String) -> Bool {
        findIdentityOutput.split(whereSeparator: \.isNewline).contains { $0.contains("\"\(prefix)") }
    }

    /// The identities as one PKCS #12 file. macOS may ask on the screen to
    /// allow the private keys' export; over SSH it can't, and this throws.
    static func export(_ found: [Found], passphrase: String) throws -> Data {
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        let phrase = passphrase as CFString
        parameters.passphrase = Unmanaged.passUnretained(phrase)
        var data: CFData?
        let status = withExtendedLifetime(phrase) {
            SecItemExport(found.map(\.identity) as CFArray, .formatPKCS12, [], &parameters, &data)
        }
        guard status == errSecSuccess, let data else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw SCError("Couldn't export your signing certificate: \(reason)",
                          hints: status == errSecInteractionNotAllowed || status == errSecAuthFailed
                              ? ["macOS asks on this Mac's screen to allow the export, which it can't over SSH: "
                                  + "run sc session add in a terminal on the Mac itself, or over Screen Sharing."]
                              : [])
        }
        return data as Data
    }

    /// The intermediate certificates the identities' chains need (Apple's
    /// WWDR, which Xcode puts in the login keychain, not the system's), each
    /// once, as DER. They go apart from the PKCS #12 file: one found by
    /// building the chain isn't a keychain item, and `SecItemExport` refuses
    /// a mix ("No keychain is available").
    static func intermediates(_ found: [Found]) -> [Data] {
        var seen: Set<String> = []
        return found.flatMap { intermediates(of: $0.identity) }
            .map { SecCertificateCopyData($0) as Data }
            .filter { seen.insert(sha1Hex($0)).inserted }
    }

    /// The certificates between an identity's and the root, which every Mac trusts already.
    static func intermediates(of identity: SecIdentity) -> [SecCertificate] {
        var certificate: SecCertificate?
        var trust: SecTrust?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return [] }
        // Evaluated only to build the chain: whether it's trusted doesn't matter here.
        _ = SecTrustEvaluateWithError(trust, nil)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return chain.count > 2 ? Array(chain.dropFirst().dropLast()) : Array(chain.dropFirst())
    }

    /// Run as the test user over SSH: exits 0 when it has every identity, 3
    /// when it has no login keychain yet (it's made at the first login), 1
    /// otherwise.
    static func checkScript(hashes: [String]) -> String {
        let checks = hashes.map { "grep -q \(Remote.quote($0)) <<<\"$have\"" }.joined(separator: " && ")
        return """
        kc="$HOME/Library/Keychains/login.keychain-db"
        [ -f "$kc" ] || exit 3
        have=$(security find-identity -v -p codesigning "$kc" || true)
        \(checks)
        """
    }

    /// Run as the test user over SSH: puts the PKCS #12 file in its login
    /// keychain, unless every identity is there already, and lets `codesign`
    /// use the keys without asking. Exits 3 when the user has no login
    /// keychain yet (it's made at the first login).
    static func installScript(p12: Data, intermediates: [Data], passphrase: String, keychainPassword: String,
                              hashes: [String]) -> String {
        // An intermediate already there is left be ("already in keychain").
        let certificates = intermediates.enumerated().map { index, der in
            """
            /usr/bin/base64 -D > "$tmp/intermediate-\(index).cer" <<'CER'
            \(der.base64EncodedString(options: [.lineLength76Characters]))
            CER
            security add-certificates -k "$kc" "$tmp/intermediate-\(index).cer" 2>/dev/null || true
            """
        }.joined(separator: "\n")
        let checks = hashes.map { "grep -q \(Remote.quote($0)) <<<\"$have\"" }.joined(separator: " && ")
        return """
        set -euo pipefail
        kc="$HOME/Library/Keychains/login.keychain-db"
        [ -f "$kc" ] || exit 3
        have=$(security find-identity -v -p codesigning "$kc" || true)
        if \(checks); then echo present; exit 0; fi
        security unlock-keychain -p \(Remote.quote(keychainPassword)) "$kc"
        tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
        /usr/bin/base64 -D > "$tmp/identity.p12" <<'P12'
        \(p12.base64EncodedString(options: [.lineLength76Characters]))
        P12
        security import "$tmp/identity.p12" -k "$kc" -f pkcs12 -P \(Remote.quote(passphrase)) -T /usr/bin/codesign -T /usr/bin/security
        \(certificates)
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \(Remote.quote(keychainPassword)) "$kc" >/dev/null
        echo installed
        """
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
