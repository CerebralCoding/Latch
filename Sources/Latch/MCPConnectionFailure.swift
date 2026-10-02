import Foundation

struct MCPConnectionFailure: Error {
    enum Reason: String {
        case endpointUpdated = "endpoint_updated"
        case schedulerUnavailable = "scheduler_unavailable"
        case schedulerMismatch = "scheduler_mismatch"
        case updateInProgress = "update_in_progress"
        case stateUnavailable = "state_unavailable"
    }

    let reason: Reason
    var detail: String?

    var reconnectRequired: Bool { reason == .endpointUpdated }
    var exitCode: Int32 {
        switch reason {
        case .endpointUpdated, .schedulerUnavailable, .schedulerMismatch: 69
        case .updateInProgress: 75
        case .stateUnavailable: 74
        }
    }

    var action: String {
        switch reason {
        case .endpointUpdated:
            "Ask the user or host to reconnect the Latch MCP server, then recover retained work by jobID."
        case .schedulerUnavailable:
            "Ask the operator to start the Latch user service, then retry on this connection."
        case .schedulerMismatch:
            "Ask the operator to align the installed scheduler and MCP executable, then reconnect."
        case .updateInProgress:
            "Wait for the operator's update to finish, then ask the user or host to reconnect Latch MCP."
        case .stateUnavailable:
            "Ask the operator to inspect Latch's installation and state, then reconnect after repair."
        }
    }

    var message: String {
        let summary =
            switch reason {
            case .endpointUpdated: "Latch was updated; this MCP connection is retired."
            case .schedulerUnavailable: "Latch scheduler service is not running."
            case .schedulerMismatch: "Latch MCP and scheduler revisions do not match."
            case .updateInProgress: "Latch is draining for an update; new work was not accepted."
            case .stateUnavailable: "Latch cannot access its current coordination state."
            }
        return
            "\(summary) \(action) Accepted work is not cancelled; preserve original job/control IDs and retry keys. Do not bypass Latch or automatically install, update, or restart it."
    }

    var data: MCPValue {
        var fields: [String: MCPValue] = [
            "reason": .string(reason.rawValue), "action": .string(action),
            "reconnectRequired": .bool(reconnectRequired), "retryable": .bool(reason != .stateUnavailable),
            "recovery": .string(
                "Connection failure does not cancel accepted jobs. Recover jobs and controls by their original IDs; retry uncertain submissions or controls only with identical arguments and the full original requestKey. Never create a replacement key or blindly replay work."
            ),
        ]
        if let detail { fields["detail"] = .string(detail) }
        return .object(fields)
    }

    static func state(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        return Self(reason: .stateUnavailable, detail: String(describing: error))
    }

    func log() {
        FileHandle.standardError.write(Data("latch mcp: \(message)\(detail.map { " \($0)" } ?? "")\n".utf8))
    }
}
