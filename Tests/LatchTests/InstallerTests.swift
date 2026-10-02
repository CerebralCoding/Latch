import Foundation
import Testing

@testable import Latch
@testable import LatchRelease

private final class InstallerFixture {
    let fixture: Fixture
    let home: URL
    let script: URL
    let stub: URL
    let scenario: String

    init(scenario: String) throws {
        self.scenario = scenario
        fixture = try Fixture()
        home = fixture.directory.appendingPathComponent("home with spaces")
        script = fixture.directory.appendingPathComponent("install.sh")
        stub = fixture.directory.appendingPathComponent("installer-latch")
        let manager = FileManager.default
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent("events"))
        let workload = fixture.executable.deletingLastPathComponent().appendingPathComponent("LatchTestWorkload")
        try manager.copyItem(at: workload, to: stub)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var contents = try String(contentsOf: root.appendingPathComponent("install.sh"), encoding: .utf8)
        for tool in ["id", "uname", "sw_vers", "stat", "curl", "codesign"] {
            let mock = fixture.directory.appendingPathComponent("installer-" + tool)
            try manager.copyItem(at: workload, to: mock)
            contents = contents.replacingOccurrences(of: "/usr/bin/" + tool, with: "'" + mock.path + "'")
        }
        // The downloaded stub needs an executable name that selects its mock lifecycle.
        contents = contents.replacingOccurrences(of: "$work/latch", with: "$work/installer-latch")
        try Data(contents.utf8).write(to: script)
        let paths = InstallationPaths(home: home, identifier: ReleasePreparation.identifier)
        if scenario == "update" || scenario == "symlink" || scenario == "conflict" {
            try manager.createDirectory(
                at: paths.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            if scenario == "symlink" {
                try manager.createSymbolicLink(atPath: paths.executable.path, withDestinationPath: "/missing/unrelated")
            } else {
                try manager.copyItem(at: workload, to: paths.executable)
            }
        }
        if scenario == "update" {
            try manager.createDirectory(at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: paths.plist)
        }
    }

    func run(arguments: [String] = ["--version", BuildIdentity.version]) throws -> (Int32, String) {
        let child = Child()
        child.process.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["LATCH_INSTALLER_TEST_SCENARIO"] = scenario
        environment["LATCH_INSTALLER_TEST_BINARY"] = stub.path
        environment["LATCH_INSTALLER_TEST_VERSION"] = BuildIdentity.version
        child.process.environment = environment
        child.process.standardOutput = child.stdout
        child.process.standardError = child.stderr
        try child.process.run()
        fixture.children.append(child)
        return (try fixture.finish(child), child.errors)
    }

    var events: String { get throws { try String(contentsOf: home.appendingPathComponent("events"), encoding: .utf8) } }
}

@Test(arguments: ["install", "update"])
func `installer verifies before dispatching one Swift lifecycle command`(scenario: String) throws {
    let f = try InstallerFixture(scenario: scenario)
    let (status, errors) = try f.run()
    #expect(status == 0, "\(errors)")
    let events = try f.events
    #expect(
        events.contains(
            "https://github.com/CerebralCoding/Latch/releases/download/v\(BuildIdentity.version)/latch-\(BuildIdentity.version)-macos-arm64"
        ))
    #expect(events.contains("--proto-redir =https"))
    #expect(events.contains(ReleasePreparation.team))
    #expect(events.contains(ReleasePreparation.identifier))
    let verification = try #require(events.range(of: "installer-codesign"))
    let execution = try #require(events.range(of: "installer-latch --version"))
    #expect(verification.lowerBound < execution.lowerBound)
    #expect(
        events.contains(
            scenario == "install" ? "installer-latch service install" : "installer-latch update --timeout 600"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: homeCache(f).path).isEmpty)
}

private func homeCache(_ fixture: InstallerFixture) -> URL { fixture.home.appendingPathComponent(".cache/latch") }

@Test(arguments: [
    "bad-checksum", "bad-signature", "bad-version", "network-failure", "command-failure", "symlink", "conflict", "root",
    "intel", "old-os",
])
func `installer fails closed and cleans downloads without touching installed commands`(scenario: String) throws {
    let f = try InstallerFixture(scenario: scenario)
    let (status, _) = try f.run()
    #expect(status != 0)
    let events = try f.events
    let executedBinary = events.split(separator: "\n").contains { $0.hasPrefix("installer-latch ") }
    if scenario != "command-failure" {
        #expect(!events.contains("installer-latch service install"))
        #expect(!events.contains("installer-latch update"))
    }
    if ["bad-checksum", "network-failure"].contains(scenario) {
        #expect(!events.contains("installer-codesign"))
        #expect(!executedBinary)
    }
    if scenario == "bad-signature" { #expect(!executedBinary) }
    let cache = homeCache(f)
    if FileManager.default.fileExists(atPath: cache.path) {
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }
    if scenario == "symlink" {
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: InstallationPaths(home: f.home).executable.path)
                == "/missing/unrelated")
    }
}

@Test func `release preparation and installer reject invalid versions and missing credentials`() throws {
    let releasePaths = InstallationPaths(identifier: ReleasePreparation.identifier)
    #expect(releasePaths.plist.lastPathComponent == "com.cerebralcoding.latch.scheduler.plist")
    for version in ["", "latest", "1.2", "1.2.3.4", "1..3", "1.2.3/evil", "1.2.3-rc1"] {
        #expect(throws: ReleaseError.self) { try ReleasePreparation.validate(version: version) }
        let f = try InstallerFixture(scenario: "install")
        #expect(try f.run(arguments: ["--version", version]).0 != 0)
        #expect(try !f.events.contains("installer-curl"))
    }
    let f = try InstallerFixture(scenario: "install")
    #expect(try f.run(arguments: []).0 != 0)
    let output = f.fixture.directory.appendingPathComponent("artifacts")
    #expect(throws: ReleaseError.self) {
        try ReleasePreparation.prepare(binary: f.stub, output: output, installer: f.script, identity: "", profile: "")
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func `release trust requirement rejects a locally built unsigned or ad hoc executable`() throws {
    let fixture = try Fixture()
    #expect(throws: ReleaseError.self) {
        try ReleasePreparation.run(
            "/usr/bin/codesign",
            [
                "--verify", "--strict", "--test-requirement", ReleasePreparation.requirement, fixture.executable.path,
            ])
    }
}
