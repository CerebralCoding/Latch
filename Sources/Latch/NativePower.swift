import Foundation

struct NativePower {
    enum Component { case cpu, gpu, ane }

    private var readings: [Component: Double] = [:]
    private var invalid: Set<Component> = []

    // Energy Model channel names follow macmon; see LICENSES/macmon.txt.
    static func component(group: String, name: String, format: Int32) -> Component? {
        guard group == "Energy Model", format == 1 else { return nil }
        if name.hasSuffix("CPU Energy") { return .cpu }
        if name == "GPU Energy" { return .gpu }
        if name.hasPrefix("ANE") { return .ane }
        return nil
    }

    mutating func record(_ component: Component, energy: Int64, unit: String?, seconds: Double) {
        let scale = ["J": 1.0, "mJ": 1e3, "uJ": 1e6, "nJ": 1e9][
            unit?.trimmingCharacters(in: .whitespaces) ?? ""]
        guard energy >= 0, seconds.isFinite, seconds > 0, let scale else {
            invalid.insert(component)
            return
        }
        let total = (readings[component] ?? 0) + Double(energy) / scale / seconds
        guard total.isFinite else {
            invalid.insert(component)
            return
        }
        readings[component] = total
    }

    subscript(_ component: Component) -> Double? {
        invalid.contains(component) ? nil : readings[component]
    }
}
