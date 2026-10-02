import Darwin
import Foundation
import Testing

@testable import Latch
@testable import LatchRelease

@Test func `unconfigured source identities use the executing account`() {
    #expect(ServiceIdentity.resolve(signingIdentifier: nil, adHoc: false, user: "sebastian") == "sebastian.latch")
    #expect(
        ServiceIdentity.resolve(signingIdentifier: "latch-product", adHoc: true, user: "another") == "another.latch")
    #expect(
        ServiceIdentity.resolve(signingIdentifier: ReleasePreparation.identifier, adHoc: true, user: "another")
            == "another.latch")
    for account in ["", "../other", "user/name", "user\nname"] {
        #expect(
            ServiceIdentity.resolve(signingIdentifier: nil, adHoc: false, user: account) == "uid-\(geteuid()).latch")
    }
}

@Test func `explicit embedded and certificate signed identities survive account changes`() {
    for account in ["sebastian", "another"] {
        #expect(
            ServiceIdentity.resolve(signingIdentifier: ReleasePreparation.identifier, adHoc: false, user: account)
                == ReleasePreparation.identifier)
        #expect(
            ServiceIdentity.resolve(
                bundleIdentifier: "org.example.latch", signingIdentifier: "automatic", adHoc: true, user: account)
                == "org.example.latch")
        #expect(
            ServiceIdentity.resolve(
                bundleIdentifier: "org.example.latch", signingIdentifier: ReleasePreparation.identifier,
                adHoc: false, user: account) == ReleasePreparation.identifier)
    }
    #expect(
        ServiceIdentity.resolve(bundleIdentifier: "../../other", signingIdentifier: nil, adHoc: false, user: "account")
            == "account.latch")
}

@Test func `installation filenames configuration and lifecycle use the selected identity`() throws {
    let fixture = try Fixture()
    for identifier in ["account.latch", ReleasePreparation.identifier] {
        let paths = InstallationPaths(
            home: fixture.directory.appendingPathComponent(identifier), identifier: identifier)
        try FileManager.default.createDirectory(
            at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ServiceInstallation.configuration(
            executable: paths.executable.path, path: fixture.lockPath, logs: paths.logs.path, label: paths.label)
        let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        try data.write(to: paths.plist)
        #expect(paths.plist.lastPathComponent == identifier + ".scheduler.plist")
        #expect(config["Label"] as? String == identifier + ".scheduler")
        #expect(try ServiceInstallation.installedPath(paths: paths) == fixture.lockPath)
        var invalid = config
        invalid["Label"] = "unrelated.latch.scheduler"
        try PropertyListSerialization.data(fromPropertyList: invalid, format: .xml, options: 0).write(to: paths.plist)
        #expect(throws: LatchError.self) { try ServiceInstallation.installedPath(paths: paths) }
    }
}

@Test func `executable metadata and copied binary agree with displayed service identity`() throws {
    let fixture = try Fixture()
    let identifier = ServiceIdentity.identifier(for: fixture.executable)
    let copy = fixture.directory.appendingPathComponent("renamed-latch")
    try FileManager.default.copyItem(at: fixture.executable, to: copy)
    #expect(ServiceIdentity.identifier(for: copy) == identifier)
    let unconfigured = fixture.executable.deletingLastPathComponent().appendingPathComponent("LatchTestWorkload")
    #expect(ServiceIdentity.identifier(for: unconfigured) == NSUserName() + ".latch")
    let child = try fixture.launch(["service", "status", "--help"], includeFile: false)
    #expect(try fixture.finish(child) == 0)
    #expect(child.output.contains("Label: \(identifier).scheduler"))
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let local = root.appendingPathComponent(".swiftpm/configuration/latch-Info.plist")
    if FileManager.default.fileExists(atPath: local.path) {
        let info = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: local), format: nil) as? [String: Any])
        #expect(identifier == info["CFBundleIdentifier"] as? String)
    } else {
        #expect(identifier == NSUserName() + ".latch")
    }
}
