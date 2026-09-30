import Foundation

struct TaskPlan: Codable, Equatable {
    var arguments: [String]
    var requirements: TaskRequirements
    var admissionTimeout: Double? = nil
    var reason: String
}

enum TaskPlanner {
    static func plan(
        arguments: [String], measurement: Bool,
        cpuCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryMiB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    ) -> TaskPlan {
        let guardrail =
            measurement
            ? TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 10)
            : TemperatureGuard(maxCPU: 85, maxGPU: 80, cooldown: 0)
        return TaskPlan(
            arguments: arguments,
            requirements: TaskRequirements(
                mode: .isolated, cpuCores: max(1, cpuCount), memoryMiB: max(1, memoryMiB / 4),
                measurement: measurement, temperatureGuard: guardrail),
            reason: measurement ? "performance measurement" : "ordinary exclusive work")
    }
}
