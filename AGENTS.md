Latch is unreleased. Implement only the current contract; do not add legacy migrations, compatibility paths, or tests for obsolete Latch versions.

# Version and Contract Freeze

The release version is frozen at **0.16.0**. The service revision, scheduler-state schema, diagnostic schema, and checkpoint wire schema start at **1**. MCP supports **2025-11-25** only.

Do not bump the release version or any revision/schema counter, change a persisted or wire contract, or add protocol compatibility without the user's explicit approval for that specific change. Routine implementation requests, verification, commits, and pushes do not authorize those changes. Do not update the installed binary or running service without an explicit installation/update request.

# Silent Waiting

**Wait silently unless the user explicitly asks for status.** Continue waits on the original job/control ID without narrating queued/running states, FIFO contention, cooldowns, pending responses, or update drains. Do not echo wait results or progress notifications, send heartbeats, or use diagnostics to fill the silence. Initial acknowledgement and final results are appropriate; report genuine failures and required user actions, such as MCP reconnection, promptly.

# Formatting

Latch is an explicit exception to the global `zsh -ic 'format'` workflow. Use the official formatter bundled with the selected Swift 6.4 toolchain, scoped to this repository:

```
swift format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests
swift format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
```

Do not run the global formatter or add a formatter package dependency. Use the same Swift 6.4 toolchain for formatting and verification.
