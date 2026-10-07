import Foundation

enum CLIHelp {
    static let overview = """
        Latch — local workload scheduler for autonomous agents sharing an Apple Silicon Mac.

        Inspect
          tui                  Live operator dashboard, charts, and queue controls
          view                 Service, running work, queue, and admission blockers
          list                 Outstanding jobs with copyable IDs
          sensors              Collect native sensor readings
          status               Process latch: free (0) or held (75)

        Operate
          prioritize JOB_ID    Prioritize a queued job; never preempts running work
          clear                Cancel never-started jobs; preserve started work
          stop                 Cancel all outstanding jobs, including running work
          service ACTION       install, start, stop, status, uninstall, run
          update | rollback    Drain work and replace the installed binary

        Execute
          schedule … -- COMMAND    FIFO scheduling with resource and thermal guards
          run … -- COMMAND         Queue a command; --shared permits overlap
          wait | guard             Wait without protecting subsequent work
          mcp                      Agent transport over stdin/stdout

        Usage: latch COMMAND [OPTIONS] [OPERANDS]
        Options use --long-name; values accept --option VALUE or --option=VALUE.
        Standalone -- ends Latch options; run/schedule require it before COMMAND.
        run/schedule forward everything after that boundary unchanged.
        Diagnostics use short text by default; --verbose expands it, --json emits data.
        Use latch COMMAND --help or latch help COMMAND for command-specific help.
        Agents use MCP; operator queue overrides are for humans.
        latch --version prints the binary version.
        latch --about prints author, license, contact, and sponsorship information.
        Exit codes: 64 usage, 69 service unavailable, 71 allocation, 74 I/O,
                    75 busy/timeout, 126 cannot execute, 127 command not found.
        run/schedule otherwise return the command's exit status.
        """

