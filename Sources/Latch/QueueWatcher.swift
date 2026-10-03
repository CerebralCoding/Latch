import Darwin
import Foundation

final class QueueWatcher {
    private let queue: Int32
    private let directory: Int32
    private var watchedPIDs: Set<Int32> = []

    init(directory path: String) throws {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw LatchError.system("watch scheduler directory") }
        let queue = kqueue()
        guard queue >= 0 else {
            close(descriptor)
            throw LatchError.system("create scheduler event queue")
        }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
        var event = kevent(
            ident: UInt(descriptor), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE), data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            close(descriptor)
            close(queue)
            throw LatchError.system("register scheduler directory")
        }
        directory = descriptor
        self.queue = queue
    }

    deinit {
        close(queue)
        close(directory)
    }

    func watchSignal(_ number: Int32) throws {
        var event = kevent(
            ident: UInt(number), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: 0, data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            throw LatchError.system("register command signal")
        }
    }

    @discardableResult
    func wait(seconds: Double, pids: [Int32]) -> Int32? {
        watchedPIDs.formIntersection(pids)
        for pid in pids where pid > 0 && watchedPIDs.insert(pid).inserted {
            var process = kevent(
                ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
            if kevent(queue, &process, 1, nil, 0, nil) != 0 {
                return nil
            }
        }
        var event = kevent()
        var timeout = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - floor(seconds)) * 1_000_000_000))
        let count = kevent(queue, nil, 0, &event, 1, &timeout)
        return count > 0 && event.filter == Int16(EVFILT_SIGNAL) ? Int32(event.ident) : nil
    }
}
