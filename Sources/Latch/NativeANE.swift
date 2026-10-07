import Foundation

struct ANEActivity: Codable, Equatable {
    enum Source: String, Codable {
        case compute, cluster, powerFloor

        var label: String {
            switch self {
            case .compute: "compute"
            case .cluster: "active time"
            case .powerFloor: "floor est."
            }
        }

        var explanation: String {
            switch self {
            case .compute: "residency-weighted compute utilization"
            case .cluster: "busiest cluster's active-time share"
            case .powerFloor:
                "time above the ANE's lowest power/bandwidth request; activity estimate, not compute occupancy"
            }
        }
    }

    var fraction: Double
    var source: Source
}

enum NativeANE {
    // Channel conventions: SiliconScope and mactop (MIT); see LICENSES/.
    // IOReport exposes different signals across chips. Keep their meaning with the reading.
    static func source(group: String, subgroup: String, name: String) -> ANEActivity.Source? {
        let unit = name.split(separator: " ").last.map(String.init) ?? ""
        func numbered(_ value: String, prefix: String) -> Bool {
            value.hasPrefix(prefix) && value.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
        if group == "SoC Stats", subgroup == "Cluster Power States",
            numbered(unit, prefix: "ANE")
                || (unit.hasSuffix("_ANE") && numbered(String(unit.dropLast(4)), prefix: "PACC"))
        {
            return .cluster
        }
        let domain = group.split(separator: " ").last.map(String.init) ?? ""
        guard numbered(domain, prefix: "PMP") else { return nil }
        if subgroup == "Fast-Die CE", numbered(unit, prefix: "ANE") { return .compute }
        if subgroup == "SOC Floor" {
            if numbered(unit, prefix: "ANE") || unit == "ANE-AF-BW" { return .powerFloor }
            if unit.hasSuffix("-AF-BW"), numbered(String(unit.dropLast(6)), prefix: "ANE-LNK") {
                return .powerFloor
            }
        }
        if subgroup == "DCS Floor", numbered(unit, prefix: "ANE") || unit == "ANE-DCS-BW" { return .powerFloor }
        return nil
    }

    static func fraction(states: [(name: String, residency: Int64)], source: ANEActivity.Source) -> Double? {
        guard !states.isEmpty, states.allSatisfy({ $0.residency >= 0 }) else { return nil }
        let states = states.map {
            (name: $0.name.trimmingCharacters(in: .whitespaces), residency: Double($0.residency))
        }
        let total = states.reduce(0) { $0 + $1.residency }
        guard total > 0 else { return nil }
        switch source {
        case .compute:
            var weighted = 0.0
            for state in states {
                guard state.name.hasSuffix("%"), let percent = Double(state.name.dropLast()),
                    percent.isFinite, (0...100).contains(percent)
                else { return nil }
                weighted += state.residency * (percent / 100)
            }
            return weighted / total
        case .cluster:
            guard states.contains(where: { $0.name == "ACT" }),
                states.allSatisfy({ ["ACT", "INACT", "OFF", "IDLE", "DOWN", "SLEEP"].contains($0.name) })
            else { return nil }
            return states.filter { $0.name == "ACT" }.reduce(0) { $0 + $1.residency } / total
        case .powerFloor:
            let idle: String
            if states.contains(where: { $0.name == "VMIN" }) {
                guard
                    states.allSatisfy({
                        ["VMIN", "VNOM", "VMAX", "VOVD", "VOVD_TYP"].contains($0.name)
                            || ($0.name.hasPrefix("VOVD") && $0.name.dropFirst(4).allSatisfy(\.isNumber))
                    })
                else { return nil }
                idle = "VMIN"
            } else {
                let levels = states.compactMap { state -> Int? in
                    guard state.name.hasPrefix("F") else { return nil }
                    return Int(state.name.dropFirst())
                }
                guard levels.count == states.count, let lowest = levels.min(), lowest > 0 else { return nil }
                idle = "F\(lowest)"
            }
            return states.filter { $0.name != idle }.reduce(0) { $0 + $1.residency } / total
        }
    }

    static func preferred(_ readings: [ANEActivity]) -> ANEActivity? {
        for source in [ANEActivity.Source.compute, .cluster, .powerFloor] {
            if let fraction = readings.filter({ $0.source == source }).map(\.fraction).max() {
                return ANEActivity(fraction: fraction, source: source)
            }
        }
        return nil
    }
}
