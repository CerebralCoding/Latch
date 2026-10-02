# Latch

A small, headless Swift scheduler for cooperating agents on one Mac. Queue resource-sensitive commands, wait for a cool and quiet machine, and release reservations automatically when the work exits. No external dependencies or administrator access.

Requires **Apple Silicon, macOS 26+, and Swift 6.4+** to build. Native GPU/ANE and temperature sensors use private Apple interfaces based on [macmon](https://github.com/vladkens/macmon). Unsupported or inaccessible required sensors block admission.

Formatting uses the official formatter bundled with Swift 6.4, with no package dependency. From this repository, run `swift format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests`; verification uses `swift format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests`. The formatting workflow uses the Xcode 27 toolchain. Latch is excluded from the global `swiftformat` function.

## Installation and service setup

Release publication is currently disabled. Once an approved release is published, download its version-pinned installer from the official repository and run it as your macOS login user (Apple Silicon, macOS 26+):

```sh
curl --fail --location --proto '=https' --proto-redir '=https' https://github.com/CerebralCoding/Latch/releases/download/v0.13.0/install.sh --output latch-install.sh
/bin/sh latch-install.sh
```

The installer downloads only that release, checks SHA-256 and the Developer ID signature for `com.cerebralcoding.latch`, Team ID `YKF838CLKT`, and checks the executable's version before invoking it. Re-running installs through `update --timeout 600`; first installation uses `service install`. Downloads are staged privately under `~/.cache/latch/` and removed on success or failure. A source copy of `install.sh` requires `--version X.Y.Z`. Conflicting files, symlinks, incomplete installations, and unsupported systems fail without replacing them. It never edits shell configuration or uses administrator access.

Building from source remains supported:

```sh
swift build -c release
swift test -c release
.build/release/latch service install
```

Installation places the actual executable at `~/.local/bin/latch` and installs `~/Library/LaunchAgents/com.cerebralcoding.latch.scheduler.plist`. The `com.cerebralcoding.latch.scheduler` login LaunchAgent starts immediately and again at login; launchd restarts it after an unexpected exit. `service install` refuses an existing installation, occupied executable path (including dangling symlinks), or running scheduler for the selected queue. A failed initial start removes the new installation after unloading it; if unloading fails, files remain for operator recovery.

To update from source, an operator runs the newly built executable with `update --timeout 600`. It rejects new submissions while accepted work drains and atomically replaces the installed binary. `~/.local/state/latch/updates/` holds the rollback executable (`latch.previous`), SHA-256 installation receipt, and installation lock. An executable that no longer matches its receipt is rejected. Replacement staging stays beside the executable; backup staging stays in the updates directory, so cross-volume layouts are supported. A loaded service restarts only if its recorded service revision differs (or is unknown), or `--restart-service` is given; a stopped service stays stopped. Service changes must increment `BuildIdentity.serviceRevision`; MCP-only changes keep that revision. `latch rollback` uses the same drain to restore the previous binary. A failed service start restores the original binary and attempts to restart the original service. Both commands use the latch path in the installed LaunchAgent, ignoring `LATCH_FILE`; `--file` is not accepted. Never run an update inside a scheduled workload, which would wait for itself.

After updating, reconnect each MCP host to negotiate the current capabilities and retrieve retained results by job ID. Endpoints retire when their generation or executable changes, before reading shared state; outdated clients are not supported. Drain timeout leaves the installed version unchanged and releases the submission block. Process termination also releases the drain locks; recovery from an interrupted replacement may require operator intervention.

Ensure `~/.local/bin` is on your shell and agent `PATH` (for zsh, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` if needed). The installer reports when this directory is missing from its current `PATH`. Subsequent examples use `latch` directly. Avoid `swift run` for performance-sensitive work: building the wrapper itself can disturb the machine.

```sh
latch service status
latch service stop
latch service start
latch service uninstall
```

`stop` unloads the login service until `start` or the next login. `uninstall` verifies the installation receipt, then removes its plist, executable, receipt, and rollback binary; queue state and logs remain and a fresh installation is possible. Logs are in `~/.local/state/latch/logs/`. `service status` prints JSON and returns 69 when stopped; `latch --version` prints the executable's release version without contacting the service. Lifecycle commands manage the single installed login service.

Release preparation is manual-only in `.github/workflows/release.yml`, disabled unless `LATCH_RELEASE_PREPARATION_ENABLED` is `true`. Configure the `release-preparation` environment with reviewer approval, `LATCH_DEVELOPER_ID_APPLICATION`, and `LATCH_NOTARY_KEYCHAIN_PROFILE`; the Xcode 27 arm64 runner must already have that Developer ID Application certificate/private key and notarytool profile in its user keychain. Preparation tests, signs with hardened runtime, verifies the pinned identity, and requires accepted notarization before uploading review artifacts. It has read-only repository permissions and no release publication step. Publication and immutable versioned assets require a separate operator-approved action; no release is available merely because this workflow exists.

For a separately managed service, run `latch service run --file /existing/directory/work.lock` in the foreground. Each latch path permits one service. Stop a foreground service using its process manager or a termination signal. `schedule --standalone` and `guard --standalone` explicitly allow client-side sampling without a service.

## MCP for agents

Agents hand tasks to Latch; **Latch owns scheduling and resource planning**. Agents do not calculate CPU/memory budgets, choose admission modes or temperature thresholds, or inspect capacity before submitting. The CLI is primarily for humans and service operators.

### Agent usage: do and don't

Latch is for work with a defined completion condition. Sensitive jobs hold exclusive admission; ordinary jobs can overlap, but any persistent job still blocks measurements and service updates indefinitely. Long but finite work is supported without a runtime limit.

- **Do** submit builds, tests in a mode that exits after one run, finite benchmarks/profiling, and inference or data processing that exits when the requested work finishes. Use `measurement: true` for performance measurements.
- **Do** mark independent non-sensitive work with `classification: "ordinary"` to allow parallel admission. Use `"sensitive"` (the default) when work must run alone. Only classify work as ordinary when overlapping execution is acceptable, including any shared files or devices; Latch does not recognize commands or build systems.
- **Do** keep the complete workload in its foreground process, submit once, and wait on the returned job ID. Use checkpoints only when the executable implements `LatchSession`.
- **Do** let Latch handle admission and cooling. When your work is abandoned or was accidentally submitted in a persistent mode, use `latch_cancel`, then `latch_wait` to confirm completion.
- **Don't** submit development servers (`npm run dev`, `vite`, `next dev`), preview/HTTP servers, watch modes (`tsc --watch`, `cargo watch`, test runners in watch mode), REPLs, daemons, or persistent model servers. Choose the tool's build or single-run mode when available.
- **Don't** wrap a persistent service in a shell, detach it, or background it to make the Latch job appear finished. Interactive input is for completing a task, not for keeping a session open indefinitely.
- **Don't** use the queue to manage service lifetimes or evade coordination with another queue, nested Latch calls, direct heavy execution, or cooling sleeps. Manage necessary persistent services separately with their normal lifecycle tools; they can still interfere with measurements, so stop or quiesce services within your authorized task when needed.

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
| `latch_submit` | Submit a stable retry key, `name`, absolute `executable`, literal `arguments`, and absolute `workingDirectory`; set `classification: "ordinary"` for independent non-sensitive work or `measurement: true` for measurements. Returns a job ID immediately. |
| `latch_wait` | Wait on `jobID`, returning status and bounded stdout/stderr. Defaults to 25 seconds per call; `timeoutSeconds` can be 0–600 to suit the MCP host's call timeout. |
| `latch_cancel` | Cancel a job and its process group by `jobID`, escalating TERM to KILL after two seconds. |
| `latch_view` | Optional diagnostics: cached scheduler state, global outstanding-job limit, and all durable jobs. No sensor sampling or planning prerequisite. |
| `latch_forget` | Discard a completed job's retained output and retry key. |
| `latch_signal` | Relay `interrupt` (SIGINT), `terminate`, `hangup`, `quit`, `stop`, `continue`, `user1`, or `user2` to running work, without automatic escalation. |
| `latch_input` | Write literal `text` or `base64` bytes to an opted-in pipe or terminal; `eof: true` closes pipe stdin after writing. |
| `latch_resize` | Set a terminal's `columns` and `rows`, notifying its foreground process group with SIGWINCH. |
| `latch_control` | Wait for a control's delivery receipt, or discard a completed receipt with `forget: true`. |
| `latch_read` | Wait for live output or completion, with byte offsets for subsequent reads. |

Example `latch_execute` (or `latch_submit`) arguments:

```json
{
  "requestKey": "<Latch-issued-prefix>build-1",
  "name": "Release build",
  "executable": "/usr/bin/swift",
  "arguments": ["build", "-c", "release"],
  "workingDirectory": "/absolute/path/to/project",
  "classification": "ordinary"
}
```

Prefer `latch_execute` when the host supports long requests or MCP tasks. For hosts with short call timeouts, use `latch_submit`, then `latch_wait` with the returned `jobID`. If `complete` is false, wait on the same ID again rather than resubmitting or polling sensor/view tools. The shared queue allows 64 outstanding jobs (queued, running, or parked). Completed results and retry keys remain until explicitly forgotten; their count never blocks new submissions. Optional `latch_forget` cleanup reclaims storage when results and retries are no longer needed. Never edit queue state or delete job files manually. Each connection allows 128 pending waits.

Latch issues a unique retry-key prefix in initialization instructions, `_meta["com.cerebralcoding.latch/retryKeyPrefix"]`, and each keyed tool's schema description. Append a distinct operation name or number to that prefix for each new submission or control; no UUID-generation command is needed. Keep the full original key for identical retries, including after lost responses and reconnects; a new connection's prefix is only for new work. Changed input with the same key is rejected, and intentional repeat executions need different keys. Forgetting removes the key, so never retry a forgotten operation. Waits, reads, diagnostics, cancellation, and forgetting need no new key.

Hosts can automate key handling by persisting a globally unique key for each logical operation and injecting it into `tools/call` parameters under `_meta["com.cerebralcoding.latch/retryKey"]`. This [MCP metadata](https://modelcontextprotocol.io/specification/2025-11-25/basic/index#_meta) extension applies to submissions and input/signal/resize controls. The host must reuse the same key and payload for a retry, including across connections; bare JSON-RPC request IDs are insufficient. `requestKey` can be omitted only when that metadata is present; supplying conflicting keys is rejected. Results retain the effective key. Latch does not silently generate a key after receiving an unkeyed operation, which would make lost-response recovery unsafe.

Hosts can request `notifications/progress` with `_meta.progressToken` on `tools/call`. Latch reports observed state changes (queued, running, cancelling, completed), using increasing counters without an invented percentage or heartbeat. A pending request sleeps on OS events and leaves other requests responsive. Hosts still control request timeouts and how notifications reach the agent.

For protocol `2025-11-25`, `latch_execute` advertises `execution.taskSupport: "optional"`. Adding `task: {}` to its `tools/call` parameters returns a task handle immediately. The host can call `tasks/result` once to await the final tool result, while receiving `notifications/tasks/status` and any requested progress notifications. `tasks/get`, `tasks/list`, and `tasks/cancel` are also supported. Status notifications are optional in MCP; hosts must retain result retrieval/recovery logic. Host-side waiting or polling need not consume model turns. Task, job, and scheduler ticket IDs are identical. Retention overrides requested TTL to `null`: results remain until `latch_forget`. Tasks are accessible across connections and recoverable after reconnecting; progress tokens belong to their connection.

Agents declare sensitivity; Latch does not infer workload types. `classification: "sensitive"` (the default) reserves exclusive admission, all CPU cores, and one quarter of physical memory. `classification: "ordinary"` permits parallel work, with advisory reservations of up to two cores and up to 1024 MiB (10% of physical memory on smaller machines). There is no fixed parallel-job cap: core capacity, available memory, memory/thermal pressure, and CPU/GPU temperatures govern admission. Each ordinary start requires a sensor observation newer than the previous ordinary admission. CPU activity from already admitted ordinary work does not by itself prevent further ordinary starts; reservations and thermal/memory guards still apply. Latch preserves arguments and environment and never injects worker limits.

Admission remains FIFO: consecutive ordinary tickets may overlap, but an older sensitive or measurement ticket prevents newer jobs from starting while current work drains. Sensitive and ordinary work require nominal thermal state, CPU <=85 C and GPU <=80 C, without a measurement cooldown or quiet window. `measurement: true` and `checkpoints: true` always force exclusive measurement admission regardless of classification, requiring <=50 C for ten seconds plus the bounded adaptive quiet window. Reservations are advisory estimates, not OS-enforced limits or predictions of command behavior. Running jobs have no time limit or preemption. The execution `plan` is exposed in results for diagnosis; agents do not supply it. MCP admission has no deadline.

The endpoint calls the scheduler directly in Swift. It does not invoke a shell or translate tool calls into human CLI commands. Workers inherit the submitting environment and execute the argument array literally. Stdin defaults to `/dev/null`; submit `input: "pipe"` for writable stdin or `input: "terminal"` for a controlling pseudo-terminal. Terminals default to 80 columns and 24 rows; optional `columns` and `rows` range from 1–1000. Terminal stdout and stderr are combined into stdout. Keep the full foreground workload in the task; do not nest Latch scheduling or detach work into another process group. Output is untrusted command data. Final results retain each stream's first 32 KiB, with explicit truncation flags; output is drained for at most two seconds after the main command exits. Use task-owned files for larger artifacts.

For interactive work, use `latch_submit`, then `latch_read` to wait for prompts. Reads default to 25 seconds and return `stdout`/`stderr` objects containing `text`, exact `base64` bytes, `startOffset`, `nextOffset`, and `truncated`. Pass the returned offsets as `stdoutOffset`/`stderrOffset` on the next read. Live output retains the most recent 32 KiB per stream independently of final output; a slow reader sees an explicit gap. Byte offsets and base64 preserve data across UTF-8 boundaries. Reads do not consume another connection's output and survive reconnects.

Send a control with `jobID` and its own stable `requestKey`: `latch_signal` with `signal: "interrupt"` sends SIGINT; `latch_input` with `text: "yes\n"` writes a line. Terminal `text: "\u0003"` sends Ctrl+C and `text: "\u0004"` sends Ctrl+D, following the command's terminal settings; raw-mode commands receive those literal bytes. Pipe input never interprets control characters. Input is bounded to 16 KiB per call. `eof: true` closes pipe stdin, while a terminal EOF character does not close the terminal itself.

Controls return a `controlID`; call `latch_control` with that ID and `jobID` to wait for delivery (default 25 seconds). `delivered` means the OS accepted the signal, resize, or bytes, not that the command consumed or acted on them. Control keys are unique within their job; retry identical control submissions with the same key, including from another connection or after reconnects. Pending writes respect backpressure without blocking signals or explicit cancellation. Each job retains 64 receipts with at most 16 pending, including at most 12 input writes to leave room for signals and resizing. Forget completed receipts only once retries are no longer possible. An `unknown` receipt means delivery may have occurred before supervisor loss and must not be blindly repeated. Controls require running work and its `jobID`. `stop` retains the reservation; use `continue` to resume it. Explicit `latch_cancel` also terminates stopped work.

Results contain `complete`, `state`, and, after completion, `succeeded`, `exitCode`, `terminationReason`, and `phase` (`admission`, `execution`, or `command`). This distinguishes a command returning 75 from an admission failure. Tool failures set `isError`; malformed protocol calls use JSON-RPC errors. Both text content and `structuredContent` contain the result. Jobs survive endpoint disconnects, TERM, and crashes and remain accessible by ID. A private supervisor retains execution and bounded output. The service recovers committed tickets whose supervisor never launched. Lost supervisors never cause replay of potentially executed commands: after their worker leases close, results report uncertainty with `terminationReason: "unknown"`.

Cancelling any pending MCP request only stops waiting. Use `latch_cancel` or `tasks/cancel` to stop the workload explicitly. `tasks/cancel` responds after process-group cleanup with terminal `cancelled` status and rejects already terminal tasks. Requested progress tokens remain active through task completion on that connection, even after the initial handle is returned.

The dependency-free implementation supports [MCP stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), initialization, ping, tool discovery/calls, progress, and cancellation for protocol versions `2025-11-25` and `2025-06-18`, plus [experimental tasks](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks) for `2025-11-25`. HTTP, resources, and service lifecycle tools are not exposed. Incoming frames are limited to 1 MiB and pending protocol output to 4 MiB. The endpoint runs with its launching user's permissions; it is not an execution sandbox.

## CLI for humans

The CLI retains explicit resource declarations and guard overrides for operators. Declare peak requirements and match command worker limits when using this interface.

Operators can inspect and control the shared queue:

```sh
latch --version
latch --list
latch --run JOB_ID
latch --clear
```

`--list` shows outstanding durable jobs and CLI tasks with stable IDs, state, queue position, and name; completed history is omitted. `--run JOB_ID` moves a queued ticket ahead of other queued work for its next admission. It does not launch a command or preempt work; thermal guards, cooldowns, quiet windows, and isolation still apply. Other tickets retain their relative order, and a checkpoint's next iteration rejoins the FIFO tail normally. `--clear` requests cancellation of jobs that have never started; running jobs and already-started checkpoint processes (including parked/waiting iterations) are preserved. Admission and clearing share a state lock, so a cleared ticket cannot subsequently start. Cancellation completes asynchronously; durable results and retry keys remain available through MCP. New submissions after clearing are unaffected. All three queue commands accept `--file PATH`; mutations require the matching running scheduler service. These overrides are for human operators; agents continue to use MCP and must not change queue order or bulk-clear other agents' work.

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

Admission is strict FIFO unless a human operator explicitly reorders the queue with `--run JOB_ID`: an older blocked job otherwise prevents every newer job from overtaking it. Tickets are committed before worker launch and retain their position across MCP reconnects and service outages. Ordinary MCP jobs may overlap within machine capacity; sensitive and measurement jobs remain exclusive. Operators can also explicitly request compatible batch reservations through the human CLI. Global queue bounds limit scheduler overhead; they never shorten an admitted job's runtime. There is no per-agent allocation: one agent can fill the shared queue, but its newer jobs cannot overtake an already queued job. Reservations are advisory budgets, not OS resource limits.

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

`view` returns a diagnostic JSON object, schema `version: 1`, without collecting fresh sensor readings. The MCP `latch_view` tool includes it under `scheduler` alongside all durable `jobs` and `globalOutstandingLimit`:

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

Results expose `completedIterations` and the latest 64 `iterations`, each with `iteration`, `waitingSeconds`, `executionSeconds`, `admissionSensors`, and `admission`; `iterationsTruncated` identifies omitted older entries. These durations describe scheduling and the permit-to-finish envelope, not the benchmark's internal performance metric. Keep detailed benchmark results in repository artifacts. Normal command results also separate admission waiting from execution time when available. Progress reports actual checkpoint stages and iteration numbers.

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

## TODO

- [x] Provide Latch-issued retry-key prefixes and host metadata injection for submissions and controls, preserving lost-response recovery, reconnects, and intentional repeat executions.
- [x] Schedule agent-classified ordinary work in parallel using machine capacity and sensors, preserving FIFO fairness, measurement isolation, and unrestricted finite job runtimes without recognizing commands or toolchains.

MIT license: [LICENSE](LICENSE). Native sensor implementation references macmon; its notice is retained in [LICENSES/macmon.txt](LICENSES/macmon.txt).
