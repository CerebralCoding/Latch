import Darwin
import Foundation

final class MCPPseudoTerminal {
    let master: FileHandle
    let slave: FileHandle

    init(columns: Int, rows: Int) throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            throw LatchError.system("open pseudo-terminal")
        }
        master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slaveFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)
    }
}

extension MCPExecution {
    var outputDescriptor: Int32 {
        terminal?.master.fileDescriptor ?? stdout.fileHandleForReading.fileDescriptor
    }

    var inputDescriptor: Int32? {
        if terminal != nil {
            return stdoutOpen ? outputDescriptor : nil
        }
        return inputOpen ? inputPipe?.fileHandleForWriting.fileDescriptor : nil
    }

    func closeOutput() {
        stdoutOpen = false
        if let terminal {
            try? terminal.master.close()
        } else {
            try? stdout.fileHandleForReading.close()
        }
    }

    func relay(_ number: Int32) throws {
        guard !complete, exitedAt == nil else { throw LatchError("command already exited") }
        let group = stdoutOpen ? (terminal.map { tcgetpgrp($0.master.fileDescriptor) } ?? pid) : pid
        guard kill(-(group > 0 ? group : pid), number) == 0 else { throw LatchError.system("relay signal") }
    }

    func applyControls(_ controls: [MCPControl], store: DurableJobs) throws {
        // Signals and resizing must remain responsive even while stdin is backpressured.
        for var control in controls {
            if control.operation == "latch_input" {
                pendingInput.append(control)
                continue
            }
            do {
                guard !complete, exitedAt == nil, cancelAt == nil else {
                    throw LatchError("command is no longer accepting controls")
                }
                if let name = control.signal, let number = MCPControl.signals[name] {
                    try relay(number)
                } else if let terminal, stdoutOpen, let columns = control.columns, let rows = control.rows {
                    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
                    guard ioctl(terminal.master.fileDescriptor, TIOCSWINSZ, &size) == 0 else {
                        throw LatchError.system("resize terminal")
                    }
                } else {
                    throw LatchError("terminal unavailable")
                }
                control.state = "delivered"
            } catch {
                control.state = "failed"
                control.error = String(describing: error)
            }
            try store.acknowledge(control, id: id)
        }
        try flushInput(store: store)
    }

    func flushInput(store: DurableJobs) throws {
        while !pendingInput.isEmpty {
            var control = pendingInput[0]
            do {
                guard !complete, exitedAt == nil, cancelAt == nil, let fd = inputDescriptor else {
                    throw LatchError("stdin is closed or command is exiting")
                }
                let bytes = control.data ?? Data()
                if control.bytesWritten < bytes.count {
                    let count = bytes.withUnsafeBytes {
                        write(
                            fd, $0.baseAddress!.advanced(by: control.bytesWritten), bytes.count - control.bytesWritten)
                    }
                    if count < 0, errno == EAGAIN || errno == EINTR {
                        return
                    }
                    guard count > 0 else { throw LatchError.system("write workload input") }
                    control.bytesWritten += count
                    pendingInput[0] = control
                    if control.bytesWritten < bytes.count {
                        return
                    }
                }
                if control.eof {
                    try inputPipe?.fileHandleForWriting.close()
                    inputOpen = false
                }
                control.state = "delivered"
            } catch {
                control.state = "failed"
                control.error = String(describing: error)
            }
            pendingInput.removeFirst()
            try store.acknowledge(control, id: id)
        }
    }
}
