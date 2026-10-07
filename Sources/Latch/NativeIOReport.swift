import CoreFoundation
import Darwin
import Foundation

/// IOReport channel/residency conventions follow macmon; see LICENSES/macmon.txt.
final class NativeIOReport {
    private typealias CopyChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias Subscribe =
        @convention(c) (
            UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64,
            CFTypeRef?
        ) -> Unmanaged<CFTypeRef>?
    private typealias Sample = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Label = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias Value = @convention(c) (CFDictionary, Int32) -> Int64

    private let library: UnsafeMutableRawPointer
    private var subscription: CFTypeRef?
    private var channels: CFMutableDictionary?
    private var subscribedChannels: CFMutableDictionary?
    private let createSample: Sample
    private let createDelta: Delta
    private let channelName: Label
    private let unit: Label
    private let stateCount: Count
    private let stateName: StateName
    private let residency: Value
    private let integerValue: Value
    private let group: Label
    private let subgroup: Label
    private let format: Count

    init() throws {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw LatchError("IOReport unavailable", exitCode: 69)
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw LatchError("IOReport missing \(name)", exitCode: 69) }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            let copy = try symbol("IOReportCopyAllChannels", CopyChannels.self)
            let subscribe = try symbol("IOReportCreateSubscription", Subscribe.self)
            createSample = try symbol("IOReportCreateSamples", Sample.self)
            createDelta = try symbol("IOReportCreateSamplesDelta", Delta.self)
            channelName = try symbol("IOReportChannelGetChannelName", Label.self)
            unit = try symbol("IOReportChannelGetUnitLabel", Label.self)
            stateCount = try symbol("IOReportStateGetCount", Count.self)
            stateName = try symbol("IOReportStateGetNameForIndex", StateName.self)
            residency = try symbol("IOReportStateGetResidency", Value.self)
            integerValue = try symbol("IOReportSimpleGetIntegerValue", Value.self)
            group = try symbol("IOReportChannelGetGroup", Label.self)
            subgroup = try symbol("IOReportChannelGetSubGroup", Label.self)
            format = try symbol("IOReportChannelGetFormat", Count.self)
            guard let all = copy(0, 0)?.takeRetainedValue(),
                let items = (all as NSDictionary)["IOReportChannels"] as? [NSDictionary],
                let selected = CFDictionaryCreateMutableCopy(nil, 0, all)
            else {
                throw LatchError("IOReport channels unavailable", exitCode: 69)
            }
            let nameOfChannel = channelName
            let groupOfChannel = group
            let subgroupOfChannel = subgroup
            let formatOfChannel = format
            let selectedItems = items.filter { item in
                let category = groupOfChannel(item as CFDictionary)?.takeUnretainedValue() as String? ?? ""
                let subcategory = subgroupOfChannel(item as CFDictionary)?.takeUnretainedValue() as String? ?? ""
                let name = nameOfChannel(item as CFDictionary)?.takeUnretainedValue() as String?
                return (category == "GPU Stats" && name == "GPUPH")
                    || NativePower.component(
                        group: category, name: name ?? "", format: formatOfChannel(item as CFDictionary)) != nil
                    || (formatOfChannel(item as CFDictionary) == 2
                        && NativeANE.source(group: category, subgroup: subcategory, name: name ?? "") != nil)
            }
            let key = "IOReportChannels" as CFString
            let array = selectedItems as CFArray
            CFDictionarySetValue(
                selected, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(array).toOpaque())
            var subscribed: Unmanaged<CFMutableDictionary>?
            guard let subscription = subscribe(nil, selected, &subscribed, 0, nil)?.takeRetainedValue() else {
                throw LatchError("IOReport subscription unavailable", exitCode: 69)
            }
            self.library = library
            self.subscription = subscription
            channels = selected
            subscribedChannels = subscribed?.takeRetainedValue()
        } catch {
            dlclose(library)
            throw error
        }
    }

    deinit {
        subscription = nil
        subscribedChannels = nil
        channels = nil
        dlclose(library)
    }

    func sample() -> CFDictionary? {
        guard let subscription, let channels else { return nil }
        return createSample(subscription, channels, nil)?.takeRetainedValue()
    }

    func activity(from first: CFDictionary?, to second: CFDictionary?, seconds: Double) -> (
        gpu: Double?, ane: Double?, aneActivity: ANEActivity?, cpuWatts: Double?, gpuWatts: Double?
    ) {
        guard let first, let second, seconds > 0,
            let delta = createDelta(first, second, nil)?.takeRetainedValue(),
            let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return (nil, nil, nil, nil, nil) }
        var gpu: Double?
        var power = NativePower()
        var aneReadings: [ANEActivity] = []
        for item in items {
            let channel = item as CFDictionary
            let name = channelName(channel)?.takeUnretainedValue() as String? ?? ""
            let category = group(channel)?.takeUnretainedValue() as String? ?? ""
            let subcategory = subgroup(channel)?.takeUnretainedValue() as String? ?? ""
            if format(channel) == 2,
                let source = NativeANE.source(group: category, subgroup: subcategory, name: name)
            {
                let count = stateCount(channel)
                guard count > 0, count < 1000 else { continue }
                let states = (0..<count).map { index in
                    (
                        name: stateName(channel, index)?.takeUnretainedValue() as String? ?? "",
                        residency: residency(channel, index)
                    )
                }
                if let fraction = NativeANE.fraction(states: states, source: source) {
                    aneReadings.append(ANEActivity(fraction: fraction, source: source))
                }
            } else if category == "GPU Stats", name == "GPUPH" {
                let count = stateCount(channel)
                guard count > 0, count < 1000 else { continue }
                var active = 0.0
                var total = 0.0
                var valid = true
                for index in 0..<count {
                    let value = residency(channel, index)
                    guard value >= 0, let label = stateName(channel, index)?.takeUnretainedValue() as String? else {
                        valid = false
                        break
                    }
                    total += Double(value)
                    if !["OFF", "IDLE", "DOWN"].contains(label) {
                        active += Double(value)
                    }
                }
                if valid, total > 0 {
                    gpu = max(gpu ?? 0, active / total)
                }
            } else if let component = NativePower.component(group: category, name: name, format: format(channel)) {
                power.record(
                    component, energy: integerValue(channel, 0),
                    unit: unit(channel)?.takeUnretainedValue() as String?, seconds: seconds)
            }
        }
        return (gpu, power[.ane], NativeANE.preferred(aneReadings), power[.cpu], power[.gpu])
    }
}
