import Foundation

/// One reference angle per gesture. No absolute-angle activation threshold.
struct MotionTracker {
    enum Event: Equatable {
        case began(reference: Double, angle: Double)
        case changed(delta: Double)
        case ended
    }

    let activationDegrees = 1.25
    let stillnessSeconds = 0.20
    private(set) var reference: Double?
    private(set) var active = false
    private var lastMotionAngle: Double = 0
    private var lastMotionTime: TimeInterval = 0

    mutating func reset() {
        reference = nil
        active = false
    }

    mutating func sample(angle: Double, time: TimeInterval) -> Event? {
        guard angle.isFinite, (0...180).contains(angle) else { return nil }
        guard let origin = reference else {
            reference = angle
            lastMotionAngle = angle
            lastMotionTime = time
            return nil
        }
        if !active {
            guard abs(angle - origin) >= activationDegrees else { return nil }
            active = true
            lastMotionAngle = angle
            lastMotionTime = time
            return .began(reference: origin, angle: angle)
        }
        if abs(angle - lastMotionAngle) >= 0.6 {
            lastMotionAngle = angle
            lastMotionTime = time
        }
        if time - lastMotionTime >= stillnessSeconds {
            active = false
            reference = angle
            return .ended
        }
        return .changed(delta: angle - origin)
    }
}
