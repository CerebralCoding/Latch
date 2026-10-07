import Foundation

struct OperatorQueue {
    let scheduler: Scheduler

    func list(verbose: Bool = false) throws -> String {
        HumanOutput.list(try SchedulerView(scheduler: scheduler).jobs, verbose: verbose)
    }

    func prioritize(_ id: String) throws {
        try requireMatchingService()
        let store = try DurableJobs(scheduler: scheduler)
        try scheduler.transaction { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else {
                throw LatchError("unknown or completed job ID: \(id)")
            }
            guard state.tasks[index].state == .queued,
                !FileManager.default.fileExists(atPath: store.file(id, "cancel").path)
            else { throw LatchError("only queued jobs can be prioritized", exitCode: 75) }
            let task = state.tasks.remove(at: index)
            let front = state.tasks.firstIndex(where: { $0.state == .queued }) ?? state.tasks.endIndex
            state.tasks.insert(task, at: front)
        }
    }

    func clear() throws -> [String] {
        try requireMatchingService()
        let store = try DurableJobs(scheduler: scheduler)
        return try scheduler.transaction { state in
            var ids: [String] = []
            for index in state.tasks.indices {
                let task = state.tasks[index]
                guard task.state == .queued, task.startedAt == nil, task.residentMemoryMiB == nil else { continue }
                // Admission uses the same state lock: cancellation wins before a job can start.
                if state.jobs.contains(where: { $0.id == task.id && !$0.complete }) {
                    try store.cancel(task.id)
                }
                state.tasks[index].state = .cancelling
                state.tasks[index].waitingFor = "queued task cancelled by operator"
                ids.append(task.id)
            }
            return ids
        }
    }

    func stop() throws -> [String] {
        try requireMatchingService()
        let store = try DurableJobs(scheduler: scheduler)
        return try scheduler.transaction { state in
            var ids = state.jobs.filter { !$0.complete }.map(\.id)
            for task in state.tasks where !ids.contains(task.id) { ids.append(task.id) }
            for id in ids { try store.cancel(id) }
            for task in state.tasks where !state.jobs.contains(where: { $0.id == task.id }) {
                ScheduledCommand.resumeCancelledSupervisor(task)
            }
            for index in state.tasks.indices where state.tasks[index].state == .queued {
                state.tasks[index].state = .cancelling
                state.tasks[index].waitingFor = "queued task cancelled by operator"
            }
            return ids
        }
    }

    // Confirmations capture IDs so jobs arriving while a dialog is open are never affected.
    func cancel(_ ids: Set<String>, onlyNeverStarted: Bool = false) throws -> [String] {
        try requireMatchingService()
        let store = try DurableJobs(scheduler: scheduler)
        return try scheduler.transaction { state in
            var cancelled: [String] = []
            for id in ids.sorted() {
                let taskIndex = state.tasks.firstIndex { $0.id == id }
                let task = taskIndex.map { state.tasks[$0] }
                let record = state.jobs.first { $0.id == id && !$0.complete }
                guard task != nil || record != nil else { continue }
                if onlyNeverStarted {
                    guard let task, task.state == .queued, task.startedAt == nil, task.residentMemoryMiB == nil else {
                        continue
                    }
                }
                try store.cancel(id)
                if let task, record == nil { ScheduledCommand.resumeCancelledSupervisor(task) }
                if let taskIndex, state.tasks[taskIndex].state == .queued {
                    state.tasks[taskIndex].state = .cancelling
                    state.tasks[taskIndex].waitingFor = "queued task cancelled by operator"
                }
                cancelled.append(id)
            }
            return cancelled
        }
    }

    private func requireMatchingService() throws {
        let status = try SchedulerService.status(in: scheduler.directory)
        guard status.running && status.serviceRevision == BuildIdentity.serviceRevision else {
            throw LatchError(
                "operator queue changes require the matching running scheduler service", exitCode: 69)
        }
    }
}
