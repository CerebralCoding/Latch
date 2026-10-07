import Foundation

struct QuietLimits: Codable, Equatable {
    static let aneActivity = 0.02

    static func anePowerAllowance(for activity: ANEActivity?) -> Double {
        // A raised floor is demand, not compute occupancy. Require power to corroborate it,
        // but allow less noise above idle than when power is our only evidence.
        activity?.source == .powerFloor && (activity?.fraction ?? 0) > aneActivity ? 0.05 : 0.1
    }

    var cpuActive: Double
    var busiestCore: Double
    var gpuActive: Double
    var aneWatts: Double
    var diskBytesPerSecond: Double

    init(baseline: IdleBaseline?, aneActivity: ANEActivity? = nil) {
        let idle = baseline ?? IdleBaseline()
        cpuActive = min(0.12, idle.cpuActive + max(0.05, idle.cpuActive * 0.5))
        busiestCore = min(0.60, idle.busiestCore + max(0.25, idle.busiestCore * 0.5))
        gpuActive = min(0.08, idle.gpuActive + max(0.02, idle.gpuActive * 0.5))
        aneWatts = min(0.2, idle.aneWatts + Self.anePowerAllowance(for: aneActivity))
        diskBytesPerSecond = min(2_097_152, idle.diskBytesPerSecond + 1_048_576)
    }
}

struct IdleReading: Codable, Equatable {
    var cpuActive: Double
    var busiestCore: Double
    var gpuActive: Double
    var aneWatts: Double
    var diskBytesPerSecond: Double
    var uptime: Double

    init?(_ sensors: SensorSnapshot) {
        guard let gpu = sensors.gpuActive, let ane = sensors.aneWatts, let disk = sensors.diskBytesPerSecond,
            (0...0.1).contains(sensors.cpuActive), (0...0.5).contains(sensors.busiestCore),
            (0...0.06).contains(gpu), (0...0.1).contains(ane), (0...1_048_576).contains(disk),
            sensors.memoryPressure == "normal", sensors.thermalState == "nominal",
            sensors.aneQuietBlocker(limits: QuietLimits(baseline: nil, aneActivity: sensors.aneActivity)) == nil
        else { return nil }
        cpuActive = sensors.cpuActive
        busiestCore = sensors.busiestCore
        gpuActive = gpu
        aneWatts = ane
        diskBytesPerSecond = disk
        uptime = sensors.uptime
    }
}

struct IdleBaseline: Codable, Equatable {
    var cpuActive = 0.0
    var busiestCore = 0.0
    var gpuActive = 0.0
    var aneWatts = 0.0
    var diskBytesPerSecond = 0.0
    var uptime = 0.0
    var calibrationSamples = 0
    var readings: [IdleReading]?

    mutating func observe(_ sample: IdleReading, allowIncrease: Bool) {
        var readings = readings ?? []
        guard readings.last?.uptime != sample.uptime else { return }
        readings.removeAll { sample.uptime - $0.uptime > 300 }
        readings.append(sample)
        if readings.count > 32 { readings.removeFirst() }
        self.readings = readings
        let fields: [(WritableKeyPath<Self, Double>, KeyPath<IdleReading, Double>)] = [
            (\.cpuActive, \.cpuActive), (\.busiestCore, \.busiestCore), (\.gpuActive, \.gpuActive),
            (\.aneWatts, \.aneWatts), (\.diskBytesPerSecond, \.diskBytesPerSecond),
        ]
        for (field, reading) in fields {
            let sorted = readings.map { $0[keyPath: reading] }.sorted()
            let measured = sorted[sorted.count < 4 ? sorted.count / 2 : sorted.count / 4]
            let current = self[keyPath: field]
            if calibrationSamples < 5 {
                if readings.count != 2 || measured <= current { self[keyPath: field] = measured }
            } else if allowIncrease || measured < current {
                self[keyPath: field] = current + 0.05 * (measured - current)
            }
        }
        uptime = sample.uptime
        calibrationSamples = min(5, calibrationSamples + 1)
    }
}

struct AdmissionSnapshot: Codable, Equatable {
    var sensors: SensorSnapshot
    var idleBaseline: IdleBaseline?
    var quietLimits: QuietLimits?

    init?(state: SchedulerState, measurement: Bool) {
        guard let sensors = state.sensors else { return nil }
        self.sensors = sensors
        idleBaseline = measurement ? state.idleBaseline : nil
        idleBaseline?.readings = nil
        quietLimits = measurement ? QuietLimits(baseline: state.idleBaseline, aneActivity: sensors.aneActivity) : nil
    }
}
