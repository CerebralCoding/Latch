import Foundation

struct HostedSigning {
    let directory: URL
    let certificate: Data
    let certificatePassword: String
    let apiKey: Data
    let keyID: String
    let issuerID: String

    static func directory(environment: [String: String]) throws -> URL {
        guard environment["GITHUB_ACTIONS"] == "true",
            environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["GITHUB_REPOSITORY"] == "CerebralCoding/Latch",
            environment["GITHUB_REF"] == "refs/heads/main",
            environment["GITHUB_ACTOR"] == "CerebralCoding",
            environment["GITHUB_TRIGGERING_ACTOR"] == "CerebralCoding",
            environment["GITHUB_EVENT_NAME"] == "workflow_dispatch",
            let temporary = environment["RUNNER_TEMP"], temporary.hasPrefix("/")
        else {
            throw ReleaseError.invalid("hosted signing requires an owner-dispatched main-branch GitHub-hosted job")
        }
        return URL(fileURLWithPath: temporary, isDirectory: true).appendingPathComponent("latch-release-credentials")
    }

    init(environment: [String: String]) throws {
        directory = try Self.directory(environment: environment)
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else {
                throw ReleaseError.invalid("missing environment secret: \(name)")
            }
            return value
        }
        func decoded(_ name: String) throws -> Data {
            let text = try required(name).filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: text), !data.isEmpty else {
                throw ReleaseError.invalid("invalid base64 environment secret: \(name)")
            }
            return data
        }
        certificate = try decoded("LATCH_SIGNING_P12_BASE64")
        certificatePassword = try required("LATCH_SIGNING_P12_PASSWORD")
        apiKey = try decoded("LATCH_NOTARY_KEY_BASE64")
        keyID = try required("LATCH_NOTARY_KEY_ID")
        issuerID = try required("LATCH_NOTARY_ISSUER_ID")
        guard keyID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), UUID(uuidString: issuerID) != nil else {
            throw ReleaseError.invalid("invalid notarization Key ID or Issuer ID")
        }
    }

    func prepare(profile: String, operation: (URL) throws -> Void) throws {
        let manager = FileManager.default
        guard !profile.isEmpty else { throw ReleaseError.invalid("notarization profile is required") }
        guard !manager.fileExists(atPath: directory.path) else {
            throw ReleaseError.invalid("hosted credential directory already exists")
        }
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? Self.cleanup(directory: directory) }
        try Data("com.cerebralcoding.latch.release".utf8).write(to: directory.appendingPathComponent("owner"))
        let certificatePath = directory.appendingPathComponent("signing.p12")
        let apiKeyPath = directory.appendingPathComponent("AuthKey_\(keyID).p8")
        for (data, path) in [(certificate, certificatePath), (apiKey, apiKeyPath)] {
            guard manager.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw ReleaseError.invalid("could not write private hosted credentials")
            }
        }
        let keychain = directory.appendingPathComponent("signing.keychain-db")
        let password = UUID().uuidString + UUID().uuidString
        print("::add-mask::\(password)")
        _ = try ReleasePreparation.run("/usr/bin/security", ["create-keychain", "-p", password, keychain.path])
        _ = try ReleasePreparation.run("/usr/bin/security", ["set-keychain-settings", "-lut", "21600", keychain.path])
        _ = try ReleasePreparation.run("/usr/bin/security", ["unlock-keychain", "-p", password, keychain.path])
        _ = try ReleasePreparation.run(
            "/usr/bin/security",
            ["import", certificatePath.path, "-P", certificatePassword, "-T", "/usr/bin/codesign", "-k", keychain.path])
        _ = try ReleasePreparation.run(
            "/usr/bin/security",
            ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain.path])
        _ = try ReleasePreparation.run(
            "/usr/bin/xcrun",
            [
                "notarytool", "store-credentials", profile, "--key", apiKeyPath.path, "--key-id", keyID, "--issuer",
                issuerID, "--keychain", keychain.path,
            ])
        try manager.removeItem(at: certificatePath)
        try manager.removeItem(at: apiKeyPath)
        try operation(keychain)
    }

    static func cleanup(directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        guard
            try String(contentsOf: directory.appendingPathComponent("owner"), encoding: .utf8)
                == "com.cerebralcoding.latch.release"
        else { throw ReleaseError.invalid("refusing to remove an unowned credential directory") }
        defer { try? manager.removeItem(at: directory) }
        let keychain = directory.appendingPathComponent("signing.keychain-db")
        if manager.fileExists(atPath: keychain.path) {
            _ = try ReleasePreparation.run("/usr/bin/security", ["delete-keychain", keychain.path])
        }
    }
}
