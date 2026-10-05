import Darwin
import Foundation

enum ScheduledCommand {
    static func run(_ arguments: [String], scheduler: Scheduler, reservation: TaskReservation) throws -> Never {
        let store = try DurableJobs(scheduler: scheduler)
        let watcher = try QueueWatcher(directory: store.directory.path)
        let forwarded: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT]
        for number in forwarded + [SIGCHLD] { try watcher.watchSignal(number) }
        let previousSignals = forwarded.map { ($0, signal($0, SIG_IGN)) }
        let previousTTOU = signal(SIGTTOU, SIG_IGN)
        let previousCHLD = signal(SIGCHLD, SIG_DFL)
        defer {
            for (number, handler) in previousSignals { signal(number, handler) }
            signal(SIGTTOU, previousTTOU)
            signal(SIGCHLD, previousCHLD)
        }
        let group = try CommandGuardian.start(scheduler: scheduler, reservation: reservation)
        var guardianFinished = false
        defer { if !guardianFinished { CommandGuardian.finish(group) } }
        let pid = try spawn(arguments, group: group)
        _ = kill(group, SIGUSR2)
        let terminal = open("/dev/tty", O_RDWR | O_CLOEXEC)
        let foreground = terminal >= 0 ? tcgetpgrp(terminal) : -1
        let controlsTerminal = foreground > 0 && foreground == getpgrp()
        if controlsTerminal { _ = tcsetpgrp(terminal, group) }
        var reaped = false
        defer {
            if controlsTerminal, tcgetpgrp(terminal) == group { _ = tcsetpgrp(terminal, foreground) }
            if terminal >= 0 { close(terminal) }
            if !reaped {
                _ = kill(-group, SIGKILL)
                _ = waitpid(pid, nil, 0)
            }
        }
        var cancelAt: Double?
        var killSent = false
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if cancelAt == nil, FileManager.default.fileExists(atPath: store.file(reservation.id, "cancel").path) {
                _ = kill(-group, SIGTERM)
                _ = kill(-group, SIGCONT)
                cancelAt = now
            }
            if let cancelAt, now >= cancelAt + 2, !killSent {
                _ = kill(-group, SIGKILL)
                killSent = true
            }
            var status = siginfo_t()
            guard waitid(P_PID, id_t(pid), &status, WEXITED | WSTOPPED | WNOHANG | WNOWAIT) == 0 else {
                throw LatchError.system("observe scheduled command")
            }
            if status.si_pid == pid, status.si_code == CLD_STOPPED {
                // Return terminal control to the caller while the foreground workload is suspended.
                _ = waitid(P_PID, id_t(pid), &status, WSTOPPED | WNOHANG)
                if cancelAt == nil, controlsTerminal, tcgetpgrp(terminal) == group,
                    [SIGTTIN, SIGTTOU].contains(status.si_status)
                {
                    _ = kill(-group, SIGCONT)
                } else if cancelAt == nil,
                    !FileManager.default.fileExists(atPath: store.file(reservation.id, "cancel").path)
                {
                    if controlsTerminal { _ = tcsetpgrp(terminal, foreground) }
                    _ = kill(getpid(), SIGSTOP)
                    if controlsTerminal { _ = tcsetpgrp(terminal, group) }
                    _ = kill(-group, SIGCONT)
                }
            }
            let exited = status.si_pid == pid && [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(status.si_code)
            let descendants = exited ? try liveGroupMembers(group, excluding: pid).filter { $0 != group } : []
            if exited, descendants.isEmpty {
                var termination: Int32 = 0
                guard waitpid(pid, &termination, 0) == pid else {
                    throw LatchError.system("reap scheduled command")
                }
                reaped = true
                if controlsTerminal { _ = tcsetpgrp(terminal, foreground) }
                CommandGuardian.finish(group)
                guardianFinished = true
                try scheduler.withdraw(reservation.id)
                let number = termination & 0x7f
                if number != 0 {
                    signal(number, SIG_DFL)
                    raise(number)
                    exit(128 + number)
                }
                exit((termination >> 8) & 0xff)
            }
            let delay = cancelAt.map { killSent ? 3600 : max(0, $0 + 2 - now) } ?? 3600
            if let number = watcher.wait(seconds: delay, pids: exited ? descendants : [pid]), number != SIGCHLD {
                _ = kill(-group, number)
            }
        }
    }

    static func resumeCancelledSupervisor(_ task: ScheduledTask) {
        guard task.pid > 1 else { return }
        var info = proc_bsdinfo()
        guard proc_pidinfo(task.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
            info.pbi_uid == geteuid()
        else { return }
        // A reused PID belongs to a process born after this ticket was created.
        let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        guard started <= task.queuedAt.timeIntervalSince1970 else { return }
        _ = kill(task.pid, SIGCONT)
    }

    private static func spawn(_ arguments: [String], group: Int32) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws {
            guard code == 0 else {
                throw LatchError("spawn scheduled command: \(String(cString: strerror(code)))", exitCode: 74)
            }
        }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, group))
        var defaults = sigset_t(0)
        for number in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT, SIGCHLD, SIGPIPE, SIGTTOU, SIGTTIN] {
            sigaddset(&defaults, number)
        }
        var mask = sigset_t(0)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        let argv = arguments.map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { for pointer in argv + environment { free(pointer) } }
        guard (argv + environment).allSatisfy({ $0 != nil }) else { throw LatchError("out of memory", exitCode: 71) }
        var pointers = argv + [nil]
        var variables = environment + [nil]
        var pid: Int32 = 0
        let code = posix_spawnp(&pid, pointers[0]!, nil, &attributes, &pointers, &variables)
        guard code == 0 else {
            throw LatchError(
                "cannot execute \(arguments[0]): \(String(cString: strerror(code)))",
                exitCode: code == ENOENT ? 127 : 126)
        }
        return pid
    }

    static func liveGroupMembers(_ group: Int32, excluding leader: Int32) throws -> [Int32] {
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard needed >= 0 else { throw LatchError.system("inspect scheduled process group") }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.stride + 16)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count))
        }
        guard bytes >= 0 else { throw LatchError.system("inspect scheduled process group") }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride).filter { pid in
            guard pid > 0, pid != leader else { return false }
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                return info.pbi_status != SZOMB
            }
            return kill(pid, 0) == 0 || errno == EPERM
        }
    }
}
