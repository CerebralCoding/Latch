# Install Latch for an agent

Follow these instructions when the user asks you to install and configure Latch, a headless scheduler for finite agent workloads. Apple Silicon and macOS 26+ are required. No Xcode, Swift toolchain or administrator access is needed.

## Install or reuse

1. Check the machine with `/usr/bin/uname -m` and `/usr/bin/sw_vers -productVersion`. Stop on unsupported hardware or macOS versions. Run as the normal login user; never use sudo or another administrator mechanism.

2. Check for `~/.local/bin/latch`. If already installed, use its absolute path to run `--version` and `service status`. Reuse a healthy installation; do not replace it, restart it or modify its queue unless the user explicitly requests that maintenance. Report conflicts or an unavailable service.

3. For a new installation, download the version-pinned installer from the official release. Run these commands separately in the current working directory:

   ```sh
   /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' https://github.com/CerebralCoding/Latch/releases/download/v0.18.0/install.sh --output latch-install.sh
   /bin/sh latch-install.sh
   ```

   Do not overwrite an existing `latch-install.sh`. Run the downloaded file only if the download succeeded. The installer verifies the binary's checksum, Developer ID signature and version, then installs `~/.local/bin/latch` and starts its per-user login service.

   If release assets are unavailable or verification fails, report the failure and stop; do not substitute a source build, unsigned binary or another download source. Never run installation or updates inside Latch's queue.

### Installation verification

Verify `--version` and `service status` using the installed executable's absolute path.

For human shell access, add `~/.local/bin` to `PATH` only if needed, preserving the user's existing shell configuration. MCP uses an absolute path and does not require a PATH change.

## Connect MCP

Add a local stdio server named `latch` using the agent host's supported configuration mechanism. Preserve other servers and settings. Resolve the actual home directory and replace `<username>` with the login account; do not put `~`, `$HOME` or the placeholder into the host configuration:

```json
{
  "command": "/Users/<username>/.local/bin/latch",
  "args": ["mcp"]
}
```

This is the server entry; its surrounding configuration is host-specific.

### Connection verification

Do not start a scheduler or background MCP process yourself. Have the host connect or reconnect, then verify initialization and tool discovery. If the host cannot reconnect automatically, ask the user to reconnect before using Latch. A successful installation alone does not establish an MCP connection.

## Use Latch

Follow MCP initialization instructions and the [usage reference](https://github.com/CerebralCoding/Latch/blob/main/README.md#connect-an-agent). Persist the following rules in the host's existing agent instructions when supported, preserving unrelated guidance:

### Workloads and submission

- Route finite builds, tests, benchmarks, profiling and inference through Latch MCP. Never queue dev servers, watch modes, REPLs, daemons or persistent model servers. Long finite jobs are supported.
- Submit the actual foreground executable, literal arguments and an absolute working directory. Mark independent work `ordinary` only when overlap is acceptable; otherwise use `sensitive`. Set `measurement: true` for performance measurements. Latch owns budgets, admission, thermal guards and cooling; agents do not plan them.

### Retry keys and waiting

- Choose a retry key once using the Latch-issued prefix and a distinct operation suffix. Preserve that full key and identical arguments for uncertain retries, including after reconnecting. Do not generate UUIDs or resubmit work because a wait is pending.
- With short host timeouts, use `latch_submit`, then `latch_wait` on the same `jobID` until complete.

### Cancellation and scopes

- Disconnecting stops waiting, not the job. Cancel abandoned work with `latch_cancel`, then retrieve its final status. Only control or forget work within the user's authorized task.
- When scope tools are advertised, create your own scope with `latch_create_scope`, retain its private `scopeToken`, and attach it to each submission and retry. `latch_clear_own` cancels only never-started queued jobs; `latch_stop_own` also cancels running and parked work. Await every returned job ID with `latch_wait`. Never share tokens or use another agent's scope.

### Checkpoints and recovery

- Set `checkpoints: true` only for an executable implementing Latch's checkpoint protocol. The executable owns iteration permits; agents must not send checkpoints or insert cooling sleeps.
- After updates, reconnect MCP and recover jobs by their original IDs. Report actionable connection failures; do not bypass scheduling with the CLI, another queue or direct heavy execution. Installation authorization does not authorize future automatic updates or restarts.

## Completion report

Finish with a brief report of the installed version, service status and MCP connection status, including any required user action.
