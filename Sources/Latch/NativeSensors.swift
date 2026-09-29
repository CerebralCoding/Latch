import Darwin
import Foundation
import IOKit

final class NativeSensors {
    private let report: NativeIOReport?
    private let temperatures: NativeSMC?
    private var initializationErrors: [String] = []

    init() {
        do { report = try NativeIOReport() }
        catch {
            report = nil
            initializationErrors.append(String(describing: error))
        }
        do { temperatures = try NativeSMC() }
        catch {
            temperatures = nil
            initializationErrors.append(String(describing: error))
        }
    }

    static func sample() throws -> SensorSnapshot {
        try NativeSensors().read()
    }

    func read() throws -> SensorSnapshot {
        var unavailable = initializationErrors
        let firstCPU = try Self.cpuTicks()
        let firstDisk = Self.diskBytes()
        let firstReport = report?.sample()
        let started = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.2)
        let secondCPU = try Self.cpuTicks()
        let secondDisk = Self.diskBytes()
        let secondReport = report?.sample()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - started
        let activities = zip(firstCPU, secondCPU).map { first, second in
            let delta = zip(first, second).map { $1 &- $0 }
            let total = delta.reduce(UInt64(0)) { $0 + UInt64($1) }
            return total > 0 ? Double(total - UInt64(delta[Int(CPU_STATE_IDLE)])) / Double(total) : 0
        }
        guard !activities.isEmpty, activities.count == firstCPU.count,
              firstCPU.count == secondCPU.count, elapsed > 0
        else {
            throw LatchError("CPU sampling failed", exitCode: 74)
        }
        let accelerator = report?.activity(from: firstReport, to: secondReport, seconds: elapsed)
        if accelerator?.gpu == nil {
            unavailable.append("GPU residency")
        }
        if accelerator?.ane == nil {
            unavailable.append("ANE power")
        }
        let disk: Double?
        if let firstDisk, let secondDisk, secondDisk >= firstDisk {
            disk = Double(secondDisk - firstDisk) / elapsed
        } else {
            disk = nil
            unavailable.append("disk I/O")
        }
        let memory = try Self.availableMemory()
        let temperature = temperatures?.temperatures()
        if temperature?.cpu == nil {
            unavailable.append("CPU temperature")
        }
        if temperature?.gpu == nil {
            unavailable.append("GPU temperature")
        }
        var pressure: Int32 = 0
        var size = MemoryLayout.size(ofValue: pressure)
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        let pressureName = pressureResult == 0 ? [1: "normal", 2: "warning", 4: "critical"][Int(pressure)] ?? "unknown" : "unknown"
        if pressureName == "unknown" {
            unavailable.append(pressureResult == 0 ? "memory pressure value \(pressure)" : "memory pressure: \(String(cString: strerror(errno)))")
        }
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return SensorSnapshot(
            sampledAt: Date(), uptime: now, cpuCores: activities.count,
            cpuActive: activities.reduce(0, +) / Double(activities.count),
            busiestCore: activities.max() ?? 0, gpuActive: accelerator?.gpu,
            aneWatts: accelerator?.ane, memoryAvailableMiB: memory,
            memoryTotalMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            memoryPressure: pressureName, thermalState: thermal,
            diskBytesPerSecond: disk, unavailable: unavailable,
            cpuTemperature: temperature?.cpu, gpuTemperature: temperature?.gpu,
        )
    }

    private static func cpuTicks() throws -> [[UInt32]] {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count: natural_t = 0
        var info: processor_info_array_t?
        var size: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &size) == KERN_SUCCESS,
              let info else { throw LatchError("cannot read CPU counters", exitCode: 74) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(size) * 4) }
        return (0 ..< Int(count)).map { core in
            (0 ..< Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + $0]) }
        }
    }

    private static func availableMemory() throws -> Int {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64_data_t()
        var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { throw LatchError("cannot read memory counters", exitCode: 74) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else {
            throw LatchError("cannot read memory page size", exitCode: 74)
        }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        return Int(pages * UInt64(pageSize) / 1_048_576)
    }

    private static func diskBytes() -> UInt64? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var sum: UInt64 = 0
        var found = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 {
                break
            }
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let read = stats["Bytes (Read)"] as? NSNumber,
               let written = stats["Bytes (Write)"] as? NSNumber
            {
                sum += read.uint64Value + written.uint64Value
                found = true
            }
        }
        return found ? sum : nil
    }
}