    static func text(for command: Options.Command?, service: Options.ServiceAction? = nil) -> String {
        guard let command else { return overview }
        let file = "File: --file PATH, then LATCH_FILE, then ~/.local/state/latch/default.lock."
        let output = "Short text by default. --verbose expands diagnostics; --json emits the full snapshot. Choose one."
        switch command {
        case .tui:
            return """
                Usage: latch tui [--file PATH] [--interval SECONDS]
                Open the native terminal dashboard. Requires an interactive Unicode terminal.
                Jobs are on the overview. Arrows or j/k: select. Enter/Tab: details. Tab/Esc: close details.
                /: filter jobs. s: sort. h: retained history. Space: freeze display. +/-: refresh interval.
                P: prioritize selected job. x: cancel selected job. C: clear never-started work. S: stop all.
                Queue changes require confirmation and a matching running service; guards still apply.
                i: sensors modal. ?: help modal. Same key or Esc closes. q or Ctrl-C: quit.
                Refresh restores your last setting, initially 1 second (range 0.5–60).
                --interval overrides the saved value. Both --interval and +/- save your selection.
                Settings: $XDG_CONFIG_HOME/latch/tui.json, default ~/.config/latch/tui.json.
                Uses cached scheduler sensors; never actively samples. Charts cover this session.
                NO_COLOR disables color. Narrow terminals use a compact layout.
                \(file)
                """
        case .view, .list:
            let purpose =
                command == .view
                ? "Show service health, outstanding jobs, and why the next job is waiting."
                : "List outstanding jobs with full, copyable IDs; completed history is omitted."
            return """
                Usage: latch \(command.rawValue) [--file PATH] [--verbose | --json]
                \(purpose)
                \(output)
                Uses cached readings; never samples or reserves resources.
                Shared samples arrive every second, whether idle or running jobs.
                No start-time estimate is made.
                \(file)
                """
        case .sensors:
            return """
                Usage: latch sensors [--verbose | --json]
                Collect CPU/GPU/ANE, memory, thermal, disk, and temperature readings.
                \(output)
                Active sampling can affect measurements; use view for cached diagnostics.
                """
        case .prioritize:
            return """
                Usage: latch prioritize JOB_ID [--file PATH]
                Move a queued job to the front for its next admission. Copy its full ID from latch list.
                Thermal guards and isolation still apply. Never preempts or starts new work.
                Requires the matching running service. Human operator override only.
                \(file)
                """
        case .clear:
            return """
                Usage: latch clear [--file PATH]
                Request cancellation of jobs that have never started.
                Running jobs and started checkpoints, including parked iterations, are preserved.
                Cancellation is asynchronous; results and retry keys remain available.
                Requires the matching running service. Human operator override only.
                \(file)
                """
        case .stop:
            return """
                Usage: latch stop [--file PATH]
                Request cancellation of all outstanding jobs in the selected queue, across all scopes.
                Includes running jobs and parked checkpoints. Completed results and retry keys remain.
                Active workloads receive TERM, then KILL after two seconds if necessary.
                Cancellation is asynchronous; use latch list or latch view to check outstanding work.
                The scheduler stays running and accepts subsequent submissions. Unmanaged processes are unaffected.
                Requires the matching running service. Human operator override only.
                \(file)
                """
        case .service:
            if let service {
                let selectsFile = [.run, .install, .status].contains(service)
                let description: String
                switch service {
                case .install:
                    description =
                        "Copy to ~/.local/bin/latch and start the per-user login service.\nInitial install refuses an existing installation; use update to replace it."
                case .start:
                    description = "Load the installed scheduler service. Accepted jobs are retained."
                case .stop:
                    description =
                        "Unload the scheduler service. Accepted jobs are retained.\nUse latch stop to cancel workloads while leaving the scheduler running."
                case .status:
                    description = "Report service state; exit 69 when stopped.\n\(output)"
                case .uninstall:
                    description = "Remove the installation; retain queue data and logs."
                case .run:
                    description = "Serve in the foreground. This is a persistent service, not a queued workload."
                }
                return """
                    Usage: latch service \(service.rawValue)\(selectsFile ? " [--file PATH]" : "")\(service == .status ? " [--verbose | --json]" : "")
                    \(description)
                    Label: \(ServiceInstallation.label)
                    \(selectsFile ? file : "Uses the installed service configuration.")
                    """
            }
            return """
                Usage: latch service ACTION [OPTIONS]
                install    Copy to ~/.local/bin/latch and start the per-user login service.
                start/stop Load or unload the installed service; accepted jobs are retained.
                status     Report service state; exit 69 when stopped. \(output)
                uninstall  Remove the installation; retain queue data and logs.
                run        Serve in the foreground (not a queued workload).
                Label: \(ServiceInstallation.label)
                Initial install refuses an existing installation. Use update to replace it.
                --file applies to install, run, and status. --verbose and --json apply only to status.
                \(file)
                """
        case .update, .rollback:
            return """
                Usage: latch \(command.rawValue) [--timeout SECONDS] [--restart-service]
                Drain accepted work before atomically replacing the installed binary.
                Run update from the newly built binary. The prior binary is retained for rollback.
                Replacing a binary restarts a loaded service. --restart-service forces a restart.
                A stopped service stays stopped. Drain timeout defaults to 600 seconds.
                Reconnect MCP hosts after replacement; retained results remain available by job ID.
                Never submit installation or update commands through Latch itself.
                """
        case .run:
            return """
                Usage: latch run [--file PATH] [--shared] [--timeout SECONDS | --no-wait] -- COMMAND [ARG...]
                run queues the command through the running scheduler with FIFO admission and thermal guards.
                --shared permits shared work while excluding exclusive work.
                Defaults: 1 CPU core, 512 MiB, CPU <=85°C, GPU <=80°C; no measurement quiet window.
                Operator clear and stop apply to run jobs, including their workload process groups.
                Use schedule for measurements or explicit resource and temperature requirements.
                Latch options precede --. All following arguments belong to COMMAND, including its flags.
                Command arguments, streams, signals, and exit status are preserved. Do not nest latches.
                \(file)
                """
        case .wait:
            return """
                Usage: latch wait [--file PATH] [--timeout SECONDS | --no-wait]
                Wait for exclusive holders to leave; shared holders do not block this check.
                Returns immediately when free. Protects no subsequent work; use run or schedule for that.
                \(file)
                """
        case .status:
            return """
                Usage: latch status [--file PATH]
                Print free (exit 0) or held (exit 75), including shared holders.
                This is process-latch state, not admission eligibility; use view for scheduler status.
                \(file)
                """
        case .schedule, .guard:
            return """
                Usage: latch \(command.rawValue) [--file PATH] [--name NAME] [--mode isolated|batch]
                       [--cpu CORES] [--memory-mib MIB]\(command == .schedule ? " [--gpu] [--io] [--bandwidth]" : "")
                       [--max-cpu-temp C] [--max-gpu-temp C] [--cooldown SECONDS]
                       [--standalone] [--timeout SECONDS | --no-wait]\(command == .schedule ? " -- COMMAND [ARG...]" : "")
                \(command == .schedule ? "Queue and protect the full foreground command. Finite work only." : "Wait, print an admitted JSON snapshot, and release; protects no subsequent work.")
                Defaults: isolated, 1 CPU core, 512 MiB, CPU/GPU <=55°C for 5 seconds.
                Operators declare peak resources and match command worker limits. Reservations are advisory.
                Batch work may overlap within capacity. Isolated work also requires a quiet window.
                FIFO prevents newer jobs overtaking an older blocked ticket. Runtime is never limited.
                Missing/stale sensors block admission. Temperature limits: 1–125°C; cooldown: 0–3600s.
                Timeout bounds admission only; --no-wait fails immediately. Requires the service unless --standalone.
                \(command == .schedule ? "Latch options precede --; command arguments, streams, signals, and exit status are preserved." : "Use schedule to protect subsequent work.")
                Do not nest scheduling.
                \(file)
                """
        case .mcp:
            return """
                Usage: latch mcp [--file PATH]
                Serve agent tools over newline-delimited JSON-RPC on stdin/stdout.
                Uses the matching installed scheduler; never installs, replaces, or restarts it.
                Agents declare sensitivity; Latch owns resource planning, FIFO, and thermal guards.
                Submit finite foreground work only. Never submit services, watch modes, or REPLs.
                \(file)
                """
        case .version: return "Usage: latch --version\nPrint the binary version without contacting the service."
        case .about:
            return
                "Usage: latch --about\nPrint author, license, contact, and sponsorship information without contacting the service."
        case .help: return overview
        }
    }
}
