import Darwin
import Foundation
import Testing

@testable import Latch

private final class InstallationFixture {
    let fixture: Fixture
    let paths: InstallationPaths
    let source: URL
    var loaded = false
    var failStart = false
    var failStop = false
    var events: [String] = []

    init() throws {
        fixture = try Fixture()
        paths = InstallationPaths(home: fixture.directory.appendingPathComponent("home with spaces"))
        source = fixture.directory.appendingPathComponent("candidate")
        try Data("executable".utf8).write(to: source)
    }

    var service: UpdateServiceControl {
        UpdateServiceControl(
            loaded: { self.loaded }, revision: { BuildIdentity.serviceRevision },
            stop: {
                self.events.append("stop")
                if self.failStop { throw LatchError("injected stop failure") }
                self.loaded = false
            },
            start: {
                self.events.append("start")
                self.loaded = true
                if self.failStart { throw LatchError("injected startup failure") }
            })
    }

    func install() throws {
        try ServiceInstall.install(source: source, paths: paths, queue: fixture.lockPath, service: service)
    }
}

@Test func `initial install uses a regular executable and private state and can be updated`() throws {
    let f = try InstallationFixture()
    try f.install()
    #expect(f.events == ["start"])
    let attributes = try FileManager.default.attributesOfItem(atPath: f.paths.executable.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    #expect(f.paths.executable.path.hasSuffix("/.local/bin/latch"))
    #expect(f.paths.plist.lastPathComponent == InstallationPaths.serviceIdentifier + ".plist")
    let record = try JSONDecoder().decode(
        UpdateReceipt.self, from: Data(contentsOf: ServiceUpdate.receipt(in: f.paths.updates)))
    #expect(record.current.sha256 == (try BuildIdentity.digest(f.paths.executable)))
    #expect(record.previous == nil)
    for directory in [f.paths.logs, f.paths.updates] {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    #expect(throws: LatchError.self) { try f.install() }
    #expect(f.events == ["start"])
    try Data("replacement".utf8).write(to: f.source)
    let scheduler = try Scheduler(path: f.fixture.lockPath)
    #expect(
        try ServiceUpdate.apply(
            source: f.source, target: f.paths.executable, updates: f.paths.updates, scheduler: scheduler,
            service: f.service))
    #expect(f.events == ["start", "stop", "start"])
    #expect(try String(contentsOf: ServiceUpdate.previous(in: f.paths.updates), encoding: .utf8) == "executable")
    #expect(!InstallationPaths.exists(f.paths.executable.appendingPathExtension("previous")))
}

@Test func `initial install preserves occupied paths including dangling links and refuses a loaded service`() throws {
    for conflict in ["file", "symlink", "plist", "service"] {
        let f = try InstallationFixture()
        let manager = FileManager.default
        try manager.createDirectory(
            at: f.paths.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch conflict {
        case "file": try Data("unrelated".utf8).write(to: f.paths.executable)
        case "symlink":
            try manager.createSymbolicLink(atPath: f.paths.executable.path, withDestinationPath: "/missing/latch")
        case "plist":
            try manager.createDirectory(
                at: f.paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("unrelated".utf8).write(to: f.paths.plist)
        default: f.loaded = true
        }
        #expect(throws: LatchError.self) { try f.install() }
        #expect(f.events.isEmpty)
        if conflict == "file" {
            #expect(try String(contentsOf: f.paths.executable, encoding: .utf8) == "unrelated")
        } else if conflict == "symlink" {
            #expect(try manager.destinationOfSymbolicLink(atPath: f.paths.executable.path) == "/missing/latch")
        } else if conflict == "plist" {
            #expect(try String(contentsOf: f.paths.plist, encoding: .utf8) == "unrelated")
        }
    }
}

@Test func `failed initial start removes only new installation and retains it if cleanup fails`() throws {
    for failStop in [false, true] {
        let f = try InstallationFixture()
        f.failStart = true
        f.failStop = failStop
        #expect(throws: LatchError.self) { try f.install() }
        #expect(f.events == ["start", "stop"])
        #expect(InstallationPaths.exists(f.paths.executable) == failStop)
        #expect(InstallationPaths.exists(f.paths.plist) == failStop)
        #expect(InstallationPaths.exists(ServiceUpdate.receipt(in: f.paths.updates)) == failStop)
    }
}

@Test func `installation state refuses symlink directories`() throws {
    let f = try InstallationFixture()
    let manager = FileManager.default
    try manager.createDirectory(at: f.paths.state, withIntermediateDirectories: true)
    let other = f.fixture.directory.appendingPathComponent("unrelated")
    try manager.createDirectory(at: other, withIntermediateDirectories: true)
    try manager.createSymbolicLink(atPath: f.paths.updates.path, withDestinationPath: other.path)
    #expect(throws: LatchError.self) { try f.install() }
    #expect(f.events.isEmpty)
    #expect(!InstallationPaths.exists(f.paths.executable))
}

@Test func `version query needs no queue or service`() throws {
    #expect(try Options(arguments: ["--version"]).command == .version)
    #expect(throws: LatchError.self) { try Options(arguments: ["version", "--file", "/queue"]) }
    let fixture = try Fixture()
    let child = try fixture.launch(["--version"], includeFile: false)
    #expect(try fixture.finish(child) == 0)
    #expect(child.output.trimmingCharacters(in: .whitespacesAndNewlines) == BuildIdentity.version)
}

@Test func `about query needs no queue or service`() throws {
    #expect(try Options(arguments: ["--about"]).command == .about)
    #expect(throws: LatchError.self) { try Options(arguments: ["--about", "--file", "/queue"]) }
    let fixture = try Fixture()
    let child = try fixture.launch(["--about"], includeFile: false)
    #expect(try fixture.finish(child) == 0)
    let output = child.output
    #expect(output.contains("Latch \(BuildIdentity.version)"))
    #expect(output.contains("Copyright © 2026 Sebastian Christiansen"))
    #expect(output.contains("mail@cerebralcoding.com"))
    #expect(output.contains("https://github.com/sponsors/CerebralCoding"))
    #expect(child.errors.isEmpty)
}

@Test func `uninstall retains queue and logs and permits a fresh installation`() throws {
    let f = try InstallationFixture()
    try f.install()
    let log = f.paths.logs.appendingPathComponent("service.log")
    try Data("history".utf8).write(to: log)
    try Data("rollback".utf8).write(to: ServiceUpdate.previous(in: f.paths.updates))
    try ServiceInstall.uninstall(paths: f.paths, stop: f.service.stop)
    #expect(f.events == ["start", "stop"])
    #expect(!InstallationPaths.exists(f.paths.executable))
    #expect(!InstallationPaths.exists(f.paths.plist))
    #expect(!InstallationPaths.exists(ServiceUpdate.receipt(in: f.paths.updates)))
    #expect(!InstallationPaths.exists(ServiceUpdate.previous(in: f.paths.updates)))
    #expect(try String(contentsOf: log, encoding: .utf8) == "history")
    try f.install()
    #expect(f.events == ["start", "stop", "start"])
}

@Test func `changed installed executable cannot be updated or uninstalled`() throws {
    let f = try InstallationFixture()
    try f.install()
    try Data("unrelated executable".utf8).write(to: f.paths.executable)
    let scheduler = try Scheduler(path: f.fixture.lockPath)
    #expect(throws: LatchError.self) {
        try ServiceUpdate.apply(
            source: f.source, target: f.paths.executable, updates: f.paths.updates,
            scheduler: scheduler, timeout: 0, service: f.service)
    }
    #expect(throws: LatchError.self) { try ServiceInstall.uninstall(paths: f.paths, stop: f.service.stop) }
    #expect(f.events == ["start"])
    #expect(try String(contentsOf: f.paths.executable, encoding: .utf8) == "unrelated executable")
}
