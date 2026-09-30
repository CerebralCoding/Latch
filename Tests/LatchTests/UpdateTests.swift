import Darwin
import Foundation
import Testing

@testable import Latch

private final class UpdateFixture {
    let fixture: Fixture
    let scheduler: Scheduler
    let target: URL
    let source: URL
    var loaded = true
    var revision: Int? = BuildIdentity.serviceRevision
    var events: [String] = []
    var failStart = false

    init() throws {
        fixture = try Fixture()
        scheduler = try Scheduler(path: fixture.lockPath)
        target = fixture.directory.appendingPathComponent("installed")
        source = fixture.directory.appendingPathComponent("candidate")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: source)
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
                if self.failStart {
                    self.failStart = false
                    throw LatchError("injected health check failure")
                }
                self.loaded = true
            })
    }

    func apply(rollback: Bool = false, restart: Bool = false, timeout: Double = 0) throws -> Bool {
        try ServiceUpdate.apply(
            source: source, target: target, scheduler: scheduler, rollback: rollback, timeout: timeout,
            restartService: restart, service: service)
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

@Test func `endpoint update keeps service running and rollback restores the prior binary`() throws {
    let f = try UpdateFixture()
    let oldGeneration = try UpdateDrain.generation(in: f.scheduler.directory)
    #expect(try f.apply() == false)
    #expect(f.events.isEmpty)
    #expect(f.loaded)
    #expect(try f.contents(f.target) == "new")
    #expect(try f.contents(ServiceUpdate.previous(for: f.target)) == "old")
    #expect(try UpdateDrain.generation(in: f.scheduler.directory) != oldGeneration)
    #expect(try f.apply(rollback: true))
    #expect(f.events == ["stop", "start"])
    #expect(try f.contents(f.target) == "old")
    #expect(try f.contents(ServiceUpdate.previous(for: f.target)) == "new")
}

@Test func `changed service revision and explicit restart restart only loaded services`() throws {
    for mode in ["changed", "forced", "stopped"] {
        let f = try UpdateFixture()
        if mode == "changed" {
            f.revision = nil
        }
        if mode == "stopped" {
            f.loaded = false
            f.revision = nil
        }
        #expect(try f.apply(restart: mode == "forced") == (mode != "stopped"))
        #expect(f.events == (mode == "stopped" ? [] : ["stop", "start"]))
        #expect(f.loaded == (mode != "stopped"))
    }
}

@Test func `failed service startup restores the old binary and service`() throws {
    let f = try UpdateFixture()
    f.failStart = true
    #expect(throws: LatchError.self) { try f.apply(restart: true) }
    #expect(f.events == ["stop", "start", "stop", "start"])
    #expect(f.loaded)
    #expect(try f.contents(f.target) == "old")
    #expect(!FileManager.default.fileExists(atPath: ServiceUpdate.receipt(for: f.target).path))
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
    let child = try f.fixture.launch(["run", "--", "/bin/sleep", "0.2"])
    try f.fixture.waitUntilHeld()
    let started = ProcessInfo.processInfo.systemUptime
    #expect(try f.apply(timeout: 3) == false)
    #expect(ProcessInfo.processInfo.systemUptime - started > 0.05)
    #expect(try f.fixture.finish(child) == 0)
    _ = try UpdateDrain.admit(in: f.scheduler.directory)
}

@Test func `rollback rejects changed backup without touching installed code`() throws {
    let f = try UpdateFixture()
    _ = try f.apply()
    try Data("damaged".utf8).write(to: ServiceUpdate.previous(for: f.target))
    #expect(throws: LatchError.self) { try f.apply(rollback: true) }
    #expect(try f.contents(f.target) == "new")
    #expect(f.events.isEmpty)
}

@Test func `repeating the same update preserves the rollback binary and endpoint generation`() throws {
    let f = try UpdateFixture()
    _ = try f.apply()
    let generation = try UpdateDrain.generation(in: f.scheduler.directory)
    _ = try f.apply()
    #expect(try f.contents(ServiceUpdate.previous(for: f.target)) == "old")
    #expect(try UpdateDrain.generation(in: f.scheduler.directory) == generation)
    #expect(f.events.isEmpty)
    #expect(try f.apply(restart: true))
    #expect(f.events == ["stop", "start"])
    #expect(try f.contents(ServiceUpdate.previous(for: f.target)) == "old")
}

@Test func `recovery after later update failure keeps the existing rollback copy`() throws {
    let f = try UpdateFixture()
    _ = try f.apply()
    let receipt = try Data(contentsOf: ServiceUpdate.receipt(for: f.target))
    try Data("newer".utf8).write(to: f.source)
    f.failStart = true
    #expect(throws: LatchError.self) { try f.apply(restart: true) }
    #expect(try f.contents(f.target) == "new")
    #expect(try f.contents(ServiceUpdate.previous(for: f.target)) == "old")
    #expect(try Data(contentsOf: ServiceUpdate.receipt(for: f.target)) == receipt)
}
