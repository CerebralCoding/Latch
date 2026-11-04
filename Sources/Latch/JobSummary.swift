import Foundation

/// A queued job short of memory that no Latch job holds: waiting on the queue cannot help, so it ends as
/// unsatisfiable once `remainingSeconds` runs out (never, when the stall timeout is off).
struct JobStall: Encodable, Equatable {
    var kind: String
    var neededMiB: Int
    var headroomMiB: Int
    var since: Date
    var elapsedSeconds: Double
    var remainingSeconds: Double?

    /// How the stall reads in a blocker detail.
    var sentence: String {
        let shortfall =
            "Stalled for \(HumanOutput.duration(elapsedSeconds)): needs \(HumanOutput.memory(Double(neededMiB))) additional \(kind), "
            + "\(HumanOutput.memory(Double(headroomMiB))) available, and no Latch job holds \(kind), so waiting cannot free it"
        guard let remainingSeconds else { return shortfall + "; the stall timeout is off" }
        return shortfall
            + "; ends as unsatisfiable in \(HumanOutput.duration(remainingSeconds)) unless \(kind) is freed"
    }
}

struct JobSummary: Encodable {
    var jobID: String
    var name: String
    var state: String
    var classification: String
    var queuePosition: Int?
    var pid: Int32?
    var createdAt: Date
    var startedAt: Date?
    var elapsedSeconds: Double
    var blockedBy: String?
    var blockerDetail: String?
    var cooldownRemainingSeconds: Double?
    var complete = false
    var finishedAt: Date?
    var owner: String?
    var sessionID: String?
    var stalled: JobStall?

    init(task: SchedulerView.Task, record: DurableJobRecord?, observedAt: Date) {
        let value = task.task
        jobID = value.id
        name = value.name
        owner = value.owner
        sessionID = value.sessionID
        state = value.state == .queued && value.residentMemoryMiB != nil ? "waiting" : value.state.rawValue
        if record?.state == "cancelling" { state = "cancelling" }
        classification = Self.classification(value.requirements)
        queuePosition = task.queuePosition
        pid = value.pid > 0 ? value.pid : nil
        createdAt = record?.createdAt ?? value.queuedAt
        startedAt = value.startedAt
        elapsedSeconds = max(
            0, observedAt.timeIntervalSince(value.state == .running ? value.startedAt ?? createdAt : value.queuedAt))
        blockedBy = task.blockedBy
        blockerDetail = task.blockerDetail
        cooldownRemainingSeconds = task.cooldownRemainingSeconds
        stalled = task.stalled
    }

    init(record: DurableJobRecord, observedAt: Date) {
        jobID = record.id
        name = record.submission.name
        owner = record.submission.owner
        sessionID = record.submission.sessionID
        state = record.state
        classification =
            record.submission.measurement ? "measurement" : record.submission.classification.rawValue
        createdAt = record.createdAt
        complete = record.complete
        finishedAt = record.complete ? record.updatedAt : nil
        elapsedSeconds = max(0, (finishedAt ?? observedAt).timeIntervalSince(record.createdAt))
        if !record.complete { blockedBy = "waiting for supervisor state" }
    }

    /// The state as people read it: a stalled job is still queued, but its wait will not clear by itself.
    var stateLabel: String { stalled == nil ? state : state + " (stalled)" }

    static func classification(_ requirements: TaskRequirements) -> String {
        requirements.measurement ? "measurement" : requirements.mode == .batch ? "ordinary" : "sensitive"
    }
}
