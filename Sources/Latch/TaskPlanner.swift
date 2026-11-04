import Foundation

struct TaskPlan: Codable, Equatable {
    var arguments: [String]
    var requirements: TaskRequirements
    var admissionTimeout: Double? = nil
    var reason: String
}

enum TaskPlanner {
    static func plan(
        arguments: [String], measurement: Bool, classification: MCPSubmission.Classification = .sensitive,
        cpuCount: Int = MachineCapacity.machine.cpuCores,
        memoryMiB: Int = MachineCapacity.machine.memoryMiB
    ) -> TaskPlan {
        let guardrail =
            measurement
            ? TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 10)
            : TemperatureGuard(maxCPU: 85, maxGPU: 80, cooldown: 0)
        let ordinary = !measurement && classification == .ordinary
        return TaskPlan(
            arguments: arguments,
            requirements: TaskRequirements(
                mode: ordinary ? .batch : .isolated,
                cpuCores: max(1, ordinary ? min(2, cpuCount) : cpuCount),
                memoryMiB: max(1, ordinary ? min(1024, memoryMiB / 10) : memoryMiB / 4),
                measurement: measurement, temperatureGuard: guardrail),
            reason: measurement
                ? "performance measurement" : ordinary ? "agent-declared ordinary work" : "sensitive exclusive work")
    }
}
