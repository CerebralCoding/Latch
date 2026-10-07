# Changelog

Versions before 0.17.0 describe development milestones. Changes made while a version remained unchanged are grouped under that version.

## 0.20.0

Latch 0.20.0 introduces a native Swift terminal dashboard for monitoring workloads and managing the operator queue.

- Added `latch tui [--file PATH] [--interval SECONDS]`, with wide and compact layouts, incremental rendering, and `NO_COLOR` support. The dashboard reads cached scheduler observations without collecting extra sensor samples.
- Added an overview showing queue and checkpoint counts, pressure warnings, and a navigable jobs list with running work first. Reservations, CPU/GPU/ANE watts, and available memory/disk readings appear in that order above the list; the selected job exposes its admission blocker.
- Fixed shared sensor collection at once per second, whether idle or running jobs, including exclusive measurements and draining, so the TUI and MCP diagnostics show current activity. Running-job observations do not count toward idle calibration or measurement readiness. The TUI does not start a separate sampler.
- Added CPU and GPU power readings before ANE power on the overview, using the existing native sensor subscription. The shared sensor snapshot and detailed diagnostics include all three power readings; unavailable readings remain explicit.
- Added session charts for CPU, GPU, and ANE activity, memory use, and CPU/GPU temperatures. Filled history bars use fixed scales, preserve captured colors, and leave gaps for paused or unavailable readings. Paused or stale readings are explicitly labeled as historical instead of showing a cached idle value as current utilization.
- Added native ANE activity readings from compute histograms and cluster residency, with a labeled power/bandwidth-state estimate when direct counters are unavailable. Sensor diagnostics retain the source of each reading; empty or invalid counters are not reported as zero utilization.
- Integrated ANE activity into measurement admission, idle calibration, and idle cooldown credit. Direct counters catch activity that watts alone can miss; power-floor estimates tighten the allowance above idle and require corroborating power before blocking admission. Fluctuating floor estimates alone do not restart the quiet window. MCP wait explanations, admission snapshots, CLI diagnostics, and the dashboard expose the same evidence and effective limits. Ordinary jobs retain shared admission.
- Integrated job navigation, filtering, sorting, retained history, and confirmed job actions into the overview. Enter or Tab opens a near-full-screen detail overlay with commands, reservations, admission conditions, and retained output; Tab or Esc closes it while preserving selection. Open details stay pinned when a job finishes, retaining the command, requirements, and scroll position while final status and output update. Sensors and help open as separate modals with `i` and `?`.
- Added confirmed operator actions to prioritize or cancel a selected job, clear never-started work, or stop outstanding jobs. Confirmation captures specific job IDs so new arrivals are excluded; admission guards remain in force.
- Persisted the last refresh interval, including changes through `+`/`-` and explicit `--interval` overrides. Refresh defaults to one second and supports 0.5–60 seconds. Preferences use `$XDG_CONFIG_HOME/latch/tui.json`, defaulting to `~/.config/latch/tui.json`.
- Added a Total jobs count covering current work and retained history, with dot-separated thousands from `10.000` onward. History counts and pagination use the same formatting.
- Added display freezing, scrolling dialogs, terminal resize and suspend/resume handling, and restoration of terminal settings on exit. Pasted input cannot trigger queue controls, and displayed job names and output escape terminal control sequences.
- Included MIT notices for the graph and sensor references from mlxtop, macmon, SiliconScope, and mactop.

Reconnect MCP clients after updating. Existing job IDs and retry keys remain valid.

## 0.19.0

Latch 0.19.0 improves admission responsiveness and makes it clearer when agents should share the machine and when they should wait.

- Clarified workload classification across MCP discovery and agent instructions. Independent builds, CPU/GPU correctness checks, numerical parity, and model-quality evaluations should explicitly use ordinary admission. Sensitive work requires a concrete exclusivity need; performance measurements remain exclusive.
- Pending MCP results now confirm acceptance, explain the current blocker, and direct agents to keep waiting on the same job or MCP task instead of resubmitting, reclassifying, or repeatedly announcing unchanged waits.
- Long-wait explanations identify running jobs and earlier FIFO tickets. Measurement blockers include CPU baseline, effective limits, excess activity, and quiet-window progress. Queue age is distinguished from time spent on the current blocker.
- Progress and task-status notifications follow meaningful state or blocker changes rather than every sensor fluctuation or passing second, including after reconnecting.
- Sensor collection now accounts for collection time when scheduling the next admission sample, reducing avoidable gaps between observations.
- Measurements can credit recent, sufficiently cold idle history toward cooldowns. History is short-lived and kept in memory; fresh sensors and the full quiet window remain mandatory, and waiting never relaxes admission limits.

Reconnect MCP clients after updating to load the revised guidance. Existing job IDs and retry keys remain valid.

## 0.18.0

- Standardized human commands as `list`, `prioritize JOB_ID`, `clear`, and `stop`, replacing the previous action flags and duplicate job-listing command.
- Added consistent `--option=value` parsing, duplicate-option checks, missing-value errors, and `--` handling that preserves child command arguments.
- Improved command-specific help and service option validation.
- Refined the README's structure, sponsorship footer, and feedback guidance.

## 0.17.0

- `latch_clear_own` cancels only never-started queued jobs in a submission scope, preserving running jobs and all started checkpoint work.
- `latch_stop_own` cancels all outstanding jobs in a submission scope, including running and parked work.
- Human `--stop` cancels all outstanding work in the selected queue across submission scopes, including running processes and parked checkpoints, without stopping the scheduler service.
- `latch run` participates in the shared FIFO scheduler and thermal admission. Human `--clear` and `--stop` cover its work, with supervised process-group cancellation and signal forwarding.
- CLI process groups remain cancellable after loss of the foreground supervisor, with reservations retained until work exits.
- Completed MCP results load on demand and remain cached; routine updates avoid repeated history reads and duplicate result decoding.

