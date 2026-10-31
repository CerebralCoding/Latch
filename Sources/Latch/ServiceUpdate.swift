import CryptoKit
import Darwin
import Foundation

struct BuildIdentity: Codable, Equatable {
    static let version = "0.22.0"
    static let serviceRevision = 1
    var release: String
    var serviceRevision: Int
    var sha256: String

    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct UpdateReceipt: Codable {
    var current: BuildIdentity
    var previous: BuildIdentity?
}

struct UpdateServiceControl {
    var loaded: () throws -> Bool
    var revision: () throws -> Int?
    var stop: () throws -> Void
    var start: () throws -> Void
}

/// The launch-agent file an update keeps in step with the installed binary.
struct ServicePlist {
    var url: URL
    var contents: Data

    func differs(from existing: Data) throws -> Bool {
        let parse = { try PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary }
        return try parse(existing) != parse(contents)
    }
}

enum ServiceUpdate {
    static func previous(in updates: URL) -> URL {
        updates.appendingPathComponent("latch.previous")
    }

    static func receipt(in updates: URL) -> URL {
        updates.appendingPathComponent("installation.json")
    }

    static func apply(
        source: URL, target: URL, updates: URL, scheduler: Scheduler, rollback: Bool = false,
        timeout: Double = 600, restartService: Bool = false, expectedIdentifier: String? = nil,
        plist: ServicePlist? = nil, service: UpdateServiceControl
    ) throws -> Bool {
        let manager = FileManager.default
        try InstallationPaths.privateDirectory(updates)
        let installLock = try FileLatch(path: updates.appendingPathComponent("installation.lock").path)
        try installLock.acquire(shared: false, timeout: 0)
        defer { installLock.release() }
        return try withExtendedLifetime(installLock) {
            let drain = try UpdateDrain(scheduler: scheduler)
            defer { drain.finish() }
            return try withExtendedLifetime(drain) {
                try drain.wait(timeout: timeout)
                let attributes = try manager.attributesOfItem(atPath: target.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                    (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
                else {
                    throw LatchError("installed executable must be a regular file owned by this user", exitCode: 74)
                }
                let receiptURL = receipt(in: updates)
                let previousReceipt = try Data(contentsOf: receiptURL)
                let record = try JSONDecoder().decode(UpdateReceipt.self, from: previousReceipt)
                let currentHash = try BuildIdentity.digest(target)
                guard record.current.sha256 == currentHash else {
                    throw LatchError("installed executable does not match its installation receipt", exitCode: 74)
                }
                let current = record.current
                let candidate = rollback ? previous(in: updates) : source
                let parent = target.deletingLastPathComponent()
                let staged = parent.appendingPathComponent(UUID().uuidString)
                let original = parent.appendingPathComponent(UUID().uuidString)
                let backup = updates.appendingPathComponent(UUID().uuidString)
                var preserveRecovery = false
                defer {
                    try? manager.removeItem(at: staged)
                    try? manager.removeItem(at: backup)
                    if !preserveRecovery {
                        try? manager.removeItem(at: original)
                    }
                }
                try manager.copyItem(at: candidate, to: staged)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
                guard
                    ServiceIdentity.identifier(for: staged)
                        == (expectedIdentifier ?? ServiceIdentity.identifier(for: target))
                else {
                    throw LatchError("replacement must use the installed service's identifier", exitCode: 74)
                }
                let hash = try BuildIdentity.digest(staged)
                let next: BuildIdentity
                if rollback {
                    guard let saved = record.previous, saved.sha256 == hash else {
                        throw LatchError("rollback binary is missing a matching installation receipt", exitCode: 74)
                    }
                    next = saved
                } else {
                    next = BuildIdentity(
                        release: BuildIdentity.version, serviceRevision: BuildIdentity.serviceRevision, sha256: hash)
                }
                var originalPlist: Data?
                var plistChanged = false
                if let plist {
                    let existing = try Data(contentsOf: plist.url)
                    originalPlist = existing
                    plistChanged = try plist.differs(from: existing)
                }
                let replacesExecutable = rollback || hash != currentHash
                let wasLoaded = try service.loaded()
                let runningRevision = try service.revision()
                let restart =
                    wasLoaded
                    && (replacesExecutable || restartService || runningRevision != next.serviceRevision
                        || plistChanged)
                if !replacesExecutable, !plistChanged {
                    if restart {
                        try service.stop()
                        try service.start()
                    }
                    return restart
                }
                if replacesExecutable {
                    try manager.copyItem(at: target, to: original)
                    // Backup and executable may live on different volumes; commit each rename locally.
                    try manager.copyItem(at: original, to: backup)
                }
                var replaced = false
                var wrotePlist = false
                do {
                    if restart {
                        try service.stop()
                    }
                    if replacesExecutable {
                        try replace(staged, target)
                        replaced = true
                    }
                    if plistChanged, let plist {
                        try plist.contents.write(to: plist.url, options: .atomic)
                        wrotePlist = true
                    }
                    if restart {
                        try service.start()
                    }
                    if replacesExecutable {
                        try UpdateDrain.advance(in: scheduler.directory)
                        try JSONEncoder().encode(UpdateReceipt(current: next, previous: current)).write(
                            to: receiptURL, options: .atomic)
                        try replace(backup, previous(in: updates))
                    }
                } catch {
                    let failure = error
                    do {
                        if restart {
                            try service.stop()
                        }
                        if replaced {
                            try replace(original, target)
                        }
                        if wrotePlist, let plist, let originalPlist {
                            try originalPlist.write(to: plist.url, options: .atomic)
                        }
                        try previousReceipt.write(to: receiptURL, options: .atomic)
                        if restart {
                            try service.start()
                        }
                    } catch {
                        preserveRecovery = true
                        throw LatchError(
                            "update failed: \(failure); recovery failed: \(error). Inspect the installation before retrying; any remaining recovery copy is at \(original.path)",
                            exitCode: 74)
                    }
                    throw LatchError("update failed; previous installation restored: \(failure)", exitCode: 74)
                }
                return restart
            }
        }
    }

    private static func replace(_ source: URL, _ destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw LatchError.system("replace \(destination.lastPathComponent)")
        }
    }
}
