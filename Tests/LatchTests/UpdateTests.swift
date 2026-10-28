import Darwin
import Foundation
import Testing

@testable import Latch

private final class UpdateFixture {
    let fixture: Fixture
    let scheduler: Scheduler
    let target: URL
    let source: URL
    let updates: URL
    var loaded = true
    var revision: Int? = BuildIdentity.serviceRevision
    var events: [String] = []
    var startedBinaries: [String] = []
    var startedPlists: [Data] = []
    var failStart = false
    let agents: URL
    let plist: URL
    let desiredPlist: Data
    let stalePlist: Data

    init() throws {
        fixture = try Fixture()
        scheduler = try Scheduler(path: fixture.lockPath)
        target = fixture.directory.appendingPathComponent("installed")
        source = fixture.directory.appendingPathComponent("candidate")
        updates = fixture.directory.appendingPathComponent("state/updates")
        agents = fixture.directory.appendingPathComponent("agents")
        plist = agents.appendingPathComponent("service.plist")
        var configuration = ServiceInstallation.configuration(
            executable: target.path, path: fixture.lockPath, logs: fixture.directory.path)
        desiredPlist = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        configuration["LimitLoadToSessionType"] = nil
        stalePlist = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try desiredPlist.write(to: plist)
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: source)
        try InstallationPaths.privateDirectory(updates)
        try JSONEncoder().encode(
            UpdateReceipt(
                current: BuildIdentity(
                    release: BuildIdentity.version, serviceRevision: BuildIdentity.serviceRevision,
                    sha256: BuildIdentity.digest(target)),
                previous: nil
            )
        ).write(to: ServiceUpdate.receipt(in: updates))
    }

    var service: UpdateServiceControl {
        UpdateServiceControl(
            loaded: { self.loaded }, revision: { self.revision },
            stop: {
                self.events.append("stop")
                self.loaded = false
            },
            start: {
                self.events.append("start")
                self.startedBinaries.append(try self.contents(self.target))
                self.startedPlists.append(try Data(contentsOf: self.plist))
                if self.failStart {
                    self.failStart = false
                    throw LatchError("injected health check failure")
                }
                self.loaded = true
            })
    }

    func apply(rollback: Bool = false, restart: Bool = false, timeout: Double = 0) throws -> Bool {
        try ServiceUpdate.apply(
            source: source, target: target, updates: updates, scheduler: scheduler, rollback: rollback,
            timeout: timeout,
            restartService: restart, plist: ServicePlist(url: plist, contents: desiredPlist), service: service)
    }

    func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

@Test func `update options cannot choose a different queue`() throws {
    let update = try Options(arguments: ["update", "--timeout", "30", "--restart-service"])
    #expect(update.command == .update)
    #expect(update.timeout == 30)
    #expect(update.restartService)
    #expect(try Options(arguments: ["rollback"]).command == .rollback)
    for arguments in [
        ["update", "--file", "/other"], ["rollback", "--timeout", "-1"], ["run", "--restart-service", "--", "true"],
        ["update", "--standalone"],
    ] {
        #expect(throws: LatchError.self) { try Options(arguments: arguments) }
    }
}

@Test func `changed binaries restart the loaded service on update and rollback without a revision change`() throws {
    let f = try UpdateFixture()
    let oldGeneration = try UpdateDrain.generation(in: f.scheduler.directory)
    #expect(try f.apply())
    #expect(f.events == ["stop", "start"])
    #expect(f.startedBinaries == ["new"])
    #expect(f.loaded)
    #expect(try f.contents(f.target) == "new")
    #expect(try f.contents(ServiceUpdate.previous(in: f.updates)) == "old")
    #expect(try UpdateDrain.generation(in: f.scheduler.directory) != oldGeneration)
    #expect(try f.apply(rollback: true))
    #expect(f.events == ["stop", "start", "stop", "start"])
    #expect(f.startedBinaries == ["new", "old"])
    #expect(try f.contents(f.target) == "old")
    #expect(try f.contents(ServiceUpdate.previous(in: f.updates)) == "new")
}

@Test func `unchanged binaries restart only for explicit restart or missing running revision`() throws {
    for mode in ["missing", "forced", "matching", "stopped"] {
        let f = try UpdateFixture()
        try Data("old".utf8).write(to: f.source)
        if mode == "missing" {
            f.revision = nil
        }
        if mode == "stopped" {
            f.loaded = false
            f.revision = nil
        }
        let shouldRestart = mode == "missing" || mode == "forced"
        #expect(try f.apply(restart: mode == "forced" || mode == "stopped") == shouldRestart)
        #expect(f.events == (shouldRestart ? ["stop", "start"] : []))
        #expect(f.loaded == (mode != "stopped"))
    }
}

