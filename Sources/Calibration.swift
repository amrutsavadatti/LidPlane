import Foundation

/// The two hinge angles that differ from one MacBook to the next.
///
/// `openAngle` is how far back the lid physically travels. `cutoffAngle` is
/// where the screen stops being visible to the user, which lands well above 0°
/// — driving the effect below it would spend most of the animation on travel
/// nobody can see.
struct Calibration: Codable, Equatable {
    var openAngle: Double
    var cutoffAngle: Double
    var recordedAt: Date

    /// Used until the walkthrough runs. These are the values measured on the
    /// original development machine.
    static let fallback = Calibration(openAngle: 128, cutoffAngle: 0, recordedAt: .distantPast)

    /// Rejects readings that would make `scaledVisualDelta` degenerate or
    /// invert. The 15° floor is deliberately loose; it only has to catch a
    /// mis-measurement, not enforce a plausible hinge.
    var isUsable: Bool {
        openAngle.isFinite && cutoffAngle.isFinite
            && cutoffAngle >= 0 && openAngle <= 180
            && openAngle - cutoffAngle >= 15
    }
}

/// Everything the app remembers between launches.
struct AppConfig: Codable {
    var calibration: Calibration?
    var setupCompleted: Bool
    /// A menu-bar app with a single switch has to come back in the state the
    /// user left it in; otherwise the effect silently turns itself off on
    /// every login.
    var effectEnabled: Bool

    static let empty = AppConfig(calibration: nil, setupCompleted: false, effectEnabled: false)
}

/// Config lives as readable JSON in Application Support rather than in the
/// preferences domain, so it can be inspected, backed up, and deleted on its
/// own without touching anything else the app might store.
enum ConfigStore {
    /// Retained only to migrate anyone who calibrated before the move.
    private static let legacyCalibrationKey = "calibration.v1"
    private static let legacyCompletedKey = "setup.completed.v1"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LidPlane", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        if let data = try? Data(contentsOf: fileURL),
           var config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            if let calibration = config.calibration, !calibration.isUsable { config.calibration = nil }
            return config
        }
        if let migrated = migrateFromDefaults() {
            save(migrated)
            return migrated
        }
        return .empty
    }

    static func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// One-time lift of the UserDefaults-era values so an existing install does
    /// not have to run the walkthrough again.
    private static func migrateFromDefaults() -> AppConfig? {
        let defaults = UserDefaults.standard
        let completed = defaults.bool(forKey: legacyCompletedKey)
        var calibration: Calibration?
        if let data = defaults.data(forKey: legacyCalibrationKey),
           let decoded = try? JSONDecoder().decode(Calibration.self, from: data), decoded.isUsable {
            calibration = decoded
        }
        guard completed || calibration != nil else { return nil }
        defaults.removeObject(forKey: legacyCalibrationKey)
        defaults.removeObject(forKey: legacyCompletedKey)
        return AppConfig(calibration: calibration, setupCompleted: completed, effectEnabled: false)
    }
}
