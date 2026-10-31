import Darwin
import Foundation
import Testing

@testable import Latch

private func ownerSensors() -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: ProcessInfo.processInfo.systemUptime, cpuCores: 8, cpuActive: 0, busiestCore: 0,
        gpuActive: 0, aneWatts: 0, memoryAvailableMiB: 24000, memoryTotalMiB: 32000,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
    )
}

private func ownerView(_ state: SchedulerState) -> SchedulerView {
    SchedulerView(
        state: state,
        service: SchedulerService.Status(
            running: true, pid: 123, path: "/queue", serviceRevision: BuildIdentity.serviceRevision),
        processLatch: "free", now: 10)
}

private func ownerTask(name: String = "build", owner: String? = nil, sessionID: String? = nil) -> ScheduledTask {
    ScheduledTask(
        id: UUID().uuidString, name: name, pid: getpid(), arguments: ["true"], requirements: TaskRequirements(),
        owner: owner, sessionID: sessionID)
}

private func ownerSubmission(_ fixture: Fixture, key: String, extra: [String: MCPValue] = [:]) -> MCPValue {
    var value: [String: MCPValue] = [
        "requestKey": .string(key), "name": "owner-test", "executable": "/usr/bin/true",
        "workingDirectory": .string(fixture.directory.path),
    ]
    for (name, item) in extra { value[name] = item }
    return .object(value)
}

/// The column of `header` in a table row, found by the header's own offset (the tables are ASCII in these tests).
private func cell(_ row: String, under header: String, in headerRow: String) -> Substring? {
    guard let range = headerRow.range(of: header) else { return nil }
    let start = headerRow.distance(from: headerRow.startIndex, to: range.lowerBound)
    guard row.count > start else { return nil }
    return row.dropFirst(start).prefix(while: { $0 != " " })
}

// MARK: command line

@Test func `schedule run and guard record an owner and session id and keep the child command literal`() throws {
    let child = ["tool", "--owner", "child", "--session", "child"]
    for command in ["schedule", "run"] {
        let options = try Options(
            arguments: [command, "--owner", "claude-code", "--session", "s-1", "--"] + child, environment: [:])
        #expect(options.owner == "claude-code")
        #expect(options.sessionID == "s-1")
        #expect(options.childArguments == child)
    }
    let inline = try Options(arguments: ["schedule", "--owner=a=b", "--session=c", "--", "tool"], environment: [:])
    #expect(inline.owner == "a=b")
    #expect(inline.sessionID == "c")
    let guarded = try Options(arguments: ["guard", "--owner", "agent", "--session", "s"], environment: [:])
    #expect(guarded.owner == "agent")
    #expect(guarded.sessionID == "s")
    let plain = try Options(arguments: ["schedule", "--", "tool"], environment: [:])
    #expect(plain.owner == nil)
    #expect(plain.sessionID == nil)
}

@Test func `owner and session id take 1 to 128 bytes on the command line and in MCP alike`() throws {
    let fixture = try Fixture()
    let cjk = String(repeating: "漢", count: 50)  // 50 characters, 150 bytes
    let edge = String(repeating: "x", count: 128)
    for bad in ["", String(repeating: "x", count: 129), cjk] {
        #expect(throws: LatchError.self) {
            try Options(arguments: ["schedule", "--owner=\(bad)", "--", "t"], environment: [:])
        }
        #expect(throws: LatchError.self) {
            try Options(arguments: ["schedule", "--session=\(bad)", "--", "t"], environment: [:])
        }
        #expect(throws: MCPFailure.self) {
            try MCPSubmission(ownerSubmission(fixture, key: "k", extra: ["owner": .string(bad)]))
        }
        #expect(throws: MCPFailure.self) {
            try MCPSubmission(ownerSubmission(fixture, key: "k", extra: ["sessionID": .string(bad)]))
        }
    }
    #expect(try Options(arguments: ["schedule", "--owner", edge, "--", "t"], environment: [:]).owner == edge)
    #expect(try MCPSubmission(ownerSubmission(fixture, key: "k", extra: ["owner": .string(edge)])).owner == edge)
    let shortCJK = String(repeating: "漢", count: 42)  // 126 bytes
    #expect(try Options(arguments: ["schedule", "--owner", shortCJK, "--", "t"], environment: [:]).owner == shortCJK)
    #expect(
        try MCPSubmission(ownerSubmission(fixture, key: "k", extra: ["owner": .string(shortCJK)])).owner == shortCJK)
}

