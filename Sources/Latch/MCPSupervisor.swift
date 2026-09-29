import Darwin
import Foundation

enum MCPSupervisor {
    static func run(path: String, id: String, lease: Int32, activity: Int32) -> Int32 {
        guard UUID(uuidString: id) != nil, lease > 2, activity > 2,
              fcntl(lease, F_GETFD) >= 0, fcntl(activity, F_GETFD) >= 0 else { return 74 }
        defer { close(lease); close(activity) }
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        signal(SIGPIPE, SIG_IGN)
        do {
            let scheduler = try Scheduler(path: path)
            let store = try DurableJobs(scheduler: scheduler)
            guard let record = try store.records().first(where: { $0.id == id }) else { return 74 }
            let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            let watcher = try QueueWatcher(directory: scheduler.directory.path)
            while true {
                if FileManager.default.fileExists(atPath: store.file(id, "cancel").path) {
                    try store.publish(id, result: ["jobID": .string(id), "requestKey": .string(record.submission.requestKey), "name": .string(record.submission.name),
                                                   "complete": true, "state": "cancelled", "succeeded": false, "phase": "admission", "exitCode": 15, "terminationReason": "signal",
                                                   "stdout": "", "stderr": "", "stdoutTruncated": false, "stderrTruncated": false])
                    return 0
                }
                guard (try? SchedulerService.requireRunning(in: scheduler.directory)) != nil else {
                    watcher.wait(seconds: 1, pids: [])
                    continue
                }
                let execution = try MCPExecution(id: id, submission: record.submission, directory: store.directory, path: path,
                                                 executable: executable, updateDescriptor: activity)
                let result = try supervise(execution, store: store)
                if result["phase"] == "admission", result["exitCode"] == 69, execution.cancelAt == nil {
                    try store.publish(id, result: ["jobID": .string(id), "requestKey": .string(record.submission.requestKey), "name": .string(record.submission.name),
                                                   "complete": false, "state": "queued", "waitingFor": "scheduler service unavailable; ticket retained"])
                    watcher.wait(seconds: 1, pids: [])
                    continue
                }
                try store.publish(id, result: result)
                return 0
            }
        } catch {
            // Retain the ticket for recovery; an admitted command must never be replayed.
            return 74
        }
    }

    private static func supervise(_ execution: MCPExecution, store: DurableJobs) throws -> MCPValue {
        let queue = kqueue()
        guard queue >= 0 else { throw LatchError.system("create supervisor event queue") }
        defer { close(queue) }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
        let directory = open(store.directory.path, O_EVTONLY | O_CLOEXEC)
        guard directory >= 0 else { throw LatchError.system("watch durable job directory") }
        defer { close(directory) }
        func watch(_ ident: UInt, filter: Int32, flags: Int32 = EV_ADD, fflags: UInt32 = 0) throws {
            var event = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
            guard kevent(queue, &event, 1, nil, 0, nil) == 0 else { throw LatchError.system("watch supervisor event") }
        }
        try watch(UInt(directory), filter: EVFILT_VNODE, flags: EV_ADD | EV_CLEAR, fflags: UInt32(NOTE_WRITE))
        for fd in execution.descriptors {
            try watch(UInt(fd), filter: EVFILT_READ)
        }
        try? watch(UInt(execution.pid), filter: EVFILT_PROC, flags: EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_EXIT))
        var previous: MCPValue?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if FileManager.default.fileExists(atPath: store.file(execution.id, "cancel").path) {
                execution.cancel(now: now)
            }
            execution.update(now: now)
            let result = try execution.result(includeOutput: execution.complete)
            if execution.complete {
                return result
            }
            if result != previous {
                try store.publish(execution.id, result: result)
                previous = result
            }
            var deadlines: [Double] = []
            if let cancel = execution.cancelAt, !execution.killSent {
                deadlines.append(cancel + 2)
            }
            if let exited = execution.exitedAt {
                deadlines.append(exited + 2)
            }
            let seconds = deadlines.min().map { max(0, $0 - now) }
            var timeout = timespec(tv_sec: Int(seconds ?? 0), tv_nsec: Int(((seconds ?? 0).truncatingRemainder(dividingBy: 1)) * 1_000_000_000))
            var events = Array(repeating: kevent(), count: 8)
            let count = seconds == nil ? kevent(queue, nil, 0, &events, 8, nil) : kevent(queue, nil, 0, &events, 8, &timeout)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw LatchError.system("wait for supervisor events")
            }
            for event in events.prefix(Int(count)) where event.filter == Int16(EVFILT_READ) {
                let fd = Int32(event.ident)
                if execution.descriptors.contains(fd) {
                    execution.drain(fd)
                }
            }
        }
    }
}
