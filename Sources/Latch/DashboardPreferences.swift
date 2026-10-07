import Foundation

struct DashboardPreferences {
    private struct Settings: Codable {
        var refreshInterval: Double
    }

    let url: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let directory =
            environment["XDG_CONFIG_HOME"].flatMap {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
            } ?? home.appendingPathComponent(".config")
        url = directory.appendingPathComponent("latch/tui.json")
    }

    func loadInterval() -> Double {
        guard let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(Settings.self, from: data),
            settings.refreshInterval.isFinite, (0.5...60).contains(settings.refreshInterval)
        else { return 1 }
        return settings.refreshInterval
    }

    func saveInterval(_ interval: Double) throws {
        guard interval.isFinite, (0.5...60).contains(interval) else {
            throw LatchError("refresh interval must be between 0.5 and 60 seconds")
        }
        try InstallationPaths.privateDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(Settings(refreshInterval: interval))
        try data.write(to: url, options: .atomic)
    }
}
