# Latch

A small, headless Swift scheduler for cooperating agents on one Mac. Queue resource-sensitive commands, wait for a cool and quiet machine, and release reservations automatically when the work exits. No external dependencies or administrator access.

Requires **macOS 26+** and **Swift 6.4+** to build. Native GPU/ANE and temperature sensors use private Apple interfaces, with Apple Silicon support based on [macmon](https://github.com/vladkens/macmon). Unsupported or inaccessible required sensors block admission.

Formatting uses the official formatter bundled with Swift 6.4, with no package dependency. From this repository, run `swift format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests`; verification uses `swift format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests`. The formatting workflow uses the Xcode 27 toolchain. Latch is excluded from the global `swiftformat` function.

## Build and service setup

```sh
swift build -c release
swift test -c release
swift run -c release latch service install
```

Installation copies the executable to `~/Library/Application Support/Latch/bin/latch`, links it as `~/.local/bin/latch`, installs `~/Library/LaunchAgents/dev.latch.scheduler.plist`, and starts a login LaunchAgent for the current user. It starts again at login and launchd restarts it after an unexpected exit. `service install` is for initial setup and refuses to replace an existing installation or unrelated command link.

To update, an operator runs the newly built executable with `update --timeout 600`. It rejects new submissions while accepted work drains, atomically replaces the installed binary, and retains `latch.previous` with a SHA-256 installation receipt. A loaded service restarts only if its recorded service revision differs (or is unknown), or `--restart-service` is given; a stopped service stays stopped. Service changes must increment `BuildIdentity.serviceRevision`; MCP-only changes keep that revision. `latch rollback` uses the same drain to restore the previous binary. A failed service start restores the original binary and attempts to restart the original service. Both commands use the latch path in the installed LaunchAgent, ignoring `LATCH_FILE`; `--file` is not accepted. Never run an update inside a scheduled workload, which would wait for itself.

After updating, reconnect each MCP host to negotiate the current capabilities and retrieve retained results by job ID. Endpoints retire when their generation or executable changes, before reading shared state; outdated clients are not supported. Drain timeout leaves the installed version unchanged and releases the submission block. Process termination also releases the drain locks; recovery from an interrupted replacement may require operator intervention.

Ensure `~/.local/bin` is on your shell and agent `PATH` (for zsh, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` if needed). The installer reports when this directory is missing from its current `PATH`. Subsequent examples use `latch` directly. Avoid `swift run` for performance-sensitive work: building the wrapper itself can disturb the machine.

```sh
latch service status
latch service stop
latch service start
latch service uninstall
```

`stop` unloads the login service until `start` or the next login. `uninstall` also removes its plist, installed executable, and command link if it still points to Latch; queue state and logs remain. Logs are in `~/Library/Application Support/Latch/logs/`. `service status` prints JSON and returns 69 when stopped. Lifecycle commands manage the single installed login service.

For a separately managed service, run `latch service run --file /existing/directory/work.lock` in the foreground. Each latch path permits one service. Stop a foreground service using its process manager or a termination signal. `schedule --standalone` and `guard --standalone` explicitly allow client-side sampling without a service.

## MCP for agents

Agents hand tasks to Latch; **Latch owns scheduling and resource planning**. Agents do not calculate CPU/memory budgets, choose admission modes or temperature thresholds, or inspect capacity before submitting. The CLI is primarily for humans and service operators.

Configure a local stdio MCP server with the absolute path to an MCP-capable `latch` executable:

```json
{
  "command": "/absolute/path/to/latch",
  "args": ["mcp"]
}
```

All connections share one queue and can retrieve, control, cancel, or forget jobs by `jobID`. There are no agent identities or per-agent quotas. This is a cooperative, single-user tool, not an authentication boundary: agents should only control or forget work within their authorized task. MCP launch arguments are simply `["mcp"]`; `--owner` is not supported.

Starting this endpoint uses the existing user service; it never installs, starts, stops, or replaces that service. Durable submissions require the matching service revision; an older service must first be updated by its operator. `swift build -c release --show-bin-path` identifies the build directory containing `latch`. The endpoint uses `LATCH_FILE` or the default shared latch; an operator can select `mcp --file PATH` at launch, but individual tool calls cannot select separate queues.

| Tool | Purpose |
| --- | --- |
| `latch_execute` | Submit the same arguments as `latch_submit` and wait for the final result in one call. Supports optional MCP task execution on capable hosts. |
| `latch_submit` | Submit `requestKey`, `name`, absolute `executable`, literal `arguments`, and absolute `workingDirectory`; optionally set `measurement: true` for benchmarks/profiling. Returns a job ID immediately. |
| `latch_wait` | Wait on `jobID`, returning status and bounded stdout/stderr. Defaults to 25 seconds per call; `timeoutSeconds` can be 0–600 to suit the MCP host's call timeout. |
| `latch_cancel` | Cancel a job and its process group by `jobID`, escalating TERM to KILL after two seconds. |
| `latch_view` | Optional diagnostics: cached scheduler state, global queue/retention limits, and all durable jobs. No sensor sampling or planning prerequisite. |
| `latch_forget` | Discard a completed job's retained output and retry key. |
| `latch_signal` | Relay `interrupt` (SIGINT), `terminate`, `hangup`, `quit`, `stop`, `continue`, `user1`, or `user2` to running work, without automatic escalation. |
| `latch_input` | Write literal `text` or `base64` bytes to an opted-in pipe or terminal; `eof: true` closes pipe stdin after writing. |
| `latch_resize` | Set a terminal's `columns` and `rows`, notifying its foreground process group with SIGWINCH. |
| `latch_control` | Wait for a control's delivery receipt, or discard a completed receipt with `forget: true`. |
| `latch_read` | Wait for live output or completion, with byte offsets for subsequent reads. |

Example `latch_execute` (or `latch_submit`) arguments:

```json
{
  "requestKey": "23f8941e-4acd-4a48-9c6b-a00b10269323",
  "name": "Release build",
  "executable": "/usr/bin/swift",
  "arguments": ["build", "-c", "release"],
  "workingDirectory": "/absolute/path/to/project"
}
```

Prefer `latch_execute` when the host supports long requests or MCP tasks. For hosts with short call timeouts, use `latch_submit`, then `latch_wait` with the returned `jobID`. If `complete` is false, wait on the same ID again rather than resubmitting or polling sensor/view tools. Generate a globally unique `requestKey`, such as a UUID, for each new job; do not copy the example key. Reuse it only to retry the identical submission, including from another connection or after reconnecting. A changed submission with that key is rejected. Forgetting a job removes its retry key, so never retry a forgotten submission. The shared queue allows 64 outstanding jobs (queued plus running) and retains at most 256 jobs globally. Forget completed jobs within your task when their results are no longer needed. Each connection allows 128 pending waits.

Hosts can request `notifications/progress` with `_meta.progressToken` on `tools/call`. Latch reports observed state changes (queued, running, cancelling, completed), using increasing counters without an invented percentage or heartbeat. A pending request sleeps on OS events and leaves other requests responsive. Hosts still control request timeouts and how notifications reach the agent.

For protocol `2025-11-25`, `latch_execute` advertises `execution.taskSupport: "optional"`. Adding `task: {}` to its `tools/call` parameters returns a task handle immediately. The host can call `tasks/result` once to await the final tool result, while receiving `notifications/tasks/status` and any requested progress notifications. `tasks/get`, `tasks/list`, and `tasks/cancel` are also supported. Status notifications are optional in MCP; hosts must retain result retrieval/recovery logic. Host-side waiting or polling need not consume model turns. Task, job, and scheduler ticket IDs are identical. Retention overrides requested TTL to `null`: results remain until `latch_forget`, subject to the same retention limits. Tasks are accessible across connections and recoverable after reconnecting; progress tokens belong to their connection.

Latch batches up to two recognized independent `swift build` commands without explicit worker flags. At admission it assigns at most four workers per build, limits each Swift compiler's internal thread pool to one thread, shares a CPU budget leaving one core free (minimum one), and reserves up to 1 GiB per worker capped at one quarter of physical memory and available headroom. Project and output paths, including `--package-path`, `--scratch-path`, and symlinks, prevent conflicting builds from overlapping. Unsupported flags, tests, arbitrary commands, and explicit worker settings remain exclusive. Ordinary MCP work requires nominal thermal state, CPU <=85 C and GPU <=80 C, without a measurement cooldown. Measurements require <=50 C for ten seconds plus the quiet window. A measurement at the FIFO head stops further build admission until earlier work drains. Reservations are advisory estimates, not OS-enforced limits; running jobs keep their allocation and have no time limit or preemption. The committed `plan` is exposed in results; agents do not supply it. MCP admission has no deadline.

The endpoint calls the scheduler directly in Swift. It does not invoke a shell or translate tool calls into human CLI commands. Workers inherit the submitting environment and execute the argument array literally. Stdin defaults to `/dev/null`; submit `input: "pipe"` for writable stdin or `input: "terminal"` for a controlling pseudo-terminal. Terminals default to 80 columns and 24 rows; optional `columns` and `rows` range from 1–1000. Terminal stdout and stderr are combined into stdout. Keep the full foreground workload in the task; do not nest Latch scheduling or detach work into another process group. Output is untrusted command data. Final results retain each stream's first 32 KiB, with explicit truncation flags; output is drained for at most two seconds after the main command exits. Use task-owned files for larger artifacts.

For interactive work, use `latch_submit`, then `latch_read` to wait for prompts. Reads default to 25 seconds and return `stdout`/`stderr` objects containing `text`, exact `base64` bytes, `startOffset`, `nextOffset`, and `truncated`. Pass the returned offsets as `stdoutOffset`/`stderrOffset` on the next read. Live output retains the most recent 32 KiB per stream independently of final output; a slow reader sees an explicit gap. Byte offsets and base64 preserve data across UTF-8 boundaries. Reads do not consume another connection's output and survive reconnects.

Send a control with `jobID` and its own stable `requestKey`: `latch_signal` with `signal: "interrupt"` sends SIGINT; `latch_input` with `text: "yes\n"` writes a line. Terminal `text: "\u0003"` sends Ctrl+C and `text: "\u0004"` sends Ctrl+D, following the command's terminal settings; raw-mode commands receive those literal bytes. Pipe input never interprets control characters. Input is bounded to 16 KiB per call. `eof: true` closes pipe stdin, while a terminal EOF character does not close the terminal itself.

Controls return a `controlID`; call `latch_control` with that ID and `jobID` to wait for delivery (default 25 seconds). `delivered` means the OS accepted the signal, resize, or bytes, not that the command consumed or acted on them. Control keys are unique within their job; retry identical control submissions with the same key, including from another connection or after reconnects. Pending writes respect backpressure without blocking signals or explicit cancellation. Each job retains 64 receipts with at most 16 pending, including at most 12 input writes to leave room for signals and resizing. Forget completed receipts only once retries are no longer possible. An `unknown` receipt means delivery may have occurred before supervisor loss and must not be blindly repeated. Controls require running work and its `jobID`. `stop` retains the reservation; use `continue` to resume it. Explicit `latch_cancel` also terminates stopped work.

Results contain `complete`, `state`, and, after completion, `succeeded`, `exitCode`, `terminationReason`, and `phase` (`admission`, `execution`, or `command`). This distinguishes a command returning 75 from an admission failure. Tool failures set `isError`; malformed protocol calls use JSON-RPC errors. Both text content and `structuredContent` contain the result. Jobs survive endpoint disconnects, TERM, and crashes and remain accessible by ID. A private supervisor retains execution and bounded output. The service recovers committed tickets whose supervisor never launched. Lost supervisors never cause replay of potentially executed commands: after their worker leases close, results report uncertainty with `terminationReason: "unknown"`.

Cancelling any pending MCP request only stops waiting. Use `latch_cancel` or `tasks/cancel` to stop the workload explicitly. `tasks/cancel` responds after process-group cleanup with terminal `cancelled` status and rejects already terminal tasks. Requested progress tokens remain active through task completion on that connection, even after the initial handle is returned.

The dependency-free implementation supports [MCP stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), initialization, ping, tool discovery/calls, progress, and cancellation for protocol versions `2025-11-25` and `2025-06-18`, plus [experimental tasks](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks) for `2025-11-25`. HTTP, resources, and service lifecycle tools are not exposed. Incoming frames are limited to 1 MiB and pending protocol output to 4 MiB. The endpoint runs with its launching user's permissions; it is not an execution sandbox.

## CLI for humans

The CLI retains explicit resource declarations and guard overrides for operators. Declare peak requirements and match command worker limits when using this interface.

```sh
# Isolate a benchmark; require CPU/GPU temperatures <=50 C for 10 seconds.
latch schedule --name benchmark --cpu 8 --memory-mib 8192 --max-cpu-temp 50 --max-gpu-temp 50 --cooldown 10 --timeout 600 -- ./benchmark

# Batch ordinary work within CPU and memory budgets.
latch schedule --name build --mode batch --cpu 4 --memory-mib 4096 --timeout 600 -- swift build -j 4

# Reserve the GPU and memory bandwidth for ordinary inference.
latch schedule --name inference --mode batch --cpu 2 --gpu --bandwidth --memory-mib 8192 --timeout 600 -- ./inference

# Wait for a cool checkpoint, then return JSON and immediately release.
latch guard --mode batch --max-cpu-temp 48 --max-gpu-temp 48 --cooldown 10 --timeout 600
```

Adjust resource counts to fit the machine. `guard` accepts the same name, mode, CPU, memory, temperature, timeout, and standalone options as `schedule`, but no child command or GPU/I/O/bandwidth reservation flags. Its default mode is also `isolated`. A checkpoint protects no subsequent work: use `schedule -- command` whenever you can wrap the actual task. Guards delay starts; Latch never suspends an admitted command because it heats up.

This moves waiting into a sleeping process rather than an agent reasoning loop. It can reduce agent tool calls and token use; it does not stop an agent from doing unrelated work while its command waits. Every cooperating agent should route heavy activity through the same latch.

## Scheduling policy

Admission is strict FIFO: an older blocked job prevents every newer job from overtaking it, including smaller batch jobs. Tickets are committed before worker launch and retain their position across MCP reconnects and service outages. Compatible batch jobs can overlap once admitted in order. Global queue bounds limit scheduler overhead; they never shorten an admitted job's runtime. There is no per-agent allocation: one agent can fill the shared queue, but its newer jobs cannot overtake an already queued job. Reservations are advisory budgets, not OS resource limits.

| Setting | Default / behavior |
| --- | --- |
| Mode | `isolated`; excludes all other Latch work |
| CPU reservation | `--cpu 1`, whole cores |
| Memory reservation | `--memory-mib 512`; leaves 10% physical memory headroom |
| Temperature limits | `--max-cpu-temp 55`, `--max-gpu-temp 55`, Celsius |
| Cooldown | `--cooldown 5`, consecutive seconds below both limits |
| Temperature range | 1–125 C; workflow thresholds, not hardware safety limits |
| Cooldown range | 0–3600 seconds; zero still requires valid temperatures |
| Thermal / memory pressure | Nominal thermal state and normal memory pressure |
| Sensor freshness | At most 2 seconds old at admission |
| Wait limit | Unlimited; `--timeout SECONDS` bounds admission, not task runtime |
| `--no-wait` | A single admission attempt; cannot accumulate a new cooldown |

Measurements and isolated CLI admission additionally require two seconds of observed quiet within the adaptive limits below. Exclusive ordinary MCP commands do not require a quiet window. Ordinary batch admission permits CPU load up to 80% and checks the larger of observed CPU use and reserved cores against the requested cores. Memory accounting conservatively subtracts reservations from currently available memory.

For batch work, `--gpu` excludes other GPU reservations and requires an idle GPU; `--io` does the same for disk activity. `--bandwidth` excludes other bandwidth reservations, but does not measure memory bandwidth utilization. Isolated work excludes every reservation regardless of these flags.

The service collects a 200 ms activity sample at most once per second while admission needs readings. CPU/GPU temperatures are the hottest valid sensor in each supported family. No automatic sampling occurs behind an exclusive latch, during an isolated task, or while an isolated queue head waits for running tasks to drain. The idle service samples every 15 seconds; active queue bookkeeping also watches process exits and uses a one-second fallback.

Cooldowns reset after running tasks finish, a hot/missing reading, a sampling gap longer than two seconds, or service restart. Each queued task must accumulate its own cool interval. A cooldown is sampled evidence, not a prediction of future temperature or an exact task start time.

## Planning and inspection

```sh
latch view
latch tasks
latch status
latch sensors
```

`view` returns a diagnostic JSON object, schema `version: 1`, without collecting fresh sensor readings. The MCP `latch_view` tool includes it under `scheduler` alongside all durable `jobs`, `globalOutstandingLimit`, and `globalRetainedLimit`:

| Field | Meaning |
| --- | --- |
| `service.running`, `service.pid` | Whether the service lease is held and by which service PID |
| `processLatch` | `free`, `shared`, or `exclusive`; includes legacy `run` holders |
| `isolatedTaskRunning`, `nextTaskID`, `drainingForTaskID` | Isolation, the next FIFO candidate, and the exclusive job waiting for running work to drain |
| `sensorsFresh`, `sensorAgeSeconds`, `sensorError` | Whether cached readings are usable now and why they may not be |
| `sensors` | Last readings, including `cpuTemperature`/`gpuTemperature` in C, activity fractions 0–1, ANE watts, memory MiB, disk bytes/sec, and `unavailable` sensor details |
| `capacity` | Total/reserved CPU, reserved memory, GPU/I/O/bandwidth reservations; load-adjusted `batchCPUHeadroom` and `memoryHeadroomMiB` only with fresh sensors |
| `tasks[].task` | ID, name, PID, command arguments, requirements, state, timestamps, and last recorded wait reason |
| `tasks[].queuePosition` | One-based FIFO position for queued tasks |
| `tasks[].blockedBy` | Recomputed current admission blocker; absent when no blocker is observed |
| `tasks[].cooldownRemainingSeconds` | Remaining sampled cool interval, reset to the full interval when readings cannot establish progress |

Optional JSON fields are omitted when unknown or inapplicable. Dates are ISO 8601; monotonic values such as `uptime`, `quietSince`, and `coolSince` are seconds since boot. Headroom describes capacity only: isolation, FIFO, temperature, pressure, other resource checks, and the process latch can still prevent admission. `blockedBy` reports one blocker at a time. When the service is stopped it reports that prerequisite, even if a task uses `--standalone`. All fields are snapshots; neither a view nor a free status reserves anything. No finish-time estimate is invented for arbitrary commands.

`tasks` exposes the scheduler state directly, including the last recorded `waitingFor` reason. Both commands prune expired task leases. `status` prints `free` (0) or `held` (75), including shared holders. `sensors` actively collects readings and prints JSON; use it for diagnosis outside measurements, not a polling loop. Cached sensors becoming stale during a measurement or idle period is expected.

Quiet-window admission uses the lower quartile of up to 32 eligible idle readings from the last five minutes (the median during startup), then adapts slowly after five samples. Running Latch work never contributes; queued or parked work prevents upward drift after calibration. Calibration rejects heavy activity, missing sensors, memory pressure, and non-nominal thermal state. Baseline plus noise allowances is capped at 12% CPU average, 60% busiest core, 8% GPU, 0.2 W ANE, and 2 MiB/s disk I/O. Waiting never relaxes these ceilings. `latch_view` exposes `idleBaseline`, `quietLimits`, observed sensors, resource-specific blockers, and `drainingForTaskID`. Measurement results retain an `admission` snapshot containing sensors, baseline, and effective limits; iteration results retain their own snapshot. CPU/GPU temperature guards, continuous quiet intervals, isolation, and FIFO still apply.

## Cooperative benchmark checkpoints

Submit one checkpoint-capable executable with `checkpoints: true` through `latch_submit` or `latch_execute`. This implies measurement isolation. Latch admits process setup first, then cools and schedules every iteration independently. Ordinary executables must omit this flag; a loop inside an ordinary command has only one admission boundary.

The `LatchCheckpoint` library product has no external dependencies. Add that product to the benchmark's target and use one session from one thread:

```swift
import LatchCheckpoint

let session = try LatchSession.connect()
// Load models or prepare shared state during the admitted setup phase.
for iteration in 0..<10 {
    try session.awaitPermit(iteration: iteration)
    // Run and measure the benchmark; finish all asynchronous CPU/GPU work.
    try session.finishIteration(iteration: iteration)
}
```

Before `awaitPermit` and `finishIteration`, all workload threads and devices must be quiescent. After finishing, only lightweight bookkeeping and the next checkpoint are allowed until another permit arrives. The process, memory, model weights, and caches remain alive. Available-memory sensors account for retained allocations; cached resident memory is also exposed in `latch_view`. Latch cannot enforce cooperation inside an arbitrary executable.

The agent submits once and waits on the same job ID. It never sends checkpoints, chooses thermal thresholds, or inserts sleeps. Every ready iteration joins the FIFO tail; other queued jobs can run while this process is parked. The supervisor releases the execution lock during these gaps so fresh sensor samples can establish a new cool/quiet interval. A resumed iteration reacquires isolation before receiving its permit. There is no runtime or iteration-count limit, and admitted iterations are never automatically paused.

Results expose `completedIterations` and the latest 64 `iterations`, each with `iteration`, `waitingSeconds`, `executionSeconds`, `admissionSensors`, and `admission`; `iterationsTruncated` identifies omitted older entries. These durations describe scheduling and the permit-to-finish envelope, not the benchmark's internal performance metric. Keep detailed benchmark results in repository artifacts. Normal command results also separate admission waiting from execution time when available. Before admission, `plan` is provisional; `planCommitted` identifies the allocation selected for execution. Progress reports actual checkpoint stages and iteration numbers.

Agent disconnects leave work running. Service outages block new permits; cancellation still works while parked or running. Use `latch_cancel` on the job ID. A broken checkpoint channel fails the Swift session permanently: exit on its error and never replay an uncertain iteration. Recovery after supervisor loss preserves recorded iteration summaries and reports `terminationReason: "unknown"` once worker leases close. Parked work still counts toward the global outstanding-job limit and update drains.

The wire protocol is newline-delimited JSON on the inherited Unix socket named by `LATCH_CHECKPOINT_FD`, separate from stdin/stdout/stderr. Frames are bounded to 1024 bytes, use `version: 1`, and carry zero-based, sequential `iteration` integers. Send `{"version":1,"kind":"ready","iteration":0}` and block for `kind: "permit"` with the same version/iteration. After quiescing the workload, send `kind: "finished"` and wait for its matching `finished` acknowledgment before advancing. Duplicate requests for the current boundary never advance it twice; invalid ordering/version closes the session through cancellation. Keep one outstanding exchange, do not inherit this socket into unrelated subprocesses, and treat EOF as failure unless all requested iterations have finished.

## Coordination, lifetime, and failures

Path precedence is `--file`, then `LATCH_FILE`, then `~/.local/state/latch/default.lock`. Explicit paths need an existing parent directory. Service and clients must use the same path on a local filesystem. `service install --file PATH` persists that path in the LaunchAgent; clients must still select it themselves. Paths identify separate coordination domains and do not isolate machine resources from each other.

State lives in `PATH.queue`, owned by the current user with mode 0700. Commands, arguments, retained input/output, control receipts, and the submitting environment for unfinished durable jobs are stored privately here. Environment snapshots are removed on completion; results and input receipts remain until forgotten. Avoid putting secrets in arguments or output. Do not delete or replace live latch, lease, or state files.

`run` remains a sensor-free primitive:

```sh
latch run -- ./exclusive-work
latch run --shared -- ./ordinary-work
latch wait --timeout 60
```

`wait` only waits for exclusive holders to leave; it can return while shared work runs. Legacy `run`/`wait` do not participate in FIFO scheduling or resource budgets. They share the process lock with scheduled tasks. Prefer `schedule` for heavy work.

`run` and `schedule` replace themselves with the command, preserving its PID, arguments, standard streams, signals, and exit status. Inherited lock descriptors keep reservations alive until the last copy closes, including descendants. Programs that close inherited descriptors can release early. Do not nest an exclusive latch on the same path; it can deadlock. Cancel a queued command with the normal process termination mechanism; its lease is then pruned automatically.

Stopping or crashing the service does not stop admitted work or release its locks. Parked CLI clients fail closed with exit 69 when they observe service loss; durable MCP jobs retain their tickets and wait for service recovery. Restart clears old sensor/cooldown history and recovers running reservations from their live leases. Corrupt state causes an error rather than silently dropping reservations. Required sensor failures prevent starts; sandbox restrictions may prevent access even when an ordinary user process can read sensors.

Coordination is cooperative and local to one user. Sensors notice unrelated activity before admission, but Latch cannot prevent another app or an uncooperative agent from starting work later. Admission checks cannot guarantee an uncontaminated measurement throughout its lifetime.

| Exit code | Meaning before command execution |
| --- | --- |
| 0 | Success |
| 64 | Invalid usage or requirements |
| 69 | Service unavailable / service management failure |
| 71 | Allocation failure |
| 74 | Filesystem, state, or other I/O error |
| 75 | Busy / admission timeout |
| 126 | Command cannot execute |
| 127 | Command not found |

After execution starts, `run`/`schedule` return the command's own status, which may overlap these codes. Before execution, failures include a `latch:` diagnostic on stderr. `latch --help` lists the CLI syntax.

MIT license: [LICENSE](LICENSE). Native sensor implementation references macmon; its notice is retained in [LICENSES/macmon.txt](LICENSES/macmon.txt).
