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

/// Calibration lives in UserDefaults; it is two numbers and a date, and it
/// should survive app updates without the user thinking about it.
enum CalibrationStore {
    private static let key = "calibration.v1"
    private static let completedKey = "setup.completed.v1"

    static func load() -> Calibration? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Calibration.self, from: data),
              value.isUsable else { return nil }
        return value
    }

    static func save(_ calibration: Calibration) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Tracked separately from the calibration itself, so that someone who
    /// finishes setup on a Mac with no usable sensor is not walked through it
    /// again on every launch.
    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }
}