@Test func `changed binaries leave stopped services stopped on update and rollback`() throws {
    let f = try UpdateFixture()
    f.loaded = false
    f.revision = nil
    #expect(try !f.apply())
    #expect(try f.contents(f.target) == "new")
    #expect(try !f.apply(rollback: true))
    #expect(try f.contents(f.target) == "old")
    #expect(f.events.isEmpty)
    #expect(!f.loaded)
}

@Test func `updates and rollbacks reject a different service identity before replacing code`() throws {
    let f = try UpdateFixture()
    _ = try f.apply()
    f.events.removeAll()
    let receipt = try Data(contentsOf: ServiceUpdate.receipt(in: f.updates))
    for rollback in [false, true] {
        #expect(throws: LatchError.self) {
            try ServiceUpdate.apply(
                source: f.source, target: f.target, updates: f.updates, scheduler: f.scheduler,
                rollback: rollback, timeout: 0, restartService: true,
                expectedIdentifier: "org.example.other-service", service: f.service)
        }
        #expect(f.events.isEmpty)
        #expect(f.loaded)
        #expect(try f.contents(f.target) == "new")
        #expect(try f.contents(ServiceUpdate.previous(in: f.updates)) == "old")
        #expect(try Data(contentsOf: ServiceUpdate.receipt(in: f.updates)) == receipt)
        _ = try UpdateDrain.admit(in: f.scheduler.directory)
    }
}

@Test func `failed service startup restores the old binary and service`() throws {
    let f = try UpdateFixture()
    f.failStart = true
    let receipt = try Data(contentsOf: ServiceUpdate.receipt(in: f.updates))
    #expect(throws: LatchError.self) { try f.apply() }
    #expect(f.events == ["stop", "start", "stop", "start"])
    #expect(f.startedBinaries == ["new", "old"])
    #expect(f.loaded)
    #expect(try f.contents(f.target) == "old")
    #expect(try Data(contentsOf: ServiceUpdate.receipt(in: f.updates)) == receipt)
    _ = try UpdateDrain.admit(in: f.scheduler.directory)
}

@Test func `drain blocks new admissions and times out without replacing anything`() throws {
    let f = try UpdateFixture()
    let permit = try UpdateDrain.admit(in: f.scheduler.directory)
    try withExtendedLifetime(permit) {
        #expect(throws: LatchError.self) { try f.apply() }
        #expect(try f.contents(f.target) == "old")
        #expect(f.events.isEmpty)
        #expect(try UpdateDrain.generation(in: f.scheduler.directory) == nil)
        let drain = try UpdateDrain(scheduler: f.scheduler)
        withExtendedLifetime(drain) {
            #expect(throws: LatchError.self) { try UpdateDrain.admit(in: f.scheduler.directory) }
            #expect(throws: LatchError.self) { try UpdateDrain(scheduler: f.scheduler) }
        }
    }
}

@Test func `drain waits for existing command exit and releases its block afterward`() throws {
    let f = try UpdateFixture()
    let service = try OperatorFixture(fixture: f.fixture)
    defer { withExtendedLifetime(service) {} }
    try service.publishSensors()
    let child = try f.fixture.launch(["run", "--", "/bin/sleep", "0.2"])
    try f.fixture.waitUntilHeld(onWait: service.publishSensors)
    let started = ProcessInfo.processInfo.systemUptime
    #expect(try f.apply(timeout: 10))
    #expect(ProcessInfo.processInfo.systemUptime - started > 0.05)
    #expect(try f.fixture.finish(child) == 0)
    _ = try UpdateDrain.admit(in: f.scheduler.directory)
}

@Test func `rollback rejects changed backup without touching installed code`() throws {
    let f = try UpdateFixture()
    _ = try f.apply()
    f.events.removeAll()
    try Data("damaged".utf8).write(to: ServiceUpdate.previous(in: f.updates))
    #expect(throws: LatchError.self) { try f.apply(rollback: true) }
    #expect(try f.contents(f.target) == "new")
    #expect(f.events.isEmpty)
}

@Test func `repeating the same update preserves the rollback binary and endpoint generation`() throws {
    let f = try UpdateFixture()
    _ = try f.apply()
    f.events.removeAll()
    let generation = try UpdateDrain.generation(in: f.scheduler.directory)
    _ = try f.apply()
    #expect(try f.contents(ServiceUpdate.previous(in: f.updates)) == "old")
    #expect(try UpdateDrain.generation(in: f.scheduler.directory) == generation)
    #expect(f.events.isEmpty)
    #expect(try f.apply(restart: true))
    #expect(f.events == ["stop", "start"])
    #expect(try f.contents(ServiceUpdate.previous(in: f.updates)) == "old")
}

