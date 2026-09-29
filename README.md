# Latch

A small, headless Swift scheduler for cooperating agents on one Mac. Queue resource-sensitive commands, wait for a cool and quiet machine, and release reservations automatically when the work exits. No external dependencies or administrator access.

Requires **macOS 26+** and **Swift 6.4+** to build. Native GPU/ANE and temperature sensors use private Apple interfaces, with Apple Silicon support based on [macmon](https://github.com/vladkens/macmon). Unsupported or inaccessible required sensors block admission.

## Build and service setup

```sh
swift build -c release
swift test -c release
swift run -c release latch service install
```

Installation copies the executable to `~/Library/Application Support/Latch/bin/latch`, links it as `~/.local/bin/latch`, installs `~/Library/LaunchAgents/dev.latch.scheduler.plist`, and starts a login LaunchAgent for the current user. It starts again at login and launchd restarts it after an unexpected exit. Re-run `service install` from a newly built binary to update it. Installation refuses to replace an unrelated command at the link path.

Ensure `~/.local/bin` is on your shell and agent `PATH` (for zsh, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` if needed). The installer reports when this directory is missing from its current `PATH`. Subsequent examples use `latch` directly. Avoid `swift run` for performance-sensitive work: building the wrapper itself can disturb the machine.

```sh
latch service status
latch service stop
latch service start
latch service uninstall
```

`stop` unloads the login service until `start` or the next login. `uninstall` also removes its plist, installed executable, and command link if it still points to Latch; queue state and logs remain. Logs are in `~/Library/Application Support/Latch/logs/`. `service status` prints JSON and returns 69 when stopped. Lifecycle commands manage the single installed login service.

For a separately managed service, run `latch service run --file /existing/directory/work.lock` in the foreground. Each latch path permits one service. Stop a foreground service using its process manager or a termination signal. `schedule --standalone` and `guard --standalone` explicitly allow client-side sampling without a service.

## Agent workflow

1. Use `latch view` when planning work. It shows current reservations, FIFO queue positions, blocking reasons, temperatures, sensor freshness, and resource headroom.
2. Route heavy work through `latch schedule`. Use `isolated` for measurements and `batch` for ordinary builds or inference. Declare peak resources honestly and configure the command's own parallelism to match.
3. Submit the command once and let the tool call wait. If the agent runtime yields a process/session handle, wait on that existing handle. Do not repeatedly invoke `view`, `sensors`, or `schedule` to poll readiness.
4. Let command completion release the reservation. A timeout before admission returns 75 without executing the command; inspect `view` once if you need to adjust the plan.

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

`view` is the preferred agent planning interface. It returns one JSON object, schema `version: 1`, without collecting fresh sensor readings:

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
