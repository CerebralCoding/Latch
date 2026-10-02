import Foundation

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

    init(task: SchedulerView.Task, record: DurableJobRecord?, observedAt: Date) {
        let value = task.task
        jobID = value.id
        name = value.name
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
    }

    init(record: DurableJobRecord, observedAt: Date) {
        jobID = record.id
        name = record.submission.name
        state = record.state
        classification =
            record.submission.measurement ? "measurement" : record.submission.classification?.rawValue ?? "sensitive"
        createdAt = record.createdAt
        complete = record.complete
        finishedAt = record.complete ? record.updatedAt : nil
        elapsedSeconds = max(0, (finishedAt ?? observedAt).timeIntervalSince(record.createdAt))
        if !record.complete { blockedBy = "waiting for supervisor state" }
    }

    static func classification(_ requirements: TaskRequirements) -> String {
        requirements.measurement ? "measurement" : requirements.mode == .batch ? "ordinary" : "sensitive"
    }
}
