import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var coordinator: Coordinator?
    private var item: NSStatusItem?
    private var settings: NSWindow?
    private let angleLabel = NSTextField(labelWithString: "—°")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Starting…")
    private let permissionLabel = NSTextField(labelWithString: "Screen Recording: checking")
    private let enableButton = NSButton(checkboxWithTitle: "Respond to lid movement", target: nil, action: nil)
    private let calibrationLabel = NSTextField(labelWithString: "Lid range: —")
    private let slider = NSSlider(value: 0, minValue: -200, maxValue: 200, target: nil, action: nil)
    private let deltaLabel = NSTextField(labelWithString: "Preview visual range: 0°")
    private var effectMenuItem: NSMenuItem?
    private var eventMonitor: Any?
    private var setup: SetupWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            coordinator = try Coordinator()
        } catch {
            let alert = NSAlert()
            alert.messageText = "LidPlane couldn’t start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        buildSettings()
        coordinator?.onChange = { [weak self] in self?.refresh() }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { self?.stopPreview() }
                return nil
            }
            return event
        }
        refresh()
        // First launch goes straight into the walkthrough; the settings window
        // would only be something to dismiss before the real starting point.
        if CalibrationStore.hasCompletedSetup {
            showSettings()
        } else {
            runSetup()
        }
    }

    @objc private func runSetup() {
        guard let coordinator, setup == nil else { return }
        settings?.orderOut(nil)
        let flow = SetupWindow(coordinator: coordinator)
        flow.onFinish = { [weak self] in
            MainActor.assumeIsolated {
                self?.setup = nil
                self?.refresh()
                self?.showSettings()
            }
        }
        setup = flow
        flow.run()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◩ —°"
        item.button?.toolTip = "LidPlane — lid-relative perspective"
        let menu = NSMenu()
        menu.addItem(menuItem("Open LidPlane…", #selector(showSettings)))
        menu.addItem(menuItem("Calibrate Lid…", #selector(runSetup)))
        menu.addItem(.separator())
        let toggle = menuItem("Respond to Lid Movement", #selector(toggleFromMenu))
        effectMenuItem = toggle
        menu.addItem(toggle)
        menu.addItem(menuItem("Play Preview", #selector(playPreview), key: "p"))
        menu.addItem(menuItem("Stop Effect", #selector(stopPreview), key: "."))
        menu.addItem(.separator())
        menu.addItem(menuItem("Fold and Sleep", #selector(foldAndSleep)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit LidPlane", #selector(quit), key: "q"))
        item.menu = menu
        self.item = item
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func buildSettings() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "LidPlane"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
                root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
            ])
        }
        let title = NSTextField(labelWithString: "A little perspective.")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        root.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "Move your display. The image stays behind.\nPause, and your live desktop returns.")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 14)
        root.addArrangedSubview(intro)
        angleLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .light)
        root.addArrangedSubview(angleLabel)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(permissionLabel)
        let permissionRow = NSStackView(views: [button("Allow Screen Recording…", #selector(allowCapture)),
                                               button("Refresh", #selector(refresh))])
        permissionRow.spacing = 10
        root.addArrangedSubview(permissionRow)
        enableButton.target = self
        enableButton.action = #selector(toggleEnabled)
        root.addArrangedSubview(enableButton)
        calibrationLabel.font = .systemFont(ofSize: 12)
        calibrationLabel.textColor = .secondaryLabelColor
        let calibrationRow = NSStackView(views: [calibrationLabel, button("Calibrate…", #selector(runSetup))])
        calibrationRow.spacing = 10
        root.addArrangedSubview(calibrationRow)
        let line = NSBox()
        line.boxType = .separator
        root.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let previewTitle = NSTextField(labelWithString: "Try it without moving the lid")
        previewTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(previewTitle)
        slider.target = self
        slider.action = #selector(scrubPreview)
        slider.isContinuous = true
        root.addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        deltaLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        root.addArrangedSubview(deltaLabel)
        let previewRow = NSStackView(views: [button("Play Preview", #selector(playPreview)), button("Stop / Esc", #selector(stopPreview))])
        previewRow.spacing = 10
        root.addArrangedSubview(previewRow)
        let footnote = NSTextField(wrappingLabelWithString: "Local prototype · Built-in display only\nScreenshots stay in memory and are discarded after each effect.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        root.addArrangedSubview(footnote)
        root.addArrangedSubview(button("Quit LidPlane", #selector(quit)))
        settings = window
    }

    @objc private func refresh() {
        guard let coordinator else { return }
        let text = coordinator.angle.map { String(format: "%0.0f°", $0) } ?? "—°"
        angleLabel.stringValue = text
        item?.button?.title = "◩ \(text)"
        statusLabel.stringValue = coordinator.status
        let allowed = CGPreflightScreenCaptureAccess()
        permissionLabel.stringValue = allowed ? "Screen Recording: allowed" : "Screen Recording: permission needed"
        enableButton.state = coordinator.enabled ? .on : .off
        let calibration = coordinator.calibration
        calibrationLabel.stringValue = calibration.recordedAt == Date.distantPast
            ? "Lid range: not calibrated — using defaults"
            : String(format: "Lid range: %.0f° open · fades out at %.0f°",
                     calibration.openAngle, calibration.cutoffAngle)
        effectMenuItem?.state = coordinator.enabled ? .on : .off
        // During manual preview, keep the controls accessible above the image.
        settings?.level = coordinator.previewing ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) : .normal
    }

    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func allowCapture() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    @objc private func toggleEnabled() { coordinator?.setEnabled(enableButton.state == .on) }
    @objc private func toggleFromMenu() { coordinator?.setEnabled(!(coordinator?.enabled ?? false)) }
    @objc private func playPreview() { coordinator?.playPreview() }
    @objc private func foldAndSleep() { coordinator?.playPreview(sleepAfter: true) }
    @objc private func stopPreview() {
        coordinator?.stopPreview()
        slider.doubleValue = 0
        deltaLabel.stringValue = "Preview visual range: 0°"
    }
    @objc private func scrubPreview() {
        deltaLabel.stringValue = String(format: "Preview visual range: %+0.0f°", slider.doubleValue)
        coordinator?.scrub(slider.doubleValue)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { coordinator?.stopPreview() }
}
