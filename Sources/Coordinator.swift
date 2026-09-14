import AppKit
import IOKit.pwr_mgt

@MainActor
final class Coordinator {
    // Sensor endpoints, measured per machine by the setup walkthrough. The
    // visual range below is deliberately not calibrated: it is an artistic
    // constant describing how much travel a full gesture is worth, so the blur
    // and dissolve tuning stays valid on every laptop.
    private(set) var calibration = CalibrationStore.load() ?? .fallback
    private let fullVisualRange = 200.0
    /// True while the setup walkthrough owns the screen. Lid movement must not
    /// raise the overlay on top of the instructions the user is reading.
    private(set) var inSetup = false
    /// Every valid sensor reading, for the walkthrough's live angle display.
    var onAngle: ((Double) -> Void)?
    let sensor = LidSensor()
    let overlay: Overlay
    var onChange: (() -> Void)?
    private(set) var status = "Checking the lid sensor…"
    private(set) var angle: Double?
    private(set) var enabled = false
    private(set) var previewing = false
    private var tracker = MotionTracker()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var previewTimer: Timer?
    private var watchdog: Timer?
    private var lastSample = CACurrentMediaTime()
    private var lastStatusUpdate: CFTimeInterval = 0
    private var sessionSuspended = false

    static var sessionIsUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // Supplemental guard; lock notifications and lifecycle cancellation also apply.
        return (session["CGSSessionScreenIsLocked"] as? Bool != true)
            && (session[kCGSessionOnConsoleKey as String] as? Bool == true)
    }

    init() throws {
        overlay = try Overlay()
        sensor.onSample = { [weak self] angle, time in
            MainActor.assumeIsolated { self?.sample(angle, time: time) }
        }
        sensor.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.status = status; self?.onChange?() }
        }
        overlay.onError = { [weak self] message in self?.status = message; self?.onChange?() }
        observeLifecycle()
        sensor.start()
        let watchdogTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !Self.sessionIsUnlocked {
                    self.suspend()
                } else if !self.previewing && CACurrentMediaTime() - self.lastSample > 0.5 {
                    self.overlay.cancel()
                    self.tracker.reset()
                }
            }
        }
        // The watchdog is what removes a stranded overlay, so it must keep
        // running while the run loop is tracking menu or slider events.
        RunLoop.main.add(watchdogTimer, forMode: .common)
        watchdog = watchdogTimer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { [weak self] in self?.suspend() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { [weak self] in self?.resume() }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.suspend() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.resume() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.stopPreview()
            self?.overlay.invalidateDisplay()
            self?.tracker.reset()
        }
    }

    private func suspend() {
        sessionSuspended = true
        stopPreview()
        overlay.cancel()
        tracker.reset()
        sensor.stop()
    }

    private func resume() {
        guard Self.sessionIsUnlocked else { return }
        sessionSuspended = false
        tracker.reset()
        overlay.invalidateDisplay()
        lastSample = CACurrentMediaTime()
        sensor.start()
    }

    func setEnabled(_ value: Bool) {
        guard !value || CGPreflightScreenCaptureAccess() else {
            status = "Allow Screen Recording first, then enable the effect."
            onChange?()
            return
        }
        stopPreview()
        enabled = value
        tracker.reset()
        overlay.cancel()
        status = value ? "Ready — move the lid in either direction" : "Effect paused"
        onChange?()
    }

    private func sample(_ angle: Double, time: CFTimeInterval) {
        // A backed-up main queue must not replay old physical movements.
        guard CACurrentMediaTime() - time < 0.15 else { return }
        self.angle = angle
        lastSample = time
        onAngle?(angle)
        if time - lastStatusUpdate >= 0.1 {
            lastStatusUpdate = time
            onChange?()
        }
        guard enabled, !previewing, !inSetup, !sessionSuspended, Self.sessionIsUnlocked else { return }
        switch tracker.sample(angle: angle, time: time) {
        case .began(let reference, let current): overlay.begin(delta: scaledVisualDelta(reference: reference, current: current))
        case .changed(let delta):
            if let reference = tracker.reference {
                overlay.delta = scaledVisualDelta(reference: reference, current: reference + delta)
            }
        case .ended: overlay.finish()
        case nil: break
        }
    }

    /// Maps the available physical travel from this gesture's reference to
    /// the calibrated endpoint into the full visual range. Negative means
    /// toward the keyboard; positive means opening away from it.
    private func scaledVisualDelta(reference: Double, current: Double) -> Double {
        if current < reference {
            let available = max(reference - calibration.cutoffAngle, 0.001)
            let progress = min(1.0, max(0.0, (reference - current) / available))
            return -progress * fullVisualRange
        }
        let available = max(calibration.openAngle - reference, 0.001)
        let progress = min(1.0, max(0.0, (current - reference) / available))
        return progress * fullVisualRange
    }

    /// Suspends lid-driven effects while the walkthrough is on screen.
    func beginSetup() {
        inSetup = true
        stopPreview()
        overlay.cancel()
        tracker.reset()
    }

    func endSetup(enableEffect: Bool) {
        inSetup = false
        tracker.reset()
        CalibrationStore.hasCompletedSetup = true
        if enableEffect, CGPreflightScreenCaptureAccess() {
            setEnabled(true)
        } else {
            onChange?()
        }
    }

    func applyCalibration(_ value: Calibration) {
        guard value.isUsable else { return }
        calibration = value
        CalibrationStore.save(value)
        tracker.reset()
        onChange?()
    }

    func beginPreview() {
        guard !sessionSuspended, Self.sessionIsUnlocked else { return }
        stopPreview()
        previewing = true
        tracker.reset()
        // A preview holds one frozen frame at a fixed delta, so it must bypass
        // the overlay's late-capture motion check.
        overlay.begin(delta: 0, requiresMotion: false)
        status = "Preview — stop to return to the live desktop"
        onChange?()
    }

    func scrub(_ delta: Double) {
        if !previewing { beginPreview() }
        overlay.delta = delta
    }

    func playPreview(sleepAfter: Bool = false) {
        beginPreview()
        guard previewing else { return }
        var startedAt: CFTimeInterval?
        let requestedAt = CACurrentMediaTime()
        let playTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let now = CACurrentMediaTime()
                guard self.overlay.visible else {
                    if now - requestedAt > 3 { self.stopPreview() }
                    return
                }
                if startedAt == nil { startedAt = now }
                let t = min(1, (now - startedAt!) / (sleepAfter ? 0.7 : 2.4))
                if sleepAfter {
                    self.overlay.delta = -85 * t * t * (3 - 2 * t)
                } else {
                    // +30 degrees then -55 degrees, always relative to one origin.
                    self.overlay.delta = t < 0.5 ? 30 * sin(t * 2 * .pi) : -55 * sin((t - 0.5) * 2 * .pi)
                }
                if t >= 1 {
                    timer.invalidate()
                    self.previewTimer = nil
                    self.stopPreview()
                    if sleepAfter { self.sleepSystem() }
                }
            }
        }
        RunLoop.main.add(playTimer, forMode: .common)
        previewTimer = playTimer
    }

    func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewing = false
        tracker.reset()
        overlay.cancel()
        onChange?()
    }

    private func sleepSystem() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { status = "macOS could not open the sleep service."; onChange?(); return }
        let result = IOPMSleepSystem(port)
        IOServiceClose(port)
        if result != kIOReturnSuccess {
            status = "macOS declined the sleep request (\(result))."
            onChange?()
        }
    }

    func shutdown() {
        stopPreview()
        sensor.stop()
        watchdog?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }
}