@Test func `owner and session flags obey the option checks`() throws {
    #expect(throws: LatchError.self) {
        try Options(arguments: ["schedule", "--owner", "a", "--owner", "b", "--", "t"], environment: [:])
    }
    #expect(throws: LatchError.self) {
        try Options(arguments: ["schedule", "--session", "a", "--session", "b", "--", "t"], environment: [:])
    }
    #expect(throws: LatchError.self) { try Options(arguments: ["schedule", "--owner", "--", "t"], environment: [:]) }
    for command in ["list", "view", "status", "sensors"] {
        #expect(throws: LatchError.self) { try Options(arguments: [command, "--owner", "a"], environment: [:]) }
        #expect(throws: LatchError.self) { try Options(arguments: [command, "--session", "a"], environment: [:]) }
    }
}

@Test func `LATCH_OWNER and LATCH_SESSION_ID fill in what the flags leave out and a bad value only warns`() throws {
    let environment = ["LATCH_OWNER": "agent-a", "LATCH_SESSION_ID": "sess-9"]
    let filled = try Options(arguments: ["schedule", "--", "tool"], environment: environment)
    #expect(filled.owner == "agent-a")
    #expect(filled.sessionID == "sess-9")
    #expect(filled.warnings.isEmpty)
    let overridden = try Options(
        arguments: ["run", "--owner", "agent-b", "--session", "sess-1", "--", "tool"], environment: environment)
    #expect(overridden.owner == "agent-b")
    #expect(overridden.sessionID == "sess-1")
    #expect(try Options(arguments: ["list"], environment: environment).owner == nil)
    #expect(try Options(arguments: ["view", "--json"], environment: environment).sessionID == nil)
    let unset = try Options(
        arguments: ["schedule", "--", "tool"], environment: ["LATCH_OWNER": "", "LATCH_SESSION_ID": ""])
    #expect(unset.owner == nil)
    #expect(unset.sessionID == nil)
    #expect(unset.warnings.isEmpty)
    // A malformed variable must not block scheduling: it is dropped with a notice naming it.
    let bad = try Options(
        arguments: ["schedule", "--", "tool"],
        environment: ["LATCH_OWNER": String(repeating: "o", count: 129), "LATCH_SESSION_ID": "ok"])
    #expect(bad.owner == nil)
    #expect(bad.sessionID == "ok")
    #expect(bad.warnings.count == 1)
    #expect(bad.warnings.first?.contains("LATCH_OWNER") == true)
    // A flag that is itself malformed is still an error: it was typed on purpose.
    #expect(throws: LatchError.self) {
        try Options(arguments: ["schedule", "--owner=", "--", "tool"], environment: environment)
    }
}

// MARK: MCP submission

@Test func `an MCP submission carries an optional owner and session id`() throws {
    let fixture = try Fixture()
    let plain = try MCPSubmission(ownerSubmission(fixture, key: "k"))
    #expect(plain.owner == nil)
    #expect(plain.sessionID == nil)
    let labelled = try MCPSubmission(
        ownerSubmission(fixture, key: "k", extra: ["owner": "claude-code", "sessionID": "abc-123"]))
    #expect(labelled.owner == "claude-code")
    #expect(labelled.sessionID == "abc-123")
    for bad: MCPValue in [7, true] {
        #expect(throws: MCPFailure.self) {
            try MCPSubmission(ownerSubmission(fixture, key: "k", extra: ["owner": bad]))
        }
        #expect(throws: MCPFailure.self) {
            try MCPSubmission(ownerSubmission(fixture, key: "k", extra: ["sessionID": bad]))
        }
    }
    // A record written before these fields existed decodes with both unset.
    var object = try #require(try MCPValue.encoded(labelled).object)
    object["owner"] = nil
    object["sessionID"] = nil
    let old = try JSONDecoder().decode(MCPSubmission.self, from: JSONEncoder().encode(MCPValue.object(object)))
    #expect(old.owner == nil)
    #expect(old.sessionID == nil)
}

