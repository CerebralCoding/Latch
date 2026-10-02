import Darwin
import Foundation
import Security

enum ServiceIdentity {
    static let identifier = identifier(
        for: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))

    static func identifier(for executable: URL) -> String {
        let embedded = CFBundleCopyInfoDictionaryForURL(executable as CFURL) as? [String: Any]
        let bundleIdentifier = embedded?["CFBundleIdentifier"] as? String
        var code: SecStaticCode?
        var information: CFDictionary?
        if SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any]
        {
            return resolve(
                bundleIdentifier: (values[kSecCodeInfoPList as String] as? [String: Any])?["CFBundleIdentifier"]
                    as? String ?? bundleIdentifier,
                signingIdentifier: values[kSecCodeInfoIdentifier as String] as? String,
                adHoc: (values[kSecCodeInfoCertificates as String] as? [SecCertificate])?.isEmpty != false,
                user: NSUserName())
        }
        return resolve(bundleIdentifier: bundleIdentifier, signingIdentifier: nil, adHoc: false, user: NSUserName())
    }

    static func resolve(bundleIdentifier: String? = nil, signingIdentifier: String?, adHoc: Bool, user: String)
        -> String
    {
        // Apple Silicon builds have an automatic ad hoc identifier, not a distribution identity.
        if !adHoc, let signingIdentifier, valid(signingIdentifier) { return signingIdentifier }
        if let bundleIdentifier, valid(bundleIdentifier) { return bundleIdentifier }
        let account = valid(user) ? user : "uid-\(geteuid())"
        return account + ".latch"
    }

    private static func valid(_ identifier: String) -> Bool {
        !identifier.isEmpty
            && identifier.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
            && identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }
}
