import Foundation

struct Options {
    enum Command: String {
        case run, wait, status, schedule, tasks, sensors, help
    }

    var command: Command
    var file: String?
    var shared = false
    var timeout: Double?
    var childArguments: [String] = []
    var taskName: String?
    var requirements = TaskRequirements()

    init(arguments: [String]) throws {
        guard let first = arguments.first else {
            throw LatchError("expected a command; see latch --help")
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
        var seen: Set<String> = []
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument != "--", !seen.insert(argument).inserted {
                throw LatchError("duplicate option '\(argument)'")
            }
            switch argument {
            case "--help", "-h":
                self.command = .help
                return
            case "--file":
                guard command != .sensors, file == nil, index < arguments.count, !arguments[index].isEmpty else {
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
                guard [.run, .wait, .schedule].contains(command), timeout == nil, index < arguments.count,
                      let value = Double(arguments[index]), value.isFinite,
                      value >= 0, value <= Double(Int32.max)
                else {
                    throw LatchError("--timeout requires seconds between 0 and \(Int32.max); cannot combine with --no-wait")
                }
                timeout = value
                index += 1
            case "--no-wait":
                guard [.run, .wait, .schedule].contains(command), timeout == nil else {
                    throw LatchError("--no-wait cannot be repeated, combined with --timeout, or used with status")
                }
                timeout = 0
            case "--name", "--mode", "--cpu", "--memory-mib":
                guard command == .schedule, index < arguments.count else {
                    throw LatchError("\(argument) requires a value and is only valid for schedule")
                }
                let value = arguments[index]
                index += 1
                switch argument {
                case "--name":
                    guard !value.isEmpty, value.count <= 128 else { throw LatchError("task name must contain 1–128 characters") }
                    taskName = value
                case "--mode":
                    guard let mode = TaskRequirements.Mode(rawValue: value) else { throw LatchError("mode must be isolated or batch") }
                    requirements.mode = mode
                case "--cpu":
                    guard let count = Int(value) else { throw LatchError("--cpu requires an integer core count") }
                    requirements.cpuCores = count
                default:
                    guard let count = Int(value) else { throw LatchError("--memory-mib requires an integer MiB count") }
                    requirements.memoryMiB = count
                }
            case "--gpu", "--io", "--bandwidth":
                guard command == .schedule else { throw LatchError("\(argument) is only valid for schedule") }
                if argument == "--gpu" {
                    requirements.gpu = true
                }
                if argument == "--io" {
                    requirements.io = true
                }
                if argument == "--bandwidth" {
                    requirements.bandwidth = true
                }
            case "--":
                guard command == .run || command == .schedule else { throw LatchError("only run and schedule accept a command") }
                childArguments = Array(arguments[index...])
                index = arguments.count
            default:
                throw LatchError("unexpected argument '\(argument)'; use -- before the command")
            }
        }
        if command == .run || command == .schedule, childArguments.isEmpty || childArguments[0].isEmpty {
            throw LatchError("\(command.rawValue) requires -- followed by a command")
        }
        if command == .schedule {
            try requirements.validate()
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
      latch schedule [--file PATH] [--name NAME] [--mode isolated|batch]
                     [--cpu CORES] [--memory-mib MIB] [--gpu] [--io] [--bandwidth]
                     [--timeout SECONDS | --no-wait] -- COMMAND [ARG...]
      latch tasks [--file PATH]
      latch sensors

    schedule  Queue a named task until reservations and native sensors allow it.
              Defaults: isolated, 1 CPU core, 512 MiB. Batch tasks may overlap
              within CPU/memory budgets; GPU, I/O, and bandwidth are exclusive
              resources when requested. Declare the command's peak requirements.
              FIFO admission prevents new work overtaking a waiting measurement.
    tasks     JSON snapshot of queued/running tasks, PIDs, reservations, sensors,
              and waiting reasons. Completed/crashed tasks are pruned by leases.
    sensors   Sample native macOS CPU, GPU, ANE, memory, thermal, and disk sensors
              and print JSON. No macmon executable, daemon, or root access needed.

    Isolated tasks require no running Latch tasks and two seconds of quiet:
    CPU <=5% overall / <=25% busiest core, GPU <=2%, ANE <=0.1 W,
    disk <=1 MiB/s, normal memory pressure, and nominal thermal state.
    All scheduled tasks leave 10% physical memory headroom. Batch admission also
    requires CPU load <=80%; GPU/I/O requests require those resources to be idle.
    Unknown/stale required sensors block admission. GPU/ANE use private IOReport
    APIs and may be unavailable on some Macs. Latch requires macOS 26 or newer.

    Scheduler state lives beside the latch in PATH.queue (private to this user).
    Queue changes/process exits wake waiters; sensor eligibility is rechecked at
    most once per second by one waiting agent. Automatic sampling stops behind
    an exclusive latch. Sensors observe background load, but cannot prevent an
    unrelated process from starting later. Use isolated mode for measurements.
    A schedule timeout includes admission/sampling. A no-wait attempt may sample
    once; it does not wait for a quiet window. run retains its original behavior.

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
      latch schedule --name benchmark -- ./benchmark
      latch schedule --mode batch --cpu 4 --memory-mib 4096 -- swift build -j 4
      latch schedule --mode batch --gpu --memory-mib 8192 -- ./inference
      latch tasks
    """
}