@Test func `labelled result fields carry the owner and session id only when they are set`() throws {
    let fixture = try Fixture()
    let labelled = try MCPSubmission(
        ownerSubmission(fixture, key: "k", extra: ["owner": "claude-code", "sessionID": "abc-123"]))
    let fields = try #require(labelled.labelled(["jobID": "j", "state": "queued"]).object)
    #expect(fields["owner"] == "claude-code")
    #expect(fields["sessionID"] == "abc-123")
    #expect(fields["jobID"] == "j")
    let bare = try #require(try MCPSubmission(ownerSubmission(fixture, key: "k")).labelled(["jobID": "j"]).object)
    #expect(bare["owner"] == nil)
    #expect(bare["sessionID"] == nil)
}

@Test func `the tool schema documents owner and sessionID for submit and execute`() throws {
    for name in ["latch_submit", "latch_execute"] {
        let tool = try #require(MCPTools.listing().first { $0["name"]?.string == name })
        let properties = try #require(tool["inputSchema"]?["properties"])
        #expect(properties["owner"]?["maxLength"] == 128)
        #expect(properties["sessionID"]?["maxLength"] == 128)
    }
}

@Test func `a durable submission queues its task with the labels and a retry re-attaches whatever labels it carries`()
    throws
{
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let store = try DurableJobs(scheduler: scheduler)
    let first = try MCPSubmission(
        ownerSubmission(fixture, key: "dedupe", extra: ["owner": "claude-code", "sessionID": "abc-123"]))
    let record = try store.submit(first)
    let task = try #require(scheduler.snapshot().tasks.first { $0.id == record.id })
    #expect(task.owner == "claude-code")
    #expect(task.sessionID == "abc-123")
    #expect(try store.submit(first).id == record.id)
    // A resumed session retrying after a lost response carries a new session id; it must still find its job.
    let resumed = try MCPSubmission(
        ownerSubmission(fixture, key: "dedupe", extra: ["owner": "claude-code", "sessionID": "def-456"]))
    let again = try store.submit(resumed)
    #expect(again.id == record.id)
    #expect(again.submission.sessionID == "abc-123")
    let bare = try store.submit(MCPSubmission(ownerSubmission(fixture, key: "dedupe")))
    #expect(bare.id == record.id)
    #expect(try scheduler.snapshot().tasks.count == 1)
    // Labels are not identity, but the work still is.
    let different = try MCPSubmission(
        ownerSubmission(fixture, key: "dedupe", extra: ["owner": "claude-code", "name": "another-job"]))
    #expect(throws: MCPFailure.self) { try store.submit(different) }
}

// MARK: CLI reservation

@Test func `a CLI reservation records the owner and session id on its queued task`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath) { ownerSensors() }
    let batch = TaskRequirements(mode: .batch)
    let reservation = try scheduler.reserve(
        name: "cli", arguments: [], requirements: batch, timeout: 0, owner: "omp", sessionID: "s-7")
    try withExtendedLifetime(reservation) {
        let task = try #require(scheduler.snapshot().tasks.first { $0.id == reservation.id })
        #expect(task.owner == "omp")
        #expect(task.sessionID == "s-7")
    }
    let bare = try scheduler.reserve(name: "bare", arguments: [], requirements: batch, timeout: 0)
    try withExtendedLifetime(bare) {
        let task = try #require(scheduler.snapshot().tasks.first { $0.id == bare.id })
        #expect(task.owner == nil)
        #expect(task.sessionID == nil)
    }
}

// MARK: presentation

@Test func `list adds OWNER and SESSION columns in order, aligned, only when some job has the label`() throws {
    let owned = ownerTask(name: "named-job", owner: "claude-code", sessionID: "abc-123")
    let unowned = ownerTask(name: "other-job")
    let wide = HumanOutput.list(ownerView(SchedulerState(tasks: [owned, unowned])).jobs, verbose: true, width: 200)
    let rows = wide.split(separator: "\n").map(String.init)
    let header = try #require(rows.first)
    let ownerAt = try #require(header.range(of: "OWNER")?.lowerBound)
    let sessionAt = try #require(header.range(of: "SESSION")?.lowerBound)
    let nameAt = try #require(header.range(of: "NAME")?.lowerBound)
    #expect(ownerAt < sessionAt && sessionAt < nameAt)
    let ownedRow = try #require(rows.first { $0.contains(owned.id) })
    #expect(cell(ownedRow, under: "OWNER", in: header) == "claude-code")
    #expect(cell(ownedRow, under: "SESSION", in: header) == "abc-123")
    #expect(cell(ownedRow, under: "NAME", in: header) == "named-job")
    let unownedRow = try #require(rows.first { $0.contains(unowned.id) })
    #expect(cell(unownedRow, under: "OWNER", in: header) == "-")
    #expect(cell(unownedRow, under: "SESSION", in: header) == "-")
    #expect(cell(unownedRow, under: "NAME", in: header) == "other-job")
    let neither = HumanOutput.list(ownerView(SchedulerState(tasks: [unowned])).jobs, verbose: true, width: 200)
    #expect(!neither.contains("OWNER") && !neither.contains("SESSION"))
    #expect(
        !HumanOutput.list(ownerView(SchedulerState(tasks: [unowned])).jobs, verbose: true, width: 60).contains("owner"))
}

