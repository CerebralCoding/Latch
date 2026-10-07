import Foundation
import Testing

@testable import Latch

@Suite struct NativeANETests {
    @Test func selectsOnlyRelevantStateChannels() {
        #expect(NativeANE.source(group: "SoC Stats", subgroup: "Cluster Power States", name: "DIE0 ANE1") == .cluster)
        #expect(NativeANE.source(group: "SoC Stats", subgroup: "Cluster Power States", name: "PACC0_ANE") == .cluster)
        #expect(NativeANE.source(group: "PMP0", subgroup: "Fast-Die CE", name: "ANE0") == .compute)
        #expect(NativeANE.source(group: "PMP0", subgroup: "SOC Floor", name: "ANE-LNK0-AF-BW") == .powerFloor)
        #expect(NativeANE.source(group: "PMP", subgroup: "DCS Floor", name: "ANE-DCS-BW") == .powerFloor)
        for (group, subgroup, name) in [
            ("Energy Model", "", "ANE0"), ("SoC Stats", "Events", "ANE_THROTTLE_SW_TRIG"),
            ("PMP0", "AF BW", "ANE L0 RD+WR"), ("PMP0", "SOC Floor", "ANE-UNKNOWN"),
            ("PMP0", "Fast-Die CE", "NOTANE0"), ("GPU Stats", "Cluster Power States", "ANE0"),
        ] { #expect(NativeANE.source(group: group, subgroup: subgroup, name: name) == nil) }
    }

    @Test func validatesAndDistinguishesUtilizationSources() {
        #expect(NativeANE.fraction(states: [("ACT", 25), ("INACT", 75)], source: .cluster) == 0.25)
        #expect(NativeANE.fraction(states: [("ACT", 0), ("INACT", 100)], source: .cluster) == 0)
        #expect(NativeANE.fraction(states: [(" 0%", 20), ("50%", 40), ("100%", 40)], source: .compute) == 0.6)
        #expect(NativeANE.fraction(states: [("VMIN", 60), ("VNOM", 20), ("VMAX", 20)], source: .powerFloor) == 0.4)
        #expect(NativeANE.fraction(states: [("F1", 50), ("F2", 50)], source: .powerFloor) == 0.5)
        #expect(NativeANE.fraction(states: [("F2", 75), ("F3", 25)], source: .powerFloor) == 0.25)
        for source in [ANEActivity.Source.compute, .cluster, .powerFloor] {
            #expect(NativeANE.fraction(states: [], source: source) == nil)
            #expect(NativeANE.fraction(states: [("ACT", -1), ("INACT", 10)], source: source) == nil)
        }
        #expect(NativeANE.fraction(states: [("ACT", 0), ("INACT", 0)], source: .cluster) == nil)
        #expect(NativeANE.fraction(states: [("0%", 0), ("100%", 0)], source: .compute) == nil)
        #expect(NativeANE.fraction(states: [("UNKNOWN", 10)], source: .cluster) == nil)
        #expect(NativeANE.fraction(states: [("VMIN", 10), ("UNKNOWN", 10)], source: .powerFloor) == nil)
        #expect(NativeANE.fraction(states: [("101%", 10)], source: .compute) == nil)
        let readings = [
            ANEActivity(fraction: 0.9, source: .powerFloor), .init(fraction: 0.5, source: .cluster),
            .init(fraction: 0.8, source: .cluster),
        ]
        #expect(NativeANE.preferred(readings) == .init(fraction: 0.8, source: .cluster))
        #expect(
            NativeANE.preferred(readings + [.init(fraction: 0, source: .compute)])
                == .init(fraction: 0, source: .compute))
    }

    @Test func currentSensorEncodingPreservesANESource() throws {
        var sensors = try NativeSensors.sample()
        sensors.aneActivity = .init(fraction: 0.4, source: .powerFloor)
        sensors.cpuWatts = 12.3
        sensors.gpuWatts = 4.5
        let decoded = try JSONDecoder().decode(SensorSnapshot.self, from: JSONEncoder().encode(sensors))
        #expect(decoded == sensors)
        #expect(DashboardMetric.ane.value(decoded) == 40)
    }
}
