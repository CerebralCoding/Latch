import Darwin
import Foundation

struct InstallationPaths {
    static let identifier = "com.cerebralcoding.latch"
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    var executable: URL { home.appendingPathComponent(".local/bin/latch") }
    var state: URL { home.appendingPathComponent(".local/state/latch") }
    var logs: URL { state.appendingPathComponent("logs") }
    var updates: URL { state.appendingPathComponent("updates") }
    var cache: URL { home.appendingPathComponent(".cache/latch") }
    var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.identifier).plist") }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func privateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
        else {
            throw LatchError(
                "directory must be owned by this user and must not be a symlink: \(url.path)", exitCode: 74)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

enum ServiceInstall {
    static func uninstall(paths: InstallationPaths, stop: () throws -> Void) throws {
        let manager = FileManager.default
        let lock = try FileLatch(path: paths.updates.appendingPathComponent("installation.lock").path)
        try lock.acquire(shared: false, timeout: 0)
        defer { lock.release() }
        _ = try ServiceInstallation.installedPath(paths: paths)
        let attributes = try manager.attributesOfItem(atPath: paths.executable.path)
        let receipt = try JSONDecoder().decode(
            UpdateReceipt.self, from: Data(contentsOf: ServiceUpdate.receipt(in: paths.updates)))
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
            receipt.current.sha256 == (try BuildIdentity.digest(paths.executable))
        else { throw LatchError("refusing to uninstall a changed or unrelated executable", exitCode: 74) }
        try stop()
        try manager.removeItem(at: paths.plist)
        try manager.removeItem(at: paths.executable)
        try manager.removeItem(at: ServiceUpdate.receipt(in: paths.updates))
        let previous = ServiceUpdate.previous(in: paths.updates)
        if InstallationPaths.exists(previous) { try manager.removeItem(at: previous) }
    }

    static func install(
        source: URL, paths: InstallationPaths, queue: String, service: UpdateServiceControl
    ) throws {
        let manager = FileManager.default
        try InstallationPaths.privateDirectory(paths.state)
        try InstallationPaths.privateDirectory(paths.updates)
        let lock = try FileLatch(path: paths.updates.appendingPathComponent("installation.lock").path)
        try lock.acquire(shared: false, timeout: 0)
        defer { lock.release() }
        guard !InstallationPaths.exists(paths.executable), !InstallationPaths.exists(paths.plist),
            !InstallationPaths.exists(ServiceUpdate.receipt(in: paths.updates)), !(try service.loaded())
        else {
            throw LatchError(
                "installation already exists; use update or resolve the conflicting path first", exitCode: 74)
        }
        try manager.createDirectory(at: paths.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InstallationPaths.privateDirectory(paths.logs)
        let staged = paths.executable.deletingLastPathComponent().appendingPathComponent(".latch-\(UUID())")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let identity = BuildIdentity(
            release: BuildIdentity.version, serviceRevision: BuildIdentity.serviceRevision,
            sha256: try BuildIdentity.digest(staged))
        let data = try PropertyListSerialization.data(
            fromPropertyList: ServiceInstallation.configuration(
                executable: paths.executable.path, path: URL(fileURLWithPath: queue).standardizedFileURL.path,
                logs: paths.logs.path), format: .xml, options: 0)
        guard renamex_np(staged.path, paths.executable.path, UInt32(RENAME_EXCL)) == 0 else {
            throw LatchError.system("install executable without replacing an existing file")
        }
        var wrotePlist = false
        var wroteReceipt = false
        var attemptedStart = false
        do {
            try data.write(to: paths.plist, options: .withoutOverwriting)
            wrotePlist = true
            try JSONEncoder().encode(UpdateReceipt(current: identity, previous: nil)).write(
                to: ServiceUpdate.receipt(in: paths.updates), options: .withoutOverwriting)
            wroteReceipt = true
            attemptedStart = true
            try service.start()
        } catch {
            let failure = error
            if attemptedStart {
                do { try service.stop() } catch {
                    throw LatchError(
                        "installation failed: \(failure); service cleanup failed: \(error). Installation retained for recovery",
                        exitCode: 74)
                }
            }
            try manager.removeItem(at: paths.executable)
            if wrotePlist { try manager.removeItem(at: paths.plist) }
            if wroteReceipt { try manager.removeItem(at: ServiceUpdate.receipt(in: paths.updates)) }
            throw LatchError("installation failed; new installation removed: \(failure)", exitCode: 74)
        }
    }
}
