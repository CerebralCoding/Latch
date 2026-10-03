# Changelog

Latch is unreleased. These entries describe development versions recorded in Git, not published releases. Changes made while a version remained unchanged are grouped under that version.

## 0.17.0

- `latch_clear_own` cancels only never-started queued jobs in a submission scope, preserving running jobs and all started checkpoint work.
- `latch_stop_own` cancels all outstanding jobs in a submission scope, including running and parked work.
- Human `--stop` cancels all outstanding work in the selected queue across submission scopes, including running processes and parked checkpoints, without stopping the scheduler service.
- `latch run` participates in the shared FIFO scheduler and thermal admission. Human `--clear` and `--stop` cover its work, with supervised process-group cancellation and signal forwarding.

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
