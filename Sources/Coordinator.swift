import AppKit

@MainActor
final class Coordinator {
    // Sensor endpoints, measured per machine by the setup walkthrough. The
    // visual range below is deliberately not calibrated: it is an artistic
    // constant describing how much travel a full gesture is worth, so the blur
    // and dissolve tuning stays valid on every laptop.
    private var config = ConfigStore.load()
    var calibration: Calibration { config.calibration ?? .fallback }
    var setupCompleted: Bool { config.setupCompleted }
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
    /// Set once ScreenCaptureKit refuses, cleared only by an explicit retry.
    private(set) var captureBlocked = false
    private var tracker = MotionTracker()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
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

    init() {
        overlay = Overlay()
        sensor.onSample = { [weak self] angle, time in
            MainActor.assumeIsolated { self?.sample(angle, time: time) }
        }
        sensor.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.status = status; self?.onChange?() }
        }
        overlay.onError = { [weak self] message in self?.status = message; self?.onChange?() }
        overlay.onCaptureRefused = { [weak self] message in self?.captureRefused(message) }
        observeLifecycle()
        sensor.start()
        let watchdogTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !Self.sessionIsUnlocked {
                    self.suspend()
                } else if CACurrentMediaTime() - self.lastSample > 0.5 {
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
            self?.stopEffect()
            self?.overlay.invalidateDisplay()
            self?.tracker.reset()
        }
    }

    private func suspend() {
        sessionSuspended = true
        stopEffect()
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
        stopEffect()
        if value { captureBlocked = false }
        enabled = value
        config.effectEnabled = value
        ConfigStore.save(config)
        tracker.reset()
        overlay.cancel()
        status = value ? "Ready — move the lid in either direction" : "Effect paused"
        onChange?()
    }

    /// Restores the switch position from the last session. Kept separate from
    /// `setEnabled` so launching never rewrites the file it just read.
    func restoreEnabledState() {
        guard config.effectEnabled, CGPreflightScreenCaptureAccess() else {
            status = config.effectEnabled
                ? "Allow Screen Recording to enable the effect."
                : "Effect paused"
            onChange?()
            return
        }
        enabled = true
        tracker.reset()
        status = "Ready — move the lid in either direction"
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
        guard enabled, !captureBlocked, !inSetup, !sessionSuspended, Self.sessionIsUnlocked else { return }
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
        stopEffect()
        overlay.cancel()
        tracker.reset()
    }

    func endSetup(enableEffect: Bool) {
        inSetup = false
        tracker.reset()
        config.setupCompleted = true
        ConfigStore.save(config)
        if enableEffect, CGPreflightScreenCaptureAccess() {
            setEnabled(true)
        } else {
            onChange?()
        }
    }

    func applyCalibration(_ value: Calibration) {
        guard value.isUsable else { return }
        config.calibration = value
        ConfigStore.save(config)
        tracker.reset()
        onChange?()
    }

    /// ScreenCaptureKit refused. `CGPreflightScreenCaptureAccess` cannot be
    /// trusted here — it happily reports `true` off stale state while capture
    /// is actually denied — so this latch is the only reliable signal that the
    /// effect cannot work.
    ///
    /// Turning the effect off is the point: leaving it armed means the next lid
    /// movement raises another system permission prompt, and the one after
    /// that, indefinitely.
    private func captureRefused(_ message: String) {
        captureBlocked = true
        enabled = false
        config.effectEnabled = false
        ConfigStore.save(config)
        tracker.reset()
        overlay.cancel()
        status = "Screen Recording was refused. Re-grant it, then switch the effect back on."
        onChange?()
    }

    /// Clears the latch so one capture can be attempted again.
    func retryCapture() {
        captureBlocked = false
        onChange?()
    }

    /// Cancels any overlay in flight and rearms the tracker. Used by the
    /// lifecycle hooks and whenever the switch changes position.
    func stopEffect() {
        tracker.reset()
        overlay.cancel()
        onChange?()
    }

    func shutdown() {
        stopEffect()
        sensor.stop()
        watchdog?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }
}
