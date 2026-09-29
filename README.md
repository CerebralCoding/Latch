# Latch

A small, headless Swift scheduler for cooperating agents on one Mac. Queue resource-sensitive commands, wait for a cool and quiet machine, and release reservations automatically when the work exits. No external dependencies or administrator access.

Requires **macOS 26+** and **Swift 6.4+** to build. Native GPU/ANE and temperature sensors use private Apple interfaces, with Apple Silicon support based on [macmon](https://github.com/vladkens/macmon). Unsupported or inaccessible required sensors block admission.

## Build and service setup

```sh
swift build -c release
swift test -c release
swift run -c release latch service install
```

Installation copies the executable to `~/Library/Application Support/Latch/bin/latch`, links it as `~/.local/bin/latch`, installs `~/Library/LaunchAgents/dev.latch.scheduler.plist`, and starts a login LaunchAgent for the current user. It starts again at login and launchd restarts it after an unexpected exit. `service install` is for initial setup and refuses to replace an existing installation or unrelated command link.

To update, an operator runs the newly built executable with `update --timeout 600`. It rejects new submissions while accepted work drains, atomically replaces the installed binary, and retains `latch.previous` with a SHA-256 installation receipt. A loaded service restarts only if its recorded service revision differs (or is unknown), or `--restart-service` is given; a stopped service stays stopped. Service changes must increment `BuildIdentity.serviceRevision`; MCP-only changes keep that revision. `latch rollback` uses the same drain to restore the previous binary. A failed service start restores the original binary and attempts to restart the original service. Both commands use the latch path in the installed LaunchAgent, ignoring `LATCH_FILE`; `--file` is not accepted. Never run an update inside a scheduled workload, which would wait for itself.

After updating, retrieve retained results and reconnect each MCP host to negotiate the new capabilities. Existing endpoints keep serving their results and identical submission retries, but reject new work once their generation changes. Updating never disconnects hosts automatically. **For the first upgrade from a version without update guards, quiesce older clients first**; they cannot honor the drain. Drain timeout leaves the installed version unchanged and releases the submission block. Process termination also releases the drain locks; recovery from an interrupted replacement may require operator intervention.

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

Configure a local stdio MCP server with the absolute path to an MCP-capable `latch` executable and `args: ["mcp"]`. For example, the launch configuration fields are:

```json
{
  "command": "/absolute/path/to/latch",
  "args": ["mcp"]
}
```

Starting this endpoint uses the existing user service; it never installs, starts, stops, or replaces that service. A locally built executable can connect to the existing service without upgrading it. `swift build -c release --show-bin-path` identifies the build directory containing `latch`. The endpoint uses `LATCH_FILE` or the default shared latch; an operator can select `mcp --file PATH` at launch, but individual tool calls cannot select separate queues.

| Tool | Purpose |
| --- | --- |
| `latch_execute` | Submit the same arguments as `latch_submit` and wait for the final result in one call. Supports optional MCP task execution on capable hosts. |
| `latch_submit` | Submit `requestKey`, `name`, absolute `executable`, literal `arguments`, and absolute `workingDirectory`; optionally set `measurement: true` for benchmarks/profiling. Returns a job ID immediately. |
| `latch_wait` | Wait on `jobID`, returning status and bounded stdout/stderr. Defaults to 25 seconds per call; `timeoutSeconds` can be 0–600 to suit the MCP host's call timeout. |
| `latch_cancel` | Cancel an owned job and its process group, escalating TERM to KILL after two seconds. |
| `latch_view` | Optional diagnostics: cached scheduler state and jobs owned by this connection. No sensor sampling or planning prerequisite. |
| `latch_forget` | Discard a completed job's retained output and retry key. |

Example `latch_execute` (or `latch_submit`) arguments:

```json
{
  "requestKey": "build-release-1",
  "name": "Release build",
  "executable": "/usr/bin/swift",
  "arguments": ["build", "-c", "release"],
  "workingDirectory": "/absolute/path/to/project"
}
```

Prefer `latch_execute` when the host supports long requests or MCP tasks. For hosts with short call timeouts, use `latch_submit`, then `latch_wait` with the returned `jobID`. If `complete` is false, wait on the same ID again rather than resubmitting or polling sensor/view tools. Reuse `requestKey` only to retry the identical submission on the same connection. A changed submission with that key is rejected. Once forgotten, a key can submit new work again. Each connection retains at most 64 jobs and 128 pending waits; forget completed jobs when their results are no longer needed.

Hosts can request `notifications/progress` with `_meta.progressToken` on `tools/call`. Latch reports observed state changes (queued, running, cancelling, completed), using increasing counters without an invented percentage or heartbeat. A pending request sleeps on OS events and leaves other requests responsive. Hosts still control request timeouts and how notifications reach the agent.

For protocol `2025-11-25`, `latch_execute` advertises `execution.taskSupport: "optional"`. Adding `task: {}` to its `tools/call` parameters returns a task handle immediately. The host can call `tasks/result` once to await the final tool result, while receiving `notifications/tasks/status` and any requested progress notifications. `tasks/get`, `tasks/list`, and `tasks/cancel` are also supported. Status notifications are optional in MCP; hosts must retain result retrieval/recovery logic. Host-side waiting or polling need not consume model turns. Task IDs equal job IDs and are distinct from scheduler reservation IDs. Retention overrides requested TTL to `null`: results remain until `latch_forget` or connection closure, subject to the same 64-job limit. Tasks are connection-local and cannot be recovered after reconnecting.

Latch's current automatic policy batches recognized `swift build` commands without explicit worker flags, adds its own `--jobs` limit (at most four and at most half the machine's cores, with a minimum of one), and reserves up to 1 GiB per worker capped at one quarter of physical memory. Tests, arbitrary commands, and commands with explicit worker settings run in isolation because Latch has no trustworthy concurrency contract for them. These use all-core reservations and one quarter of physical memory. Reservations remain advisory estimates, not OS-enforced limits. Ordinary guards require <=55 C for five seconds; measurements require <=50 C for ten seconds plus the quiet window. Admission times out after ten minutes. The selected `plan` is exposed in job results for diagnosis; agents do not supply it.

