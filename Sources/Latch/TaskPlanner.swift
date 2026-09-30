import Foundation

struct TaskPlan: Codable, Equatable {
    var arguments: [String]
    var requirements: TaskRequirements
    var admissionTimeout: Double? = nil
    var reason: String
    var buildPaths: [String]? = nil
}

enum TaskPlanner {
    static func plan(
        executable: String, arguments: [String], measurement: Bool,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cpuCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryMiB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    ) -> TaskPlan {
        let cores = max(1, cpuCount)
        let memory = max(1, memoryMiB / 4)
        let guardrail =
            measurement
            ? TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 10)
            : TemperatureGuard(maxCPU: 85, maxGPU: 80, cooldown: 0)
        let swiftPackage = URL(fileURLWithPath: executable).lastPathComponent == "swift" && arguments.first == "build"
        if !measurement, swiftPackage, environment["SWIFTPM_BUILD_DIR"] == nil,
            let paths = buildPaths(arguments: arguments, workingDirectory: workingDirectory)
        {
            let workers = max(1, min(4, cores / 2))
            let managedArguments = arguments + workerArguments(workers)
            return TaskPlan(
                arguments: managedArguments,
                requirements: TaskRequirements(
                    mode: .batch, cpuCores: workers, memoryMiB: min(memory, workers * 1024), temperatureGuard: guardrail
                ),
                reason: "Swift package workload with Latch-managed workers", buildPaths: paths)
        }
        // Unknown commands have no trustworthy concurrency contract; never guess that they can share the machine.
        return TaskPlan(
            arguments: arguments,
            requirements: TaskRequirements(
                mode: .isolated, cpuCores: cores, memoryMiB: memory, measurement: measurement,
                temperatureGuard: guardrail),
            reason: measurement ? "performance measurement" : "exclusive admission for an unmanaged workload")
    }

    static let maximumConcurrentBuilds = 2

    private static func workerArguments(_ workers: Int) -> [String] {
        // Whole-module compilation otherwise adds a thread pool using every available core.
        ["-Xswiftc", "-num-threads", "-Xswiftc", "1", "--jobs", String(workers)]
    }

    static func conflicts(_ first: TaskPlan, _ second: TaskPlan) -> Bool {
        (first.buildPaths ?? []).contains { a in
            (second.buildPaths ?? []).contains { b in
                a == "/" || b == "/" || a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
            }
        }
    }

    static func allocate(_ task: ScheduledTask, in state: SchedulerState) -> ScheduledTask {
        guard task.state == .queued, var plan = task.plan, plan.buildPaths != nil, let sensors = state.sensors else {
            return task
        }
        let running = state.tasks.filter { $0.state == .running }
        var candidates: [TaskPlan] = running.compactMap(\.plan)
        for queued in state.tasks where queued.state == .queued {
            guard let queuedPlan = queued.plan, queuedPlan.buildPaths != nil,
                !candidates.contains(where: { conflicts($0, queuedPlan) }),
                candidates.count < maximumConcurrentBuilds
            else { break }
            candidates.append(queuedPlan)
        }
        let cpuBudget = max(1, sensors.cpuCores - 1)
        let reservedCPU = running.reduce(0) { $0 + $1.requirements.cpuCores }
        let reservedMemory = running.reduce(0) { $0 + $1.requirements.memoryMiB }
        let memory = max(0, sensors.memoryAvailableMiB - sensors.memoryTotalMiB / 10 - reservedMemory)
        let workers = max(1, min(4, cpuBudget / max(1, candidates.count), cpuBudget - reservedCPU, memory / 1024))
        let managedArguments = workerArguments(workers)
        plan.arguments = Array(plan.arguments.dropLast(managedArguments.count)) + managedArguments
        plan.requirements.cpuCores = workers
        plan.requirements.memoryMiB = min(sensors.memoryTotalMiB / 4, workers * 1024)
        var prepared = task
        prepared.plan = plan
        prepared.requirements = plan.requirements
        prepared.arguments = [task.arguments[0]] + plan.arguments
        return prepared
    }

    private static func buildPaths(arguments: [String], workingDirectory: String) -> [String]? {
        let values: Set<String> = [
            "--package-path", "--scratch-path", "--cache-path", "--config-path", "--security-path",
            "-c", "--configuration", "--target", "--product", "--triple", "--sdk", "--swift-sdk", "--sanitize",
            "--traits",
        ]
        let flags: Set<String> = [
            "-v", "--verbose", "-q", "--quiet", "--skip-update", "--disable-automatic-resolution",
            "--force-resolved-versions", "--only-use-versions-from-resolved-file", "--disable-sandbox",
            "--disable-index-store", "--enable-index-store", "--auto-index-store", "--build-tests",
            "--enable-all-traits", "--disable-default-traits", "--enable-code-coverage", "--disable-code-coverage",
        ]
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let pieces = arguments[index].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(
                String.init)
            guard let key = pieces.first else { return nil }
            index += 1
            if flags.contains(key), pieces.count == 1 { continue }
            guard values.contains(key), options[key] == nil else { return nil }
            let value: String
            if pieces.count == 2 {
                value = pieces[1]
            } else {
                guard index < arguments.count else { return nil }
                value = arguments[index]
                index += 1
            }
            guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
            options[key] = value
        }
        func canonical(_ path: String, relativeTo base: String) -> String {
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        var package = canonical(options["--package-path"] ?? workingDirectory, relativeTo: workingDirectory)
        if options["--package-path"] == nil {
            while !FileManager.default.fileExists(atPath: package + "/Package.swift"), package != "/" {
                package = URL(fileURLWithPath: package).deletingLastPathComponent().path
            }
        }
        guard FileManager.default.fileExists(atPath: package + "/Package.swift") else { return nil }
        var paths = [
            package,
            options["--scratch-path"].map { canonical($0, relativeTo: workingDirectory) }
                ?? canonical(".build", relativeTo: package),
        ]
        for key in ["--cache-path", "--config-path", "--security-path"] {
            if let path = options[key] { paths.append(canonical(path, relativeTo: workingDirectory)) }
        }
        return Array(Set(paths)).sorted()
    }
}
