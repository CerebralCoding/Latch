import CryptoKit
import Foundation

enum ReleaseError: Error {
    case invalid(String)
}

enum ReleasePreparation {
    static let identifier = "com.cerebralcoding.latch"
    static let team = "YKF838CLKT"
    static let requirement = """
        anchor apple generic and identifier "\(identifier)" and certificate leaf[subject.OU] = "\(team)" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """

    static func validate(version: String) throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            throw ReleaseError.invalid("release version must be X.Y.Z")
        }
    }

    static func run(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter {
            ![
                "LATCH_SIGNING_P12_BASE64", "LATCH_SIGNING_P12_PASSWORD", "LATCH_NOTARY_KEY_BASE64",
                "LATCH_NOTARY_KEY_ID", "LATCH_NOTARY_ISSUER_ID",
            ].contains($0.key)
        }
        let output = Pipe()
        if capture { process.standardOutput = output }
        try process.run()
        let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ReleaseError.invalid("\(executable) failed (\(process.terminationStatus))")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func verify(binary: URL, requirement: String = ReleasePreparation.requirement) throws {
        _ = try run(
            "/usr/bin/codesign", ["--verify", "--strict", "--test-requirement", "=" + requirement, binary.path])
    }

    static func prepare(
        binary: URL, output: URL, installer: URL, identity: String, profile: String, keychain: URL? = nil
    ) throws {
        guard !identity.isEmpty, !profile.isEmpty else {
            throw ReleaseError.invalid("Developer ID Application identity and notarytool keychain profile are required")
        }
        let version = try run(binary.path, ["--version"], capture: true)
        try validate(version: version)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ReleaseError.invalid("output directory must not already exist")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        let asset = output.appendingPathComponent("latch-\(version)-macos-arm64")
        try FileManager.default.copyItem(at: binary, to: asset)
        guard try run("/usr/bin/lipo", ["-archs", asset.path], capture: true) == "arm64" else {
            throw ReleaseError.invalid("release must contain only the arm64 architecture")
        }
        _ = try run(
            "/usr/bin/codesign",
            [
                "--force", "--sign", identity, "--identifier", identifier, "--options", "runtime", "--timestamp",
                asset.path,
            ] + (keychain.map { ["--keychain", $0.path] } ?? []))
        try verify(binary: asset)
        let archive = output.appendingPathComponent("notarization.zip")
        _ = try run("/usr/bin/ditto", ["-c", "-k", asset.path, archive.path])
        let response = try run(
            "/usr/bin/xcrun",
            [
                "notarytool", "submit", archive.path, "--keychain-profile", profile, "--wait", "--output-format",
                "json",
            ] + (keychain.map { ["--keychain", $0.path] } ?? []), capture: true)
        guard let result = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
            result["status"] as? String == "Accepted"
        else {
            throw ReleaseError.invalid("notarization was not accepted: \(response)")
        }
        try Data(response.utf8).write(to: output.appendingPathComponent("notarization.json"))
        try FileManager.default.removeItem(at: archive)
        let hash = SHA256.hash(data: try Data(contentsOf: asset)).map { String(format: "%02x", $0) }.joined()
        try Data((hash + "\n").utf8).write(to: asset.appendingPathExtension("sha256"))
        let bootstrap = try String(contentsOf: installer, encoding: .utf8)
        guard bootstrap.contains("@LATCH_VERSION@"), bootstrap.contains(team), bootstrap.contains(identifier) else {
            throw ReleaseError.invalid("installer does not match the release trust configuration")
        }
        try Data(bootstrap.replacingOccurrences(of: "@LATCH_VERSION@", with: version).utf8).write(
            to: output.appendingPathComponent("install.sh"))
        try FileManager.default.copyItem(
            at: installer.deletingLastPathComponent().appendingPathComponent("LICENSE"),
            to: output.appendingPathComponent("LICENSE"))
        try FileManager.default.copyItem(
            at: installer.deletingLastPathComponent().appendingPathComponent("LICENSES/macmon.txt"),
            to: output.appendingPathComponent("macmon-LICENSE.txt"))
        completed = true
        print("Prepared \(version) in \(output.path). Publication requires separate operator approval.")
    }
}

@main
struct LatchRelease {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let environment = ProcessInfo.processInfo.environment
            if arguments == ["--cleanup-hosted"] {
                try HostedSigning.cleanup(directory: HostedSigning.directory(environment: environment))
                return
            }
            let hosted = arguments.first == "--hosted"
            if hosted { arguments.removeFirst() }
            guard arguments.count == 10,
                arguments[0] == "--binary", arguments[2] == "--output", arguments[4] == "--installer",
                arguments[6] == "--signing-identity", arguments[8] == "--notary-profile"
            else {
                throw ReleaseError.invalid(
                    "usage: LatchRelease [--hosted] --binary PATH --output PATH --installer PATH --signing-identity IDENTITY --notary-profile PROFILE; LatchRelease --cleanup-hosted"
                )
            }
            func prepare(keychain: URL?) throws {
                try ReleasePreparation.prepare(
                    binary: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[3]),
                    installer: URL(fileURLWithPath: arguments[5]), identity: arguments[7], profile: arguments[9],
                    keychain: keychain)
            }
            if hosted {
                try HostedSigning(environment: environment).prepare(profile: arguments[9]) { try prepare(keychain: $0) }
            } else {
                try prepare(keychain: nil)
            }
        } catch {
            FileHandle.standardError.write(Data("release preparation: \(error)\n".utf8))
            exit(1)
        }
    }
}