@Test func `a session-only job shows its session in the table and in the stacked layout`() throws {
    let job = ownerTask(name: "solo", sessionID: "sess-only")
    let view = ownerView(SchedulerState(tasks: [job]))
    let wide = HumanOutput.list(view.jobs, verbose: true, width: 160)
    let header = try #require(wide.split(separator: "\n").first.map(String.init))
    #expect(header.contains("SESSION") && !header.contains("OWNER"))
    #expect(wide.contains("sess-only"))
    let narrow = HumanOutput.list(view.jobs, verbose: true, width: 60)
    #expect(narrow.contains("session sess-only"))
    #expect(!narrow.contains("owner"))
}

@Test func `a 128 byte owner and session never push a row past the terminal width`() throws {
    let owner = String(repeating: "o", count: 128)
    let session = String(repeating: "s", count: 128)
    let view = ownerView(SchedulerState(tasks: [ownerTask(name: "n", owner: owner, sessionID: session)]))
    for width in [100, 120, 160, 200] {
        let text = HumanOutput.list(view.jobs, verbose: true, width: width)
        for line in text.split(separator: "\n") { #expect(line.count <= width, "width \(width): \(line.count)") }
    }
    let table = HumanOutput.list(view.jobs, verbose: true, width: 200)
    #expect(table.contains("OWNER") && table.contains("…"))
    #expect(!table.contains(owner) && !table.contains(session))
    // Too narrow for the table: the stacked layout keeps the label whole across wrapped lines.
    let stacked = HumanOutput.list(view.jobs, verbose: true, width: 100)
    #expect(!stacked.contains("OWNER"))
    #expect(stacked.replacingOccurrences(of: "\n", with: "").contains(owner))
}

@Test func `wide characters in a label are clipped by display width`() throws {
    let owner = String(repeating: "漢", count: 40)
    let view = ownerView(SchedulerState(tasks: [ownerTask(name: "n", owner: owner)]))
    let text = HumanOutput.list(view.jobs, verbose: true, width: 200)
    #expect(text.contains("…"))
    #expect(!text.contains(owner))
}

@Test func `list escapes terminal controls in an owner and a session id`() throws {
    let view = ownerView(
        SchedulerState(tasks: [ownerTask(owner: "a\u{1B}[31m\u{202e}b", sessionID: "c\u{1B}[0m\u{202e}d")]))
    for width in [60, 160] {
        let text = HumanOutput.list(view.jobs, verbose: true, width: width)
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\u{202e}"))
        #expect(text.contains("\\u{1b}[31m"))
        #expect(text.contains("\\u{1b}[0m"))
    }
}

@Test func `job summaries encode owner and sessionID when set and omit them when not`() throws {
    let view = ownerView(
        SchedulerState(tasks: [ownerTask(owner: "claude-code", sessionID: "abc-123"), ownerTask()]))
    let data = try JSONEncoder().encode(view.jobs)
    let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let labelled = try #require(rows.first { $0["owner"] != nil })
    #expect(labelled["owner"] as? String == "claude-code")
    #expect(labelled["sessionID"] as? String == "abc-123")
    let bare = try #require(rows.first { $0["owner"] == nil })
    #expect(bare["sessionID"] == nil)
}

@Test func `a job known only by its durable record still shows its labels`() throws {
    let fixture = try Fixture()
    let record = DurableJobRecord(
        id: UUID().uuidString,
        submission: try MCPSubmission(
            ownerSubmission(fixture, key: "record-only", extra: ["owner": "claude-code", "sessionID": "abc-123"])))
    let jobs = ownerView(SchedulerState(jobs: [record])).jobs
    let summary = try #require(jobs.first)
    #expect(summary.owner == "claude-code")
    #expect(summary.sessionID == "abc-123")
    #expect(HumanOutput.list(jobs, verbose: true, width: 200).contains("claude-code"))
}
