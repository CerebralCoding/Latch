import Foundation
import Testing

@testable import Latch

@Test(.enabled(if: ProcessInfo.processInfo.environment["LATCH_VALIDATE_ADMISSION"] == "1"))
func validateNativeAdmission() throws {
    struct Observation: Encodable {
        var admission: AdmissionSnapshot
        var blocker: String?
        var quietSince: Double?
    }
    var state = SchedulerState()
    var observations: [Observation] = []
    for _ in 0..<64 {
        let sensors = try NativeSensors.sample()
        state.record(sensors)
        observations.append(
            Observation(
                admission: try #require(AdmissionSnapshot(state: state, measurement: true)),
                blocker: sensors.quietBlocker(baseline: state.idleBaseline), quietSince: state.quietSince))
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(observations).write(
        to: root.appendingPathComponent(".build/admission-validation.json"), options: .atomic)
    #expect(state.idleBaseline?.calibrationSamples == 5)
    #expect(
        observations.contains { observation in
            guard let since = observation.quietSince else { return false }
            return observation.admission.sensors.uptime - since >= SchedulingPolicy.quietPeriod
        })
}
