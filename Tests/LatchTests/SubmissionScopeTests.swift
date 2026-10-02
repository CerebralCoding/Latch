import Foundation
import Testing

@testable import Latch

@Test func `submission scopes reject forged and foreign capabilities without accumulating records`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let other = try Fixture()
    let foreign = try Scheduler(path: other.lockPath)
    let token = try SubmissionScope.create(in: scheduler.directory)
    let scope = try SubmissionScope.validate(token, in: scheduler.directory)
    #expect(try SubmissionScope.validate(token, in: scheduler.directory) == scope)
    #expect(!token.contains(scope))
    _ = try SubmissionScope.create(in: foreign.directory)
    #expect(throws: MCPFailure.self) { try SubmissionScope.validate(token, in: foreign.directory) }
    let parts = token.split(separator: ".")
    for invalid in ["", "unknown", scope, UUID().uuidString + "." + String(parts[1]), String(parts[0]) + ".AAAA"] {
        #expect(throws: MCPFailure.self) { try SubmissionScope.validate(invalid, in: scheduler.directory) }
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: scheduler.directory.path)
    for _ in 0..<100 {
        let next = try SubmissionScope.create(in: scheduler.directory)
        #expect(try SubmissionScope.validate(next, in: scheduler.directory) != scope)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: scheduler.directory.path) == files)
    let permissions = try FileManager.default.attributesOfItem(
        atPath: scheduler.directory.appendingPathComponent("scope.key").path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func `bulk cancellation never touches foreign unscoped or completed jobs`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let store = try DurableJobs(scheduler: scheduler)
    let ownToken = try SubmissionScope.create(in: scheduler.directory)
    let ownScope = try SubmissionScope.validate(ownToken, in: scheduler.directory)
    let otherToken = try SubmissionScope.create(in: scheduler.directory)
    let otherScope = try SubmissionScope.validate(otherToken, in: scheduler.directory)
    func submit(scope: String?) throws -> DurableJobRecord {
        try store.submit(
            MCPSubmission([
                "requestKey": .string(UUID().uuidString), "name": "scoped-test", "executable": "/usr/bin/true",
                "workingDirectory": .string(fixture.directory.path),
            ]), scope: scope)
    }
    var own: [DurableJobRecord] = []
    var foreign: [DurableJobRecord] = []
    for state in [ScheduledTask.State.queued, .running, .parked] {
        let a = try submit(scope: ownScope)
        let b = try submit(scope: otherScope)
        own.append(a)
        foreign.append(b)
        try scheduler.transaction { snapshot in
            for index in snapshot.tasks.indices where [a.id, b.id].contains(snapshot.tasks[index].id) {
                snapshot.tasks[index].state = state
            }
        }
    }
    let unscoped = try submit(scope: nil)
    let completed = try submit(scope: ownScope)
    try store.publish(completed.id, result: ["complete": true, "state": "completed", "succeeded": true])
    let expected = own.map(\.id)
    #expect(try store.clearOwn(scopeToken: ownToken) == expected)
    #expect(try DurableJobs(scheduler: Scheduler(path: fixture.lockPath)).clearOwn(scopeToken: ownToken) == expected)
    for id in expected { #expect(FileManager.default.fileExists(atPath: store.file(id, "cancel").path)) }
    for id in foreign.map(\.id) + [unscoped.id, completed.id] {
        #expect(!FileManager.default.fileExists(atPath: store.file(id, "cancel").path))
    }
    #expect(try store.records().contains { $0.id == completed.id && $0.complete })
    #expect(try store.submit(own[0].submission, scope: ownScope).id == own[0].id)
    for scope in [otherScope, nil] {
        #expect(throws: MCPFailure.self) { try store.submit(own[0].submission, scope: scope) }
    }
    #expect(throws: MCPFailure.self) { try store.submit(unscoped.submission, scope: ownScope) }
    #expect(throws: MCPFailure.self) { try store.clearOwn(scopeToken: otherScope) }
    #expect(try store.records().count == own.count + foreign.count + 2)
}
