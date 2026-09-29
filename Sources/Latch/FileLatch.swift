import Darwin
import Foundation

final class FileLatch {
    let descriptor: Int32

    init(path: String) throws {
        let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard opened >= 0 else { throw LatchError.system("open \(path)") }
        let descriptor: Int32
        // Keep the lock out of stdin/stdout/stderr even when the caller closed them.
        if opened < 3 {
            let duplicate = fcntl(opened, F_DUPFD_CLOEXEC, 3)
            let failure = duplicate < 0 ? LatchError.system("duplicate latch descriptor") : nil
            close(opened)
            if let failure {
                throw failure
            }
            descriptor = duplicate
        } else {
            descriptor = opened
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = LatchError.system("inspect \(path)")
            close(descriptor)
            throw error
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
            close(descriptor)
            throw LatchError("latch must be a regular file owned by this user with one link", exitCode: 74)
        }
        self.descriptor = descriptor
    }

    deinit {
        // Unlinking here would allow waiters and new arrivals to lock different inodes.
        close(descriptor)
    }

    func acquire(shared: Bool, timeout: Double?) throws {
        let operation = shared ? LOCK_SH : LOCK_EX
        guard let timeout else {
            while flock(descriptor, operation) != 0 {
                if errno != EINTR {
                    throw LatchError.system("acquire latch")
                }
            }
            return
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while true {
            if flock(descriptor, operation | LOCK_NB) == 0 {
                return
            }
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EAGAIN || failure == EINTR else {
                throw LatchError.system("acquire latch")
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw LatchError("latch is busy (wait expired)", exitCode: 75)
            }
            let components = min(remaining, .milliseconds(10)).components
            var delay = timespec(tv_sec: Int(components.seconds), tv_nsec: Int(components.attoseconds / 1_000_000_000))
            _ = nanosleep(&delay, nil)
        }
    }

    func inheritAcrossExec() throws {
        guard fcntl(descriptor, F_SETFD, 0) == 0 else {
            throw LatchError.system("inherit latch descriptor")
        }
    }

    func release() {
        _ = flock(descriptor, LOCK_UN)
    }
}