The endpoint calls the scheduler directly in Swift. It does not invoke a shell or translate tool calls into human CLI commands. Workers inherit the endpoint's environment, use `/dev/null` for stdin, and execute the argument array literally. Keep the full foreground workload in the task; do not nest Latch scheduling or detach work into another process group. Output is untrusted command data. Each stream retains its first 32 KiB, with explicit truncation flags; inherited output pipes are drained for at most two seconds after the main command exits. Use task-owned files for larger artifacts.

Results contain `complete`, `state`, and, after completion, `succeeded`, `exitCode`, `terminationReason`, and `phase` (`admission`, `execution`, or `command`). This distinguishes a command returning 75 from an admission failure. Tool failures set `isError`; malformed protocol calls use JSON-RPC errors. Both text content and `structuredContent` contain the result. Cancellation of a pending MCP wait only cancels that wait; `latch_cancel` cancels the job. Jobs can only be waited on or cancelled by their submitting connection. A normal disconnect/TERM cancels its active jobs. On an abrupt server kill, queued workers notice owner loss; already executing commands retain their process-scoped reservations until exit. Job IDs/results are connection-local, not recoverable across reconnects.

Cancelling a non-task `latch_execute` request cancels its workload. Cancelling `latch_wait` or `tasks/result` only stops waiting. Use `tasks/cancel` to cancel task execution; it responds after process-group cleanup with terminal `cancelled` status and rejects already terminal tasks. Requested progress tokens remain active through task completion, even after the initial handle is returned.

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

Admission is FIFO. An isolated task at the front prevents later batch jobs from overtaking it. Compatible batch jobs can overlap. Reservations are advisory budgets, not OS resource limits.

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

Isolated admission additionally requires two seconds of observed quiet: CPU average <=5%, busiest core <=25%, GPU <=2%, ANE <=0.1 W, and disk activity <=1 MiB/s. Ordinary batch admission permits CPU load up to 80% and checks the larger of observed CPU use and reserved cores against the requested cores. Memory accounting conservatively subtracts reservations from currently available memory.

For batch work, `--gpu` excludes other GPU reservations and requires an idle GPU; `--io` does the same for disk activity. `--bandwidth` excludes other bandwidth reservations, but does not measure memory bandwidth utilization. Isolated work excludes every reservation regardless of these flags.

The service collects a 200 ms activity sample at most once per second while admission needs readings. CPU/GPU temperatures are the hottest valid sensor in each supported family. No automatic sampling occurs behind an exclusive latch, during an isolated task, or while an isolated queue head waits for running tasks to drain. The idle service sleeps on filesystem notifications with an hourly housekeeping wakeup; active queue bookkeeping also watches process exits and uses a one-second fallback.

