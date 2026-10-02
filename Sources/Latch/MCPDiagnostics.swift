import Foundation

enum MCPDiagnostics {
    private struct Cursor: Codable {
        var scope: String
        var createdAt: Date
        var jobID: String
    }

    static func view(_ view: SchedulerView, verbose: Bool) throws -> MCPValue {
        var scheduler: MCPValue
        if !verbose {
            scheduler = [
                "observedAt": .string(view.observedAt.formatted(.iso8601)),
                "service": try .encoded(view.service), "processLatch": .string(view.processLatch),
                "sensorsFresh": .bool(view.sensorsFresh), "samplingPaused": .bool(view.samplingPaused),
                "capacity": try .encoded(view.capacity),
            ]
            var value = scheduler.object!
            if let age = view.sensorAgeSeconds { value["sensorAgeSeconds"] = .number(age) }
            if let error = view.sensorError { value["sensorError"] = .string(error) }
            if let reason = view.samplingPausedReason { value["samplingPausedReason"] = .string(reason) }
            if let sensors = view.sensors { value["sensors"] = try .encoded(sensors) }
            if let next = view.jobs.first(where: { $0.jobID == view.nextTaskID }) {
                value["nextJob"] = try .encoded(next)
            }
            if let id = view.drainingForTaskID { value["drainingForTaskID"] = .string(id) }
            scheduler = .object(value)
        } else {
            // Summaries are returned below; full tasks retain the diagnostic admission evidence.
            var value = try MCPValue.encoded(view).object!
            value.removeValue(forKey: "jobs")
            scheduler = .object(value)
        }
        let shown = verbose ? view.jobs : Array(view.jobs.prefix(10))
        return [
            "scheduler": scheduler,
            "globalOutstandingLimit": .number(Double(DurableJobs.globalOutstandingLimit)),
            "outstandingCount": .number(Double(view.jobs.count)),
            "counts": .object(Dictionary(grouping: view.jobs, by: \.state).mapValues { .number(Double($0.count)) }),
            "jobs": try .encoded(shown), "omittedJobCount": .number(Double(view.jobs.count - shown.count)),
        ]
    }

    static func page(state: SchedulerState, view: SchedulerView, arguments: MCPArguments) throws -> MCPValue {
        let scope = try arguments.text("scope", default: "outstanding", maximum: 16)
        guard ["outstanding", "history"].contains(scope) else {
            throw MCPFailure.invalid("scope must be outstanding or history")
        }
        let limit = Int(try arguments.number("limit", default: 20, range: 1...50, integer: true))
        var summaries =
            scope == "outstanding"
            ? view.jobs
            : state.jobs.filter(\.complete).map { JobSummary(record: $0, observedAt: view.observedAt) }
        summaries.sort {
            if $0.createdAt == $1.createdAt { return scope == "history" ? $0.jobID > $1.jobID : $0.jobID < $1.jobID }
            return scope == "history" ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
        }
        let total = summaries.count
        if arguments.values["cursor"] != nil {
            let text = try arguments.text("cursor", maximum: 1024)
            guard let data = Data(base64Encoded: text), let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
                cursor.scope == scope, cursor.createdAt.timeIntervalSinceReferenceDate.isFinite,
                UUID(uuidString: cursor.jobID) != nil
            else { throw MCPFailure.invalid("invalid cursor for this scope") }
            summaries = summaries.filter {
                if $0.createdAt == cursor.createdAt {
                    return scope == "history" ? $0.jobID < cursor.jobID : $0.jobID > cursor.jobID
                }
                return scope == "history" ? $0.createdAt < cursor.createdAt : $0.createdAt > cursor.createdAt
            }
        }
        let page = Array(summaries.prefix(limit))
        var result: [String: MCPValue] = [
            "scope": .string(scope), "jobs": try .encoded(page), "totalCount": .number(Double(total)),
            "hasMore": .bool(summaries.count > page.count),
        ]
        if summaries.count > page.count, let last = page.last {
            result["nextCursor"] = .string(
                try JSONEncoder().encode(Cursor(scope: scope, createdAt: last.createdAt, jobID: last.jobID))
                    .base64EncodedString())
        }
        return .object(result)
    }
}
