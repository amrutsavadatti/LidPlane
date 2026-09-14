import AppKit

/// The whole product surface: an icon in the menu bar.
///
/// Left click opens a popover holding a single switch, in the manner of the
/// Passwords menu-bar item. Right click opens a short menu for the two actions
/// that have nowhere else to live — recalibrating, and quitting, which an
/// `LSUIElement` app has no Dock icon or app menu to offer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var coordinator: Coordinator?
    private var item: NSStatusItem?
    private var setup: SetupWindow?
    private let popover = NSPopover()
    private let effectSwitch = NSSwitch()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let permissionRow = NSStackView()
    private var eventMonitor: Any?

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
        buildStatusItem()
        buildPopover()
        coordinator?.onChange = { [weak self] in self?.refresh() }
        // Esc cancels an effect in flight without having to reach the menu bar.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.coordinator?.stopEffect() }
            return nil
        }
        if coordinator?.setupCompleted == true {
            coordinator?.restoreEnabledState()
        } else {
            runSetup()
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "LidPlane") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "◩"
        }
        item.button?.toolTip = "LidPlane"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary { showContextMenu() } else { togglePopover() }
    }

    private func showContextMenu() {
        guard let item else { return }
        let menu = NSMenu()
        let calibrate = NSMenuItem(title: "Calibrate Lid…", action: #selector(runSetup), keyEquivalent: "")
        calibrate.target = self
        menu.addItem(calibrate)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LidPlane", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // Attaching the menu and clicking is the supported way to show a menu
        // from a status item that normally handles clicks itself.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - Popover

    /// Fixed width; the height is whatever the content needs.
    private static let popoverWidth: CGFloat = 260

    private func buildPopover() {
        let title = NSTextField(labelWithString: "Lid effect")
        title.font = .systemFont(ofSize: 13, weight: .medium)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        effectSwitch.target = self
        effectSwitch.action = #selector(toggleEffect)

        let titles = NSStackView(views: [title, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        // A spacer that yields its width so the switch is pushed to the edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [titles, spacer, effectSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        // Stacked vertically rather than beside the button: a wrapping sentence
        // and a button side by side in 260pt leaves neither enough room.
        let warning = NSTextField(wrappingLabelWithString:
            "Screen Recording is blocked. Grant it, then switch the effect on again.")
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .secondaryLabelColor
        // Without this the label reports a single-line height and the popover
        // is sized too short for the text it actually draws.
        warning.preferredMaxLayoutWidth = Self.popoverWidth - 28
        let fixButton = NSButton(title: "Open Settings", target: self, action: #selector(openCaptureSettings))
        fixButton.bezelStyle = .accessoryBarAction
        fixButton.controlSize = .small
        permissionRow.orientation = .vertical
        permissionRow.alignment = .leading
        permissionRow.spacing = 6
        permissionRow.setViews([warning, fixButton], in: .leading)
        permissionRow.isHidden = true

        let root = NSStackView(views: [row, permissionRow])
        root.orientation = .vertical
        // .width makes every arranged subview span the popover, so the switch
        // stays pinned right whether or not the warning is showing.
        root.alignment = .width
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: Self.popoverWidth).isActive = true
        // A hidden arranged subview must leave the layout entirely, or the
        // popover keeps reserving space for the warning that is not drawn.
        root.detachesHiddenViews = true

        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    /// The popover does not track its content, so the size is recomputed
    /// whenever the permission row appears or disappears.
    private func resizePopover() {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        if popover.contentSize != fitting { popover.contentSize = fitting }
    }

    private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func refresh() {
        guard let coordinator else { return }
        // Preflight reports true off stale state while capture is actually
        // refused, so the latch has to be consulted alongside it.
        let allowed = CGPreflightScreenCaptureAccess() && !coordinator.captureBlocked
        effectSwitch.state = coordinator.enabled ? .on : .off
        permissionRow.isHidden = allowed
        let calibration = coordinator.calibration
        subtitleLabel.stringValue = calibration.recordedAt == Date.distantPast
            ? "Not calibrated"
            : String(format: "%.0f° – %.0f°", calibration.cutoffAngle, calibration.openAngle)
        // Dim the icon while the effect is off, so the menu bar reflects state
        // without needing a second glyph.
        item?.button?.appearsDisabled = !coordinator.enabled
        resizePopover()
    }

    @objc private func toggleEffect() {
        coordinator?.setEnabled(effectSwitch.state == .on)
        refresh()
    }

    @objc private func openCaptureSettings() {
        coordinator?.retryCapture()
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Setup

    @objc private func runSetup() {
        guard let coordinator, setup == nil else { return }
        popover.performClose(nil)
        let flow = SetupWindow(coordinator: coordinator)
        flow.onFinish = { [weak self] in
            MainActor.assumeIsolated {
                self?.setup = nil
                self?.refresh()
            }
        }
        setup = flow
        flow.run()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
