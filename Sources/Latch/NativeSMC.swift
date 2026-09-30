import Darwin
import Foundation
import IOKit

/// AppleSMC protocol and temperature key families follow macmon (LICENSES/macmon.txt).
final class NativeSMC {
    private let connection: io_connect_t
    private var keys: [UInt32: [UInt8]] = [:]
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []

    init() throws {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS
        else {
            throw LatchError("AppleSMC unavailable", exitCode: 69)
        }
        defer { IOObjectRelease(iterator) }
        var opened: io_connect_t = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 {
                break
            }
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS,
                String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    == "AppleSMCKeysEndpoint"
            else { continue }
            guard IOServiceOpen(service, mach_task_self_, 0, &opened) == KERN_SUCCESS else {
                throw LatchError("cannot open AppleSMC temperature sensors", exitCode: 69)
            }
            break
        }
        guard opened != 0 else { throw LatchError("AppleSMC temperature endpoint unavailable", exitCode: 69) }
        connection = opened
        let countBytes = try value(Self.key("#KEY"))
        guard countBytes.count >= 4 else { throw LatchError("invalid SMC key count", exitCode: 74) }
        let count = countBytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count < 100_000 else { throw LatchError("invalid SMC key count", exitCode: 74) }
        for index in 0..<count {
            guard let output = try? call(command: 8, index: index) else { continue }
            let key = output.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let prefix = UInt16(key >> 16)
            if [UInt16(0x5470), 0x5465, 0x5473].contains(prefix) {
                cpuKeys.append(key)
            }
            if prefix == 0x5467 {
                gpuKeys.append(key)
            }
        }
    }

    deinit { IOServiceClose(connection) }

    func temperatures() -> (cpu: Double?, gpu: Double?) {
        // Use the hottest valid sensor in each family, rather than hiding hot spots in an average.
        (cpuKeys.compactMap { try? temperature($0) }.max(), gpuKeys.compactMap { try? temperature($0) }.max())
    }

    static func decodeTemperature(_ bytes: [UInt8], type: UInt32) -> Double? {
        let value: Double
        if type == key("flt "), bytes.count == 4 {
            let bits = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            value = Double(Float(bitPattern: UInt32(littleEndian: bits)))
        } else if type == key("sp78"), bytes.count == 2 {
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        } else {
            return nil
        }
        return value.isFinite && value > 0 && value < 150 ? value : nil
    }

    static func key(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func temperature(_ key: UInt32) throws -> Double {
        let info = try information(key)
        let type = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard let value = try Self.decodeTemperature(value(key), type: type) else {
            throw LatchError("invalid SMC temperature", exitCode: 74)
        }
        return value
    }

    private func information(_ key: UInt32) throws -> [UInt8] {
        if let cached = keys[key] {
            return cached
        }
        let output = try call(command: 9, key: key)
        let info = Array(output[28..<40])
        keys[key] = info
        return info
    }

    private func value(_ key: UInt32) throws -> [UInt8] {
        let info = try information(key)
        let count = info.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard count > 0, count <= 32 else { throw LatchError("invalid SMC value size", exitCode: 74) }
        let output = try call(command: 5, key: key, info: info)
        return Array(output[48..<(48 + Int(count))])
    }

    private func call(command: UInt8, key: UInt32 = 0, index: UInt32 = 0, info: [UInt8]? = nil) throws -> [UInt8] {
        // The kernel's 80-byte SMCKeyData ABI includes padding; Swift struct layout is not an ABI guarantee.
        var input = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: key, as: UInt32.self)
            $0.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
        }
        input[42] = command
        if let info {
            input.replaceSubrange(28..<40, with: info)
        }
        var output = [UInt8](repeating: 0, count: 80)
        var size = output.count
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, source.count, target.baseAddress, &size)
            }
        }
        guard result == KERN_SUCCESS, size == 80, output[40] == 0 else {
            throw LatchError("SMC read failed (\(result), \(output[40]))", exitCode: 74)
        }
        return output
    }
}
