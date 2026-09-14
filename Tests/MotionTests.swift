import Foundation

@main
struct MotionTests {
    static func main() {
        var tracker = MotionTracker()
        assert(tracker.sample(angle: 90, time: 0) == nil)
        assert(tracker.sample(angle: 91, time: 0.02) == nil, "Ignore one-degree jitter")
        assert(tracker.sample(angle: 92, time: 0.04) == .began(reference: 90, angle: 92))
        assert(tracker.sample(angle: 120, time: 0.10) == .changed(delta: 30))
        assert(tracker.sample(angle: 110, time: 0.15) == .changed(delta: 20), "Reversal retains origin")
        assert(tracker.sample(angle: 85, time: 0.20) == .changed(delta: -5), "Crossing origin changes sign")
        assert(tracker.sample(angle: 85, time: 0.35) == .changed(delta: -5))
        assert(tracker.sample(angle: 85, time: 0.41) == .ended)
        assert(tracker.reference == 85)
        assert(tracker.sample(angle: 83, time: 0.45) == .began(reference: 85, angle: 83))

        tracker.reset()
        assert(tracker.sample(angle: 120, time: 1) == nil)
        assert(tracker.sample(angle: 118, time: 1.1) == .began(reference: 120, angle: 118))
        assert(tracker.sample(angle: 10, time: 1.2) == .changed(delta: -110), "No clamping to a preset fold arc")
        assert(tracker.sample(angle: 10, time: 1.41) == .ended)

        tracker.reset()
        _ = tracker.sample(angle: 80, time: 2)
        for i in 1...6 { assert(tracker.sample(angle: 80 + Double(i) * 0.2, time: 2 + Double(i) * 0.05) == nil) }
        assert(tracker.sample(angle: 81.4, time: 2.35) == .began(reference: 80, angle: 81.4), "Slow changes accumulate")
        tracker.reset()
        assert(tracker.sample(angle: .nan, time: 3) == nil)
        assert(tracker.sample(angle: 300, time: 3) == nil)
        assert(tracker.reference == nil)
        assert(tracker.sample(angle: 100, time: 3) == nil, "Resume initializes without animation")
        print("PASS: jitter, relative angle, reversals, stillness, new origin, large delta, slow movement, invalid samples, reset")
    }
}