## 0.16.0

- Established the unreleased contract baseline: service, scheduler-state, diagnostic, and checkpoint revisions start at `1`; MCP supports `2025-11-25` only. Removed obsolete compatibility paths and froze changes behind explicit approval.
- Added actionable MCP connection failure reasons and recovery instructions, including reconnection after updates and refusal of new submissions while draining.
- Added agent installation instructions at a shareable repository URL and clarified agent progress reporting.
- Restarted loaded scheduler services when an update changes the binary, even when the service revision is unchanged; identical updates avoid unnecessary restarts.
- Added `--about` with author, copyright, contact, and GitHub sponsorship information.
- Distinguished cached or intentionally paused sensor readings from sensor errors in human diagnostics.
- Reduced scheduler contention during exclusive measurement admission.
- Added private submission scopes, scope tokens omitted from global diagnostics, and scoped bulk cancellation recoverable across MCP connections.
- Added release-mode tests to CI and corrected installation and service test fixtures.

## 0.15.0

- Resolved service identity from binary metadata or the current account, using `<username>.latch.scheduler` for builds without an assigned identifier.
- Added optional local build metadata and rejected replacements with a different service identity.
- Reworked the README around precompiled binary installation and agent usage; added GitHub Sponsors configuration.

## 0.14.0

- Made human diagnostics compact by default, with `--verbose` details and explicit JSON output.
- Added focused CLI help, clearer errors, and readable scheduler, sensor, task, and service status output.
- Added compact MCP job listing and individual job inspection, avoiding full history and command output in routine diagnostics.

## 0.13.0

- Added agent-declared ordinary and sensitive classifications. Consecutive ordinary jobs can overlap, with concurrency determined by machine capacity and sensor guards; sensitive jobs and measurements remain exclusive.
- Preserved submitted commands and environment without command recognition or injected worker limits.
- Added connection-specific retry-key prefixes and host-supplied retry-key metadata for recoverable submissions and controls.
- Restricted builds to Apple Silicon and macOS 26 or newer.

## 0.12.0

- Added human `--version`, `--list`, and `--run JOB_ID` queue prioritization.
- Added `--clear` to cancel never-started queued work while preserving running jobs and started checkpoints.
- Standardized the login service identifier and LaunchAgent filename with the `.scheduler` suffix.

## 0.11.0

- Added a standalone installer and release tooling for signed and notarized binaries, with publication blocked until release signing is configured.
- Adopted user-owned Unix-style binary, state, log, and update locations.
- Added installation receipts, verified update and rollback binaries, and protected existing installations from accidental replacement.

## 0.10.2

- Limited outstanding work instead of retained history: completed results and retry keys no longer block new submissions.
- Clarified finite workload usage and prohibited persistent servers, watch modes, and daemons in the scheduled queue.

## 0.10.1

- Removed automatic build recognition, worker flag injection, and build batching, retaining exclusive admission with the improved adaptive measurement baseline.

## 0.10.0

- Experimented with parallel admission for independent recognized builds, including conflict checks and scheduler-selected resource allocations.
- Added robust adaptive idle calibration, bounded noise allowances, resource-specific admission blockers, and measurement admission snapshots.
- Separated ordinary thermal guards from measurement quiet windows and cooldowns; exposed the exclusive queue head waiting for running work to drain.
- Added periodic idle sensor sampling and per-iteration admission diagnostics.

## 0.9.1

- Calibrated quiet-window admission against observed idle activity, excluding running Latch work and preventing upward baseline drift while work is waiting.
- Retired outdated MCP endpoints after updates before they could continue reading shared state.

## 0.9.0

- Added cooperative benchmark checkpoints and the `LatchCheckpoint` Swift library. Benchmarks retain their process and resident data while yielding execution between iterations and rejoining the FIFO queue.
- Added checkpoint progress, retained iteration summaries, admission and execution timing, and cancellation while parked or running.
- Adopted the official Swift 6.4 formatter and CI formatting checks.

## 0.8.0

- Removed agent ownership and per-agent quotas in favor of one shared durable queue.
- Made jobs, results, retry keys, and controls accessible across connections without an agent identity.

## 0.7.0

- Added durable signal delivery, interactive pipe input, terminal control bytes, resizing, live output reads, and recoverable control receipts.
- Added process-group cancellation and cleanup, including TERM-resistant descendants.

## 0.6.0

- Persisted jobs, results, retry keys, and FIFO tickets across connections and service interruptions.
- Prevented newer work from overtaking an older blocked ticket; added durable submission ownership and quotas, subsequently removed in 0.8.0.

## 0.5.0

- Added long-running MCP execution requests, progress notifications, task handles, task status notifications, result waiting, and task cancellation.
- Added coordinated update draining, atomic binary replacement, rollback, and retirement of outdated MCP transports.

## 0.3.0

- Added a dependency-light handrolled MCP transport with submission, waiting, diagnostics, cancellation, forgetting, and retry-key deduplication.
- Moved task planning and sensor-aware scheduling into Latch so agents submit commands without calculating resource budgets or cooldowns.

## Initial unversioned milestones

- Added process-scoped shared and exclusive latches, command execution, queue waiting, status inspection, and automatic release on process exit.
- Added native Swift sensors, resource reservations, FIFO admission, and isolation for performance-sensitive work on macOS 26 with Swift 6.4.
- Added a temperature-aware login scheduler service, cooldowns between measurements, a planning view, and installation on the user PATH.
- Added the MIT license.