Cooldowns reset after running tasks finish, a hot/missing reading, a sampling gap longer than two seconds, or service restart. Each queued task must accumulate its own cool interval. A cooldown is sampled evidence, not a prediction of future temperature or an exact task start time.

## Planning and inspection

```sh
latch view
latch tasks
latch status
latch sensors
```

`view` returns a diagnostic JSON object, schema `version: 1`, without collecting fresh sensor readings. The MCP `latch_view` tool includes it under `scheduler` alongside connection-owned `jobs`:

| Field | Meaning |
| --- | --- |
| `service.running`, `service.pid` | Whether the service lease is held and by which service PID |
| `processLatch` | `free`, `shared`, or `exclusive`; includes legacy `run` holders |
| `isolatedTaskRunning`, `nextTaskID` | Isolation and the next FIFO candidate |
| `sensorsFresh`, `sensorAgeSeconds`, `sensorError` | Whether cached readings are usable now and why they may not be |
| `sensors` | Last readings, including `cpuTemperature`/`gpuTemperature` in C, activity fractions 0–1, ANE watts, memory MiB, disk bytes/sec, and `unavailable` sensor details |
| `capacity` | Total/reserved CPU, reserved memory, GPU/I/O/bandwidth reservations; load-adjusted `batchCPUHeadroom` and `memoryHeadroomMiB` only with fresh sensors |
| `tasks[].task` | ID, name, PID, command arguments, requirements, state, timestamps, and last recorded wait reason |
| `tasks[].queuePosition` | One-based FIFO position for queued tasks |
| `tasks[].blockedBy` | Recomputed current admission blocker; absent when no blocker is observed |
| `tasks[].cooldownRemainingSeconds` | Remaining sampled cool interval, reset to the full interval when readings cannot establish progress |

Optional JSON fields are omitted when unknown or inapplicable. Dates are ISO 8601; monotonic values such as `uptime`, `quietSince`, and `coolSince` are seconds since boot. Headroom describes capacity only: isolation, FIFO, temperature, pressure, other resource checks, and the process latch can still prevent admission. `blockedBy` reports one blocker at a time. When the service is stopped it reports that prerequisite, even if a task uses `--standalone`. All fields are snapshots; neither a view nor a free status reserves anything. No finish-time estimate is invented for arbitrary commands.

`tasks` exposes the scheduler state directly, including the last recorded `waitingFor` reason. Both commands prune expired task leases. `status` prints `free` (0) or `held` (75), including shared holders. `sensors` actively collects readings and prints JSON; use it for diagnosis outside measurements, not a polling loop. Cached sensors becoming stale during a measurement or idle period is expected.

## Coordination, lifetime, and failures

Path precedence is `--file`, then `LATCH_FILE`, then `~/.local/state/latch/default.lock`. Explicit paths need an existing parent directory. Service and clients must use the same path on a local filesystem. `service install --file PATH` persists that path in the LaunchAgent; clients must still select it themselves. Paths identify separate coordination domains and do not isolate machine resources from each other.

State lives in `PATH.queue`, owned by the current user with mode 0700. Commands and arguments appear in this private state, so avoid putting secrets in arguments. Do not delete or replace live latch, lease, or state files.

`run` remains a sensor-free primitive:

```sh
latch run -- ./exclusive-work
latch run --shared -- ./ordinary-work
latch wait --timeout 60
```

`wait` only waits for exclusive holders to leave; it can return while shared work runs. Legacy `run`/`wait` do not participate in FIFO scheduling or resource budgets. They share the process lock with scheduled tasks. Prefer `schedule` for heavy work.

`run` and `schedule` replace themselves with the command, preserving its PID, arguments, standard streams, signals, and exit status. Inherited lock descriptors keep reservations alive until the last copy closes, including descendants. Programs that close inherited descriptors can release early. Do not nest an exclusive latch on the same path; it can deadlock. Cancel a queued command with the normal process termination mechanism; its lease is then pruned automatically.

Stopping or crashing the service does not stop admitted work or release its locks. Parked clients fail closed with exit 69 when they observe service loss; retry after the service is available. Restart clears old sensor/cooldown history and recovers running reservations from their live leases. Corrupt state causes an error rather than silently dropping reservations. Required sensor failures prevent starts; sandbox restrictions may prevent access even when an ordinary user process can read sensors.

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
