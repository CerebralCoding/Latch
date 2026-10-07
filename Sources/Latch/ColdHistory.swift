import Foundation

/// Short-lived thermal evidence; never substitutes for fresh quiet-window observations.
struct ColdHistory {
    private var readings: [SensorSnapshot] = []
    private var lastCompletion: Date?

    mutating func observe(_ sample: SensorSnapshot, state: inout SchedulerState) {
        let completed = state.jobs.lazy.filter(\.complete).map(\.updatedAt).max()
        if completed != lastCompletion { readings.removeAll(keepingCapacity: true) }
        lastCompletion = completed
        guard
            !state.tasks.contains(where: { $0.state == .running || $0.startedAt != nil || $0.residentMemoryMiB != nil }
            ),
            sample.thermalState == "nominal", sample.memoryPressure == "normal",
            (0...0.8).contains(sample.cpuActive), let gpu = sample.gpuActive, (0...0.5).contains(gpu),
            sample.aneQuietBlocker(
                limits: QuietLimits(baseline: state.idleBaseline, aneActivity: sample.aneActivity)) == nil
        else {
            readings.removeAll(keepingCapacity: true)
            return
        }
        if let previous = readings.last {
            let maximumGap = SchedulingPolicy.maximumSampleAge
            let elapsed = sample.uptime - previous.uptime
            let wallElapsed = sample.sampledAt.timeIntervalSince(previous.sampledAt)
            if elapsed <= 0 || elapsed > maximumGap || wallElapsed < 0 || wallElapsed > maximumGap {
                readings.removeAll(keepingCapacity: true)
            }
        }
        readings.removeAll { sample.uptime - $0.uptime > 60 }
        for index in state.tasks.indices {
            let task = state.tasks[index]
            guard task.state == .queued, task.requirements.measurement,
                let guardrail = task.requirements.temperatureGuard, guardrail.cooldown > 0
            else { continue }
            var cold = guardrail
            cold.maxCPU -= 10
            cold.maxGPU -= 10
            guard cold.satisfied(by: sample) else { continue }
            let history = readings.reversed().prefix { cold.satisfied(by: $0) }
            guard let since = history.last?.uptime, since < task.queuedUptime,
                sample.uptime - since >= guardrail.cooldown
            else { continue }
            state.tasks[index].coolSince = min(task.coolSince ?? sample.uptime, since)
        }
        // A new job can consume idle history once; interrupted sampling must earn cooldown again.
        if state.tasks.isEmpty {
            readings.append(sample)
            if readings.count > 64 { readings.removeFirst(readings.count - 64) }
        } else {
            readings.removeAll(keepingCapacity: true)
        }
    }
}
