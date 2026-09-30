Latch is unreleased. Implement only the current contract; do not add legacy migrations, compatibility paths, or tests for obsolete Latch versions.

# Formatting

Latch is an explicit exception to the global `zsh -ic 'format'` workflow. Use the official formatter bundled with the selected Swift 6.4 toolchain, scoped to this repository:

```
swift format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests
swift format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
```

Do not run the global formatter or add a formatter package dependency. Use the same Swift 6.4 toolchain for formatting and verification.