@Test func `recovery after later update failure keeps the existing rollback copy`() throws {
    let f = try UpdateFixture()
    _ = try f.apply()
    let receipt = try Data(contentsOf: ServiceUpdate.receipt(in: f.updates))
    try Data("newer".utf8).write(to: f.source)
    f.failStart = true
    #expect(throws: LatchError.self) { try f.apply() }
    #expect(try f.contents(f.target) == "new")
    #expect(try f.contents(ServiceUpdate.previous(in: f.updates)) == "old")
    #expect(try Data(contentsOf: ServiceUpdate.receipt(in: f.updates)) == receipt)
}

@Test func `update refreshes a launch agent missing the session limit before restarting the service`() throws {
    let f = try UpdateFixture()
    try f.stalePlist.write(to: f.plist)
    #expect(try f.apply())
    #expect(f.events == ["stop", "start"])
    #expect(f.startedPlists == [f.desiredPlist])
    let refreshed = try PropertyListSerialization.propertyList(from: Data(contentsOf: f.plist), format: nil)
    let queue = (refreshed as? [String: Any])?["ProgramArguments"] as? [String]
    #expect(queue?.last == f.fixture.lockPath)
    #expect((refreshed as? [String: Any])?["LimitLoadToSessionType"] as? [String] == ["Aqua", "Background"])
}

@Test func `an unchanged binary with a stale launch agent refreshes it and restarts without touching the receipt`()
    throws
{
    let f = try UpdateFixture()
    try Data("old".utf8).write(to: f.source)
    try f.stalePlist.write(to: f.plist)
    let receipt = try Data(contentsOf: ServiceUpdate.receipt(in: f.updates))
    #expect(try f.apply())
    #expect(f.events == ["stop", "start"])
    #expect(f.startedPlists == [f.desiredPlist])
    #expect(try Data(contentsOf: ServiceUpdate.receipt(in: f.updates)) == receipt)
    #expect(!InstallationPaths.exists(ServiceUpdate.previous(in: f.updates)))
    #expect(try f.contents(f.target) == "old")
}

@Test func `a stale launch agent is refreshed without starting a stopped service`() throws {
    let f = try UpdateFixture()
    f.loaded = false
    f.revision = nil
    try f.stalePlist.write(to: f.plist)
    #expect(try !f.apply())
    #expect(f.events.isEmpty)
    #expect(try Data(contentsOf: f.plist) == f.desiredPlist)
}

@Test func `an identical launch agent leaves the file and a running service alone`() throws {
    let f = try UpdateFixture()
    try Data("old".utf8).write(to: f.source)
    let before = try FileManager.default.attributesOfItem(atPath: f.plist.path)[.modificationDate] as? Date
    #expect(try !f.apply())
    #expect(f.events.isEmpty)
    #expect(try FileManager.default.attributesOfItem(atPath: f.plist.path)[.modificationDate] as? Date == before)
}

@Test func `failed startup restores the original launch agent along with the executable`() throws {
    let f = try UpdateFixture()
    try f.stalePlist.write(to: f.plist)
    f.failStart = true
    #expect(throws: LatchError.self) { try f.apply() }
    #expect(f.events == ["stop", "start", "stop", "start"])
    #expect(f.startedBinaries == ["new", "old"])
    #expect(f.startedPlists == [f.desiredPlist, f.stalePlist])
    #expect(try Data(contentsOf: f.plist) == f.stalePlist)
    #expect(try f.contents(f.target) == "old")
    #expect(f.loaded)
}

@Test func `failed startup with an unchanged binary restores the original launch agent`() throws {
    let f = try UpdateFixture()
    try Data("old".utf8).write(to: f.source)
    try f.stalePlist.write(to: f.plist)
    f.failStart = true
    #expect(throws: LatchError.self) { try f.apply() }
    #expect(f.startedPlists == [f.desiredPlist, f.stalePlist])
    #expect(try Data(contentsOf: f.plist) == f.stalePlist)
    #expect(try f.contents(f.target) == "old")
    #expect(f.loaded)
}

@Test func `an unwritable launch agent directory restores the executable and the service`() throws {
    let f = try UpdateFixture()
    try f.stalePlist.write(to: f.plist)
    let receipt = try Data(contentsOf: ServiceUpdate.receipt(in: f.updates))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.agents.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.agents.path) }
    #expect(throws: LatchError.self) { try f.apply() }
    #expect(try f.contents(f.target) == "old")
    #expect(try Data(contentsOf: f.plist) == f.stalePlist)
    #expect(try Data(contentsOf: ServiceUpdate.receipt(in: f.updates)) == receipt)
    #expect(f.loaded)
    #expect(f.startedBinaries == ["old"])
}
