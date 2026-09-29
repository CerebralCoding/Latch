import Foundation

struct TaskPlan: Codable, Equatable {
    var arguments: [String]
    var requirements: TaskRequirements
    var admissionTimeout = 600.0
    var reason: String
}

enum TaskPlanner {
    static func plan(executable: String, arguments: [String], measurement: Bool,
                     cpuCount: Int = ProcessInfo.processInfo.activeProcessorCount,
                     memoryMiB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)) -> TaskPlan
    {
        let cores = max(1, cpuCount)
        let memory = max(1, memoryMiB / 4)
        let guardrail = measurement ? TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 10) : TemperatureGuard()
        let explicitWorkers = arguments.contains { $0 == "--jobs" || $0.hasPrefix("--jobs=") || $0.hasPrefix("-j") || $0 == "--num-workers" || $0.hasPrefix("--num-workers=") }
        let swiftPackage = URL(fileURLWithPath: executable).lastPathComponent == "swift" && arguments.first == "build"
        if !measurement, swiftPackage, !explicitWorkers, !arguments.contains("--") {
            let workers = max(1, min(4, cores / 2))
            let managedArguments = arguments + ["--jobs", String(workers)]
            return TaskPlan(arguments: managedArguments,
                            requirements: TaskRequirements(mode: .batch, cpuCores: workers, memoryMiB: min(memory, workers * 1024), temperatureGuard: guardrail),
                            reason: "Swift package workload with Latch-managed workers")
        }
        // Unknown commands have no trustworthy concurrency contract; never guess that they can share the machine.
        return TaskPlan(arguments: arguments,
                        requirements: TaskRequirements(mode: .isolated, cpuCores: cores, memoryMiB: memory, temperatureGuard: guardrail),
                        reason: measurement ? "performance measurement" : "exclusive admission for an unmanaged workload")
    }
}
