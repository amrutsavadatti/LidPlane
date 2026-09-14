import AppKit

/// First-run walkthrough: grant Screen Recording, measure the hinge, start using it.
///
/// Wherever the lid itself can be the input, it is — the open measurement
/// completes by holding the lid still, and the cutoff measurement completes by
/// opening it again. The user should not have to find a button mid-gesture.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private enum Step: Int { case permission, openWide, cutoff, done }

    /// Travel required before the open measurement will accept a plateau, so
    /// that a lid already resting at its stop cannot complete the step instantly.
    private static let requiredTravel = 8.0
    /// How long the lid must be held at its furthest point.
    private static let plateauSeconds: CFTimeInterval = 1.0
    /// How far the lid must reopen after the cutoff before the step completes.
    private static let reopenMargin = 10.0

    private let coordinator: Coordinator
    private let window: NSWindow
    private let stepContainer = NSView()
    private let dots: [NSView]
    private var step: Step = .permission
    var onFinish: (() -> Void)?

    // Live measurement state.
    private var startAngle: Double?
    private var maxAngle = -Double.greatestFiniteMagnitude
    private var plateauSince: CFTimeInterval?
    private var measuredOpen: Double?
    private var measuredCutoff: Double?
    private var sawSensor = false

    private let liveAngleLabel = NSTextField(labelWithString: "—°")
    private let hintLabel = NSTextField(labelWithString: "")
    private var cutoffWindow: NSWindow?
    private let cutoffPrompt = NSTextField(labelWithString: "Press Space when you can’t read this.")
    private var keyMonitor: Any?
    private var permissionTimer: Timer?
    private var sensorTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 430),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up LidPlane"
        window.isReleasedWhenClosed = false
        dots = (0..<3).map { _ in
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6)
            ])
            return dot
        }
        super.init()
        window.delegate = self
        window.center()
        buildChrome()
    }

    // MARK: - Lifecycle

    func run() {
        coordinator.beginSetup()
        coordinator.onAngle = { [weak self] angle in self?.receive(angle) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.recoverFromSleep() }
            }
        go(to: CGPreflightScreenCaptureAccess() ? .openWide : .permission)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Leaves setup mode. `completed` distinguishes finishing the walkthrough
    /// from dismissing it; either way the user is not asked again on next
    /// launch, since being re-prompted forever is worse than an uncalibrated app.
    private func close(completed: Bool) {
        permissionTimer?.invalidate(); permissionTimer = nil
        sensorTimer?.invalidate(); sensorTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        cutoffWindow?.orderOut(nil)
        cutoffWindow = nil
        coordinator.onAngle = nil
        coordinator.endSetup(enableEffect: completed)
        window.orderOut(nil)
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) { close(completed: false) }

    // MARK: - Chrome

    private func buildChrome() {
        guard let content = window.contentView else { return }
        stepContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stepContainer)
        let dotRow = NSStackView(views: dots)
        dotRow.spacing = 7
        dotRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dotRow)
        NSLayoutConstraint.activate([
            stepContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44),
            stepContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44),
            stepContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            stepContainer.bottomAnchor.constraint(equalTo: dotRow.topAnchor, constant: -20),
            dotRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dotRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26)
        ])
    }

    private func updateDots() {
        for (index, dot) in dots.enumerated() {
            let filled = step == .done || index <= step.rawValue
            dot.layer?.backgroundColor = filled
                ? NSColor.controlAccentColor.cgColor
                : NSColor.quaternaryLabelColor.cgColor
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = false
        return field
    }

    private func present(_ views: [NSView]) {
        stepContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: stepContainer.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: stepContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: stepContainer.topAnchor)
        ])
        stack.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            stack.animator().alphaValue = 1
        }
        updateDots()
    }

    private func primaryButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.keyEquivalent = "\r"
        button.bezelStyle = .push
        button.controlSize = .large
        return button
    }

    // MARK: - Step routing

    private func go(to next: Step) {
        step = next
        switch next {
        case .permission: showPermission()
        case .openWide: showOpenWide()
        case .cutoff: showCutoff()
        case .done: showDone()
        }
    }

    // MARK: - Step 1, permission

    private func showPermission() {
        present([
            label("Allow Screen Recording", size: 26, weight: .semibold),
            label("LidPlane freezes an image of your own display while the lid moves. Nothing is written to disk or sent anywhere.",
                  size: 13, color: .secondaryLabelColor),
            primaryButton("Open System Settings", #selector(requestPermission)),
            label("This screen continues on its own once permission is granted.",
                  size: 11, color: .tertiaryLabelColor)
        ])
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.step == .permission else { return }
                guard CGPreflightScreenCaptureAccess() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.go(to: .openWide)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    @objc private func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 2, maximum open angle

    private func showOpenWide() {
        startAngle = nil
        maxAngle = -.greatestFiniteMagnitude
        plateauSince = nil
        sawSensor = false
        liveAngleLabel.font = .monospacedDigitSystemFont(ofSize: 52, weight: .thin)
        liveAngleLabel.stringValue = "—°"
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.stringValue = "Waiting for the lid sensor…"
        let manual = NSButton(title: "Use this angle", target: self, action: #selector(acceptCurrentAngle))
        manual.bezelStyle = .accessoryBarAction
        present([
            label("Open your lid all the way back", size: 26, weight: .semibold),
            label("Push it to where it stops, and hold it there.", size: 13, color: .secondaryLabelColor),
            liveAngleLabel,
            hintLabel,
            manual
        ])
        // If no reading ever arrives this Mac cannot be calibrated. Say so
        // rather than leaving the user holding a lid against a dead screen.
        sensorTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.step == .openWide, !self.sawSensor else { return }
                self.showSensorUnavailable()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sensorTimer = timer
    }

    private func receive(_ angle: Double) {
        sawSensor = true
        switch step {
        case .openWide: trackOpening(angle)
        case .cutoff: trackReopening(angle)
        default: break
        }
    }

    private func trackOpening(_ angle: Double) {
        liveAngleLabel.stringValue = String(format: "%.0f°", angle)
        if startAngle == nil { startAngle = angle }
        if angle > maxAngle + 0.4 {
            maxAngle = angle
            plateauSince = nil
        }
        guard maxAngle - (startAngle ?? angle) >= Self.requiredTravel else {
            hintLabel.stringValue = "Keep opening…"
            return
        }
        guard angle >= maxAngle - 0.75 else {
            plateauSince = nil
            hintLabel.stringValue = "Keep opening…"
            return
        }
        let now = CACurrentMediaTime()
        if plateauSince == nil { plateauSince = now }
        let held = now - (plateauSince ?? now)
        hintLabel.stringValue = "Hold it there…"
        if held >= Self.plateauSeconds {
            measuredOpen = maxAngle
            go(to: .cutoff)
        }
    }

    @objc private func acceptCurrentAngle() {
        guard let angle = coordinator.angle else { return }
        measuredOpen = max(angle, maxAngle > 0 ? maxAngle : angle)
        go(to: .cutoff)
    }

    private func showSensorUnavailable() {
        present([
            label("No lid sensor readings", size: 26, weight: .semibold),
            label("This Mac isn’t reporting a hinge angle. LidPlane will use its default range — the effect still works, it just won’t be tuned to your laptop.",
                  size: 13, color: .secondaryLabelColor),
            primaryButton("Continue", #selector(finishWithDefaults))
        ])
    }

    @objc private func finishWithDefaults() { close(completed: true) }

    // MARK: - Step 3, visual cutoff

    private func showCutoff() {
        measuredCutoff = nil
        present([
            label("Now close the lid slowly", size: 26, weight: .semibold),
            label("Your screen fades from view well before the lid shuts. Press the Space bar the moment you can no longer read the screen.",
                  size: 13, color: .secondaryLabelColor),
            primaryButton("I’m Ready", #selector(beginCutoffMeasurement))
        ])
    }

    @objc private func beginCutoffMeasurement() {
        let screen = Overlay.builtInScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setFrame(screen.frame, display: true)

        let root = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        // Large and high contrast on purpose: the measurement should be about
        // the display's viewing angle, not about finding small text.
        cutoffPrompt.stringValue = "Press Space when you can’t read this."
        cutoffPrompt.font = .systemFont(ofSize: 58, weight: .medium)
        cutoffPrompt.textColor = .white
        cutoffPrompt.alignment = .center
        cutoffPrompt.isSelectable = false
        cutoffPrompt.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cutoffPrompt)
        NSLayoutConstraint.activate([
            cutoffPrompt.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            cutoffPrompt.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            cutoffPrompt.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.8)
        ])
        panel.contentView = root
        panel.orderFrontRegardless()
        cutoffWindow = panel

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var handled = false
            MainActor.assumeIsolated {
                if event.keyCode == 49 { self.recordCutoff(); handled = true }
                else if event.keyCode == 53 { self.abortCutoff(); handled = true }
            }
            return handled ? nil : event
        }
    }

    private func recordCutoff() {
        guard step == .cutoff, measuredCutoff == nil, let angle = coordinator.angle else { return }
        measuredCutoff = angle
        // The user cannot see a visual confirmation at this point, so the
        // acknowledgement has to be audible.
        NSSound.beep()
        cutoffPrompt.stringValue = "Open your lid back up"
    }

    private func trackReopening(_ angle: Double) {
        guard let cutoff = measuredCutoff else { return }
        guard angle >= cutoff + Self.reopenMargin else { return }
        finishCutoff()
    }

    private func finishCutoff() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cutoffWindow?.orderOut(nil)
        cutoffWindow = nil
        go(to: .done)
    }

    private func abortCutoff() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cutoffWindow?.orderOut(nil)
        cutoffWindow = nil
        measuredCutoff = nil
        go(to: .cutoff)
    }

    /// Closing the lid past the cutoff without pressing Space sleeps the Mac
    /// mid-measurement. Restart the step instead of leaving it half finished.
    private func recoverFromSleep() {
        guard step == .cutoff, measuredCutoff == nil else { return }
        abortCutoff()
    }

    // MARK: - Step 4, done

    private func showDone() {
        let open = measuredOpen ?? coordinator.calibration.openAngle
        let cutoff = measuredCutoff ?? coordinator.calibration.cutoffAngle
        let candidate = Calibration(openAngle: open, cutoffAngle: cutoff, recordedAt: Date())
        guard candidate.isUsable else {
            present([
                label("Those readings don’t look right", size: 26, weight: .semibold),
                label(String(format: "Your lid measured %.0f° open and %.0f° at cutoff, which is too narrow a range to animate. Let’s measure again.", open, cutoff),
                      size: 13, color: .secondaryLabelColor),
                primaryButton("Measure Again", #selector(restartMeasurement))
            ])
            return
        }
        coordinator.applyCalibration(candidate)
        present([
            label("You’re all set", size: 26, weight: .semibold),
            label(String(format: "Your lid opens to %.0f°, and your screen fades from view around %.0f°. The effect is tuned to that range.", open, cutoff),
                  size: 13, color: .secondaryLabelColor),
            primaryButton("Start Using LidPlane", #selector(finishSetup)),
            label("LidPlane lives in the menu bar. Press Esc to stop an effect.",
                  size: 11, color: .tertiaryLabelColor)
        ])
    }

    @objc private func restartMeasurement() {
        measuredOpen = nil
        measuredCutoff = nil
        go(to: .openWide)
    }

    @objc private func finishSetup() { close(completed: true) }
}
