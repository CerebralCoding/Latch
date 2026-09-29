import Foundation

final class UpdateDrain {
    private let intent: FileLatch
    private let activity: FileLatch
    private let gate: FileLatch
    private let scheduler: Scheduler

    init(scheduler: Scheduler) throws {
        self.scheduler = scheduler
        intent = try FileLatch(path: scheduler.directory.appendingPathComponent("update.lock").path)
        activity = try FileLatch(path: scheduler.directory.appendingPathComponent("activity.lock").path)
        gate = try FileLatch(path: scheduler.path)
        do { try intent.acquire(shared: false, timeout: 0) }
        catch let error as LatchError where error.exitCode == 75 {
            throw LatchError("another update is in progress", exitCode: 75)
        }
    }

    static func admit(in directory: URL) throws -> FileLatch {
        let intent = try FileLatch(path: directory.appendingPathComponent("update.lock").path)
        do { try intent.acquire(shared: true, timeout: 0) }
        catch let error as LatchError where error.exitCode == 75 {
            throw LatchError("Latch is draining for an update; retry after the update finishes", exitCode: 75)
        }
        defer { intent.release() }
        return try withExtendedLifetime(intent) {
            let activity = try FileLatch(path: directory.appendingPathComponent("activity.lock").path)
            try activity.acquire(shared: true, timeout: 0)
            return activity
        }
    }

    func finish() {
        gate.release()
        activity.release()
        intent.release()
    }

    func wait(timeout: Double) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let watcher = try QueueWatcher(directory: scheduler.directory.path)
        while true {
            let state = try scheduler.snapshot()
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            if state.tasks.isEmpty {
                try activity.acquire(shared: false, timeout: remaining)
                try gate.acquire(shared: false, timeout: remaining)
                // Older clients do not hold activity leases. Never restart over their visible queue.
                guard try scheduler.snapshot().tasks.isEmpty else {
                    throw LatchError("an older client submitted during the drain; quiesce older clients before updating", exitCode: 75)
                }
                return
            }
            guard remaining > 0 else { throw LatchError("update drain timed out; installed version is unchanged", exitCode: 75) }
            watcher.wait(seconds: min(remaining, 1), pids: state.tasks.map(\.pid))
        }
    }

    static func generation(in directory: URL) throws -> Data? {
        do { return try Data(contentsOf: directory.appendingPathComponent("generation")) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    static func advance(in directory: URL) throws {
        try Data(UUID().uuidString.utf8).write(to: directory.appendingPathComponent("generation"), options: .atomic)
    }
}
