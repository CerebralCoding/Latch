import Darwin
import Foundation

enum TerminalKey: Equatable {
    case character(Character)
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, escape, tab, backspace, quit, suspend
}

struct TerminalInput {
    private var bytes: [UInt8] = []
    private var pasting = false

    mutating func feed(_ data: Data, flushEscape: Bool = false) -> [TerminalKey] {
        bytes.append(contentsOf: data)
        var keys: [TerminalKey] = []
        let sequences: [String: TerminalKey] = [
            "[A": .up, "[B": .down, "[C": .right, "[D": .left,
            "OA": .up, "OB": .down, "OC": .right, "OD": .left,
            "[H": .home, "[F": .end, "OH": .home, "OF": .end,
            "[1~": .home, "[4~": .end, "[7~": .home, "[8~": .end,
            "[5~": .pageUp, "[6~": .pageDown, "[Z": .left,
        ]
        while let byte = bytes.first {
            if pasting {
                let end: [UInt8] = [27, 91, 50, 48, 49, 126]
                if bytes.starts(with: end) {
                    bytes.removeFirst(end.count)
                    pasting = false
                    continue
                }
                if end.starts(with: bytes) { break }
                bytes.removeFirst()
                continue
            }
            if byte == 27 {
                if bytes.count == 1 {
                    if flushEscape {
                        keys.append(.escape)
                        bytes.removeFirst()
                    }
                    break
                }
                if bytes[1] == 91 || bytes[1] == 79 {
                    guard let end = bytes.indices.dropFirst(2).first(where: { (64...126).contains(bytes[$0]) }) else {
                        if bytes.count > 64 || flushEscape { bytes.removeAll() }
                        break
                    }
                    let sequence = String(decoding: bytes[1...end], as: UTF8.self)
                    bytes.removeFirst(end + 1)
                    if sequence == "[200~" { pasting = true } else if let key = sequences[sequence] { keys.append(key) }
                    continue
                }
                // Alt-modified input is not an unmodified operator shortcut.
                bytes.removeFirst(2)
                continue
            }
            switch byte {
            case 3: keys.append(.quit)
            case 26: keys.append(.suspend)
            case 9: keys.append(.tab)
            case 10, 13: keys.append(.enter)
            case 8, 127: keys.append(.backspace)
            case 0...31: break
            default:
                let length = byte < 128 ? 1 : byte < 224 ? 2 : byte < 240 ? 3 : 4
                guard bytes.count >= length else { return keys }
                if let text = String(bytes: bytes.prefix(length), encoding: .utf8), let character = text.first {
                    keys.append(.character(character))
                }
                bytes.removeFirst(length)
                continue
            }
            bytes.removeFirst()
        }
        return keys
    }
}

final class TerminalSession {
    enum Event {
        case input(Data)
        case signal(Int32)
        case idle, end
    }
    let input: Int32
    let output: Int32
    private var original = termios()
    private var active = false
    private var queue: Int32 = -1
    private var signals: [(Int32, sigaction)] = []

    init(
        input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.input = input
        self.output = output
        guard isatty(input) == 1, isatty(output) == 1, environment["TERM"] != "dumb" else {
            throw LatchError("tui requires an interactive terminal; use latch view or latch list for text output")
        }
        guard tcgetattr(input, &original) == 0 else { throw LatchError("cannot read terminal settings", exitCode: 74) }
        queue = kqueue()
        guard queue >= 0 else { throw LatchError("cannot create terminal event queue", exitCode: 74) }
        do {
            try register(ident: UInt(input), filter: Int16(EVFILT_READ))
            for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT, SIGWINCH] {
                var old = sigaction()
                var ignored = sigaction()
                ignored.__sigaction_u.__sa_handler = SIG_IGN
                sigemptyset(&ignored.sa_mask)
                guard sigaction(number, &ignored, &old) == 0 else {
                    throw LatchError("cannot watch terminal signal", exitCode: 74)
                }
                signals.append((number, old))
                try register(ident: UInt(number), filter: Int16(EVFILT_SIGNAL))
            }
            try enter()
        } catch {
            restore()
            restoreSignals()
            close(queue)
            queue = -1
            throw error
        }
    }

    deinit {
        restore()
        restoreSignals()
        if queue >= 0 { close(queue) }
    }

    var size: (width: Int, height: Int) {
        var value = winsize()
        guard ioctl(output, TIOCGWINSZ, &value) == 0, value.ws_col > 0, value.ws_row > 0 else { return (79, 24) }
        // Keep the last terminal column unused to avoid autowrap, including on the bottom row.
        return (max(1, Int(value.ws_col) - 1), Int(value.ws_row))
    }

    func write(_ text: String) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LatchError("terminal output failed", exitCode: 74) }
                offset += count
            }
        }
    }

    func nextEvent() throws -> Event {
        var event = kevent()
        var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)
        let count = kevent(queue, nil, 0, &event, 1, &timeout)
        if count < 0, errno == EINTR { return .idle }
        guard count >= 0 else { throw LatchError("terminal event wait failed", exitCode: 74) }
        if count == 0 { return .idle }
        if event.filter == Int16(EVFILT_SIGNAL) { return .signal(Int32(event.ident)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let read = Darwin.read(input, &buffer, buffer.count)
        if read < 0, errno == EINTR || errno == EAGAIN { return .idle }
        guard read > 0 else { return .end }
        return .input(Data(buffer.prefix(read)))
    }

    func suspend() throws {
        restore()
        // SIGSTOP works even when launched in an orphaned process group (e.g. a multiplexer).
        raise(SIGSTOP)
        try enter()
    }

    func restore() {
        guard active else { return }
        try? write("\u{1B}[0m\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l")
        _ = tcsetattr(input, TCSANOW, &original)
        active = false
    }

    private func enter() throws {
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(input, TCSANOW, &raw) == 0 else {
            throw LatchError("cannot enter terminal raw mode", exitCode: 74)
        }
        active = true
        try write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h\u{1B}[2J\u{1B}[H")
    }

    private func register(ident: UInt, filter: Int16) throws {
        var event = kevent(
            ident: ident, filter: filter, flags: UInt16(EV_ADD | EV_ENABLE), fflags: 0, data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            throw LatchError("cannot register terminal event", exitCode: 74)
        }
    }

    private func restoreSignals() {
        for (number, original) in signals {
            var value = original
            _ = sigaction(number, &value, nil)
        }
        signals.removeAll()
    }
}
