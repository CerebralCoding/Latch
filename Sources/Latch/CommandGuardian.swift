import Darwin
import Foundation

enum CommandGuardian {
    static func start(scheduler: Scheduler, reservation: TaskReservation) throws -> Int32 {
        var ready = [Int32](repeating: -1, count: 2)
        guard pipe(&ready) == 0 else { throw LatchError.system("create guardian readiness pipe") }
        defer { for fd in ready where fd >= 0 { close(fd) } }
        for index in ready.indices {
            if ready[index] < 3 {
                let duplicate = fcntl(ready[index], F_DUPFD_CLOEXEC, 3)
                guard duplicate >= 0 else { throw LatchError.system("duplicate guardian readiness descriptor") }
                close(ready[index])
                ready[index] = duplicate
            } else if fcntl(ready[index], F_SETFD, FD_CLOEXEC) < 0 {
                throw LatchError.system("protect guardian readiness descriptor")
            }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws {
            guard code == 0 else {
                throw LatchError("start command guardian: \(String(cString: strerror(code)))", exitCode: 74)
            }
        }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(
                posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
            )
        }
        let descriptors =
            [reservation.lease.descriptor, reservation.gate.descriptor]
            + (reservation.updatePermit.map { [$0.descriptor] } ?? [])
        for fd in descriptors + [ready[1]] {
            try check(posix_spawn_file_actions_addinherit_np(&actions, fd))
        }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(0)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
        let strings = [
            executable, "__command_guardian", scheduler.path, reservation.id, String(getpid()),
            String(ready[1]), String(reservation.lease.descriptor),
            String(reservation.gate.descriptor), String(reservation.updatePermit?.descriptor ?? -1),
        ].map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { for pointer in strings + environment { free(pointer) } }
        guard (strings + environment).allSatisfy({ $0 != nil }) else { throw LatchError("out of memory", exitCode: 71) }
        var argv = strings + [nil]
        var variables = environment + [nil]
        var pid: Int32 = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, &argv, &variables))
        close(ready[1])
        ready[1] = -1
        var byte: UInt8 = 0
        var count: Int
        repeat { count = read(ready[0], &byte, 1) } while count < 0 && errno == EINTR
        guard count == 1, byte == 1 else {
            _ = kill(pid, SIGKILL)
            _ = waitpid(pid, nil, 0)
            throw LatchError("command guardian did not become ready", exitCode: 74)
        }
        return pid
    }

    static func finish(_ pid: Int32) {
        _ = kill(pid, SIGUSR1)
        while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
    }

    static func run(path: String, id: String, parent: Int32, ready: Int32, descriptors: [Int32]) -> Int32 {
        guard UUID(uuidString: id) != nil, parent > 1, getpgrp() == getpid(), ready > 2,
            descriptors.count >= 2, descriptors.allSatisfy({ $0 > 2 && fcntl($0, F_GETFD) >= 0 })
        else { return 74 }
        defer { for fd in descriptors { close(fd) } }
        for number in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT, SIGPIPE, SIGUSR1, SIGUSR2] {
            signal(number, SIG_IGN)
        }
        do {
            let store = try DurableJobs(scheduler: Scheduler(path: path))
            let watcher = try QueueWatcher(directory: store.directory.path)
            try watcher.watchSignal(SIGUSR1)
            try watcher.watchSignal(SIGUSR2)
            var byte: UInt8 = 1
            guard write(ready, &byte, 1) == 1 else { throw LatchError.system("announce command guardian") }
            close(ready)
            var finishing = false
            var cancelAt: Double?
            while true {
                let members = try ScheduledCommand.liveGroupMembers(getpid(), excluding: getpid())
                let parentAlive = getppid() == parent
                if finishing || !parentAlive, members.isEmpty { return 0 }
                let now = ProcessInfo.processInfo.systemUptime
                if cancelAt == nil, FileManager.default.fileExists(atPath: store.file(id, "cancel").path) {
                    _ = kill(-getpid(), SIGTERM)
                    _ = kill(-getpid(), SIGCONT)
                    cancelAt = now
                }
                if let cancelAt, now >= cancelAt + 2 {
                    // The guardian remains the group leader until this final signal, preventing ID reuse.
                    _ = kill(-getpid(), SIGKILL)
                    return SIGKILL
                }
                let delay = cancelAt.map { max(0, $0 + 2 - now) } ?? 3600
                if watcher.wait(seconds: delay, pids: members + (parentAlive ? [parent] : [])) == SIGUSR1 {
                    finishing = true
                }
            }
        } catch {
            _ = kill(-getpid(), SIGKILL)
            return 74
        }
    }
}
