import Foundation

struct Options {
    enum Command: String {
        case run, wait, status, help
    }

    var command: Command
    var file: String?
    var shared = false
    var timeout: Double?
    var childArguments: [String] = []

    init(arguments: [String]) throws {
        guard let first = arguments.first else {
            throw LatchError("expected run, wait, or status; see latch --help")
        }
        if ["help", "--help", "-h"].contains(first) {
            guard arguments.count == 1 else { throw LatchError("unexpected arguments after help") }
            command = .help
            return
        }
        guard let command = Command(rawValue: first) else {
            throw LatchError("unknown command '\(first)'; see latch --help")
        }
        self.command = command
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--help", "-h":
                self.command = .help
                return
            case "--file":
                guard file == nil, index < arguments.count, !arguments[index].isEmpty else {
                    throw LatchError("--file requires one nonempty path")
                }
                file = arguments[index]
                index += 1
            case "--shared":
                guard command == .run, !shared else {
                    throw LatchError("--shared may be specified once for run")
                }
                shared = true
            case "--timeout":
                guard command != .status, timeout == nil, index < arguments.count,
                      let value = Double(arguments[index]), value.isFinite,
                      value >= 0, value <= Double(Int32.max)
                else {
                    throw LatchError("--timeout requires seconds between 0 and \(Int32.max); cannot combine with --no-wait")
                }
                timeout = value
                index += 1
            case "--no-wait":
                guard command != .status, timeout == nil else {
                    throw LatchError("--no-wait cannot be repeated, combined with --timeout, or used with status")
                }
                timeout = 0
            case "--":
                guard command == .run else { throw LatchError("only run accepts a command") }
                childArguments = Array(arguments[index...])
                index = arguments.count
            default:
                throw LatchError("unexpected argument '\(argument)'; use -- before the command")
            }
        }
        if command == .run, childArguments.isEmpty || childArguments[0].isEmpty {
            throw LatchError("run requires -- followed by a command")
        }
    }

    func resolvedPath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let path = file ?? environment["LATCH_FILE"] {
            guard !path.isEmpty else { throw LatchError("latch file path must not be empty") }
            return path
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/latch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        return directory.appendingPathComponent("default.lock").path
    }

    static let usage = """
    Usage:
      latch run [--file PATH] [--shared] [--timeout SECONDS | --no-wait] -- COMMAND [ARG...]
      latch wait [--file PATH] [--timeout SECONDS | --no-wait]
      latch status [--file PATH]

    run     Hold an exclusive latch for a command. --shared lets cooperating
            background work overlap while excluding exclusive work.
    wait    Wait until no exclusive holder remains, then exit. This is only a
            checkpoint; use run to protect the full duration of work.
    status  Print free (exit 0) or held (exit 75), including shared holders.
            Status is a snapshot, not a reservation.

    The default is to block without polling. --no-wait fails immediately;
    --timeout bounds the wait in seconds (fractional values allowed).
    File: --file, then LATCH_FILE, then ~/.local/state/latch/default.lock.
    Explicit paths require an existing parent directory. All agents must use
    the same file on a local filesystem. Never delete or replace a latch file.

    run replaces itself with COMMAND, preserving arguments, streams, signals,
    and exit status. The lock descriptor is inherited by the command and its
    children; it releases when the last copy closes, including on process exit.
    Commands that close inherited descriptors can release the latch early.
    Coordination is advisory; every participant must cooperate. Waiters are
    not guaranteed FIFO ordering. No daemon or external dependencies.

    Exit codes: 64 usage, 74 I/O, 75 busy/timeout, 126 cannot execute,
                127 command not found. run otherwise returns COMMAND's status.

    Examples:
      latch run -- swift test
      latch run --shared -- swift build
      latch run --timeout 30 -- ./benchmark
      latch wait --no-wait
    """
}
