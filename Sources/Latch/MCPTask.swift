import Foundation

final class MCPProgress {
    let token: MCPValue
    private var identity: String?
    private var sequence = 0

    init(token: MCPValue) {
        self.token = token
    }

    func update(state: String, taskID: String? = nil, identity: String? = nil) -> MCPValue? {
        let identity = identity ?? state
        guard self.identity != identity else { return nil }
        self.identity = identity
        sequence += 1
        var params: [String: MCPValue] = [
            "progressToken": token, "progress": .number(Double(sequence)), "message": .string(state),
        ]
        if let taskID {
            params["_meta"] = MCPTask.metadata(taskID)
        }
        return .object(params)
    }
}

final class MCPTask {
    let jobID: String
    let createdAt: Date
    var updatedAt = Date()
    var status = "working"
    var message = "queued"
    private(set) var progressIdentity = "queued"
    let progress: MCPProgress?
    var result: MCPValue?
    var terminal: Bool {
        status != "working"
    }

    init(jobID: String, progress: MCPProgress?, createdAt: Date = Date()) {
        self.jobID = jobID
        self.progress = progress
        self.createdAt = createdAt
    }

    func update(job: MCPJob) throws -> Bool {
        guard !terminal else { return false }
        let result = try job.result(includeOutput: false)
        let next =
            job.complete
            ? (job.cancelAt != nil ? "cancelled" : (result["succeeded"] == true ? "completed" : "failed")) : "working"
        let message = job.complete ? next : (result["progressMessage"]?.string ?? result["state"]?.string ?? next)
        let identity = job.complete ? next : job.progressIdentity(for: result)
        let changed = next != status || identity != progressIdentity
        status = next
        self.message = message
        progressIdentity = identity
        if changed { updatedAt = Date() }
        return changed
    }

    func value() throws -> MCPValue {
        try [
            "taskId": .string(jobID), "status": .string(status), "statusMessage": .string(message),
            "createdAt": .encoded(createdAt), "lastUpdatedAt": .encoded(updatedAt),
            "ttl": .null, "pollInterval": 25000,
        ]
    }

    static func metadata(_ id: String) -> MCPValue {
        ["io.modelcontextprotocol/related-task": ["taskId": .string(id)]]
    }
}
