import CryptoKit
import Darwin
import Foundation

struct BuildIdentity: Codable, Equatable {
    static let version = "0.7.0"
    // Bump when daemon behavior or its client/state contract requires a service restart.
    static let serviceRevision = 3
    var release: String
    var serviceRevision: Int?
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
    var previous: BuildIdentity
}

struct UpdateServiceControl {
    var loaded: () throws -> Bool
    var revision: () throws -> Int?
    var stop: () throws -> Void
    var start: () throws -> Void
}

enum ServiceUpdate {
    static func previous(for target: URL) -> URL {
        target.appendingPathExtension("previous")
    }

    static func receipt(for target: URL) -> URL {
        target.appendingPathExtension("installation.json")
    }

    static func apply(source: URL, target: URL, scheduler: Scheduler, rollback: Bool = false,
                      timeout: Double = 600, restartService: Bool = false, service: UpdateServiceControl) throws -> Bool
    {
        let manager = FileManager.default
        let installLock = try FileLatch(path: target.appendingPathExtension("update.lock").path)
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
                let receiptURL = receipt(for: target)
                let previousReceipt: Data?
                do { previousReceipt = try Data(contentsOf: receiptURL) }
                catch CocoaError.fileReadNoSuchFile { previousReceipt = nil }
                let record = try previousReceipt.map { try JSONDecoder().decode(UpdateReceipt.self, from: $0) }
                let currentHash = try BuildIdentity.digest(target)
                let current = record?.current.sha256 == currentHash ? record!.current : BuildIdentity(release: "unknown", serviceRevision: nil, sha256: currentHash)
                let candidate = rollback ? previous(for: target) : source
                let parent = target.deletingLastPathComponent()
                let staged = parent.appendingPathComponent(UUID().uuidString)
                let original = parent.appendingPathComponent(UUID().uuidString)
                var preserveRecovery = false
                defer {
                    try? manager.removeItem(at: staged)
                    if !preserveRecovery {
                        try? manager.removeItem(at: original)
                    }
                }
                try manager.copyItem(at: candidate, to: staged)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
                let hash = try BuildIdentity.digest(staged)
                let next: BuildIdentity
                if rollback {
                    guard let saved = record?.previous, saved.sha256 == hash else {
                        throw LatchError("rollback binary is missing a matching installation receipt", exitCode: 74)
                    }
                    next = saved
                } else {
                    next = BuildIdentity(release: BuildIdentity.version, serviceRevision: BuildIdentity.serviceRevision, sha256: hash)
                }
                let wasLoaded = try service.loaded()
                let runningRevision = try service.revision()
                let restart = wasLoaded && (restartService || next.serviceRevision == nil || runningRevision != next.serviceRevision)
                if !rollback, hash == currentHash {
                    if restart {
                        try service.stop()
                        try service.start()
                    }
                    return restart
                }
                try manager.copyItem(at: target, to: original)
                var replaced = false
                do {
                    if restart {
                        try service.stop()
                    }
                    try replace(staged, target)
                    replaced = true
                    if restart {
                        try service.start()
                    }
                    try UpdateDrain.advance(in: scheduler.directory)
                    try JSONEncoder().encode(UpdateReceipt(current: next, previous: current)).write(to: receiptURL, options: .atomic)
                    try replace(original, previous(for: target))
                } catch {
                    let failure = error
                    do {
                        if restart {
                            try service.stop()
                        }
                        if replaced {
                            try replace(original, target)
                        }
                        if let previousReceipt {
                            try previousReceipt.write(to: receiptURL, options: .atomic)
                        } else if manager.fileExists(atPath: receiptURL.path) {
                            try manager.removeItem(at: receiptURL)
                        }
                        if restart {
                            try service.start()
                        }
                    } catch {
                        preserveRecovery = true
                        throw LatchError("update failed: \(failure); recovery failed: \(error). Inspect the installation before retrying; any remaining recovery copy is at \(original.path)", exitCode: 74)
                    }
                    throw LatchError("update failed; previous installation restored: \(failure)", exitCode: 74)
                }
                return restart
            }
        }
    }

    private static func replace(_ source: URL, _ destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else { throw LatchError.system("replace \(destination.lastPathComponent)") }
    }
}
