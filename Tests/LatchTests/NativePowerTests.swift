import Foundation
import Testing

@testable import Latch

@Suite struct NativePowerTests {
    @Test func energyChannelsExcludeComponentBreakdownsAndResidency() {
        for name in ["CPU Energy", "DIE_0_CPU Energy", "DIE_1_CPU Energy"] {
            #expect(NativePower.component(group: "Energy Model", name: name, format: 1) == .cpu)
        }
        #expect(NativePower.component(group: "Energy Model", name: "GPU Energy", format: 1) == .gpu)
        #expect(NativePower.component(group: "Energy Model", name: "ANE0_1", format: 1) == .ane)
        for name in ["GPU SRAM0", "EACC_CPU0", "DRAM0"] {
            #expect(NativePower.component(group: "Energy Model", name: name, format: 1) == nil)
        }
        #expect(NativePower.component(group: "PMP", name: "ANE0", format: 2) == nil)
        #expect(NativePower.component(group: "Energy Model", name: "CPU Energy", format: 2) == nil)
    }

    @Test func energyDeltasConvertToWattsAndSumAcrossDies() throws {
        var power = NativePower()
        #expect(power[.cpu] == nil)
        power.record(.cpu, energy: 600, unit: "mJ", seconds: 0.2)
        power.record(.cpu, energy: 400_000, unit: "uJ", seconds: 0.2)
        power.record(.gpu, energy: 300_000_000, unit: "nJ ", seconds: 0.2)
        power.record(.ane, energy: 0, unit: "mJ", seconds: 0.2)
        #expect(power[.cpu] == 5)
        #expect(abs(try #require(power[.gpu]) - 1.5) < 0.000001)
        #expect(power[.ane] == 0)
    }

    @Test func invalidEnergyNeverBecomesZeroOrPartialPower() {
        for (energy, unit, seconds) in [
            (Int64(-1), "mJ", 1.0), (1, "ticks", 1), (1, "mJ", 0),
            (1, "mJ", -1), (1, "mJ", .infinity), (1, "mJ", .nan),
        ] {
            var power = NativePower()
            power.record(.cpu, energy: 100, unit: "mJ", seconds: 1)
            power.record(.cpu, energy: energy, unit: unit, seconds: seconds)
            power.record(.cpu, energy: 200, unit: "mJ", seconds: 1)
            power.record(.gpu, energy: 0, unit: "mJ", seconds: 1)
            #expect(power[.cpu] == nil)
            #expect(power[.gpu] == 0)
        }
    }
}
