import AppKit
import CoreImage
import ScreenCaptureKit

/// Recoverable conditions the overlay raises for itself, as opposed to errors
/// thrown out of ScreenCaptureKit. The distinction matters: these do not latch
/// the effect off, capture refusals do.
enum PlaneError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text): return text }
    }
}

@MainActor
final class Overlay {
    /// Blur radii, in source pixels, for the progressive defocus ladder. Each
    /// level is a separate copy of the screenshot; a vertical mask decides how
    /// far down from the moving edge that level reaches. Stacking them gives a
    /// continuous falloff instead of the single sharp/blurred crossfade, which
    /// read as a flat translucent sheet laid over the screenshot.
    ///
    /// The last radius is reserved for the closing direction, which is tuned to
    /// defocus harder than opening. See `closingBlurFullScale`.
    private static let blurRadii: [CGFloat] = [10, 26, 58, 120, 200]
    /// Index into `blurRadii` that only participates while the lid is closing.
    private static let closingOnlyLevel = 4
    /// Visual degrees at which the closing blur reaches full strength. Past
    /// roughly -90 the lid has gone beyond the range where the effect is still
    /// visible, so saturating there puts the whole ramp inside the part that
    /// actually gets seen. This deliberately does not touch the perspective
    /// transform, which stays mapped across the full ±200 range.
    private static let closingBlurFullScale = 90.0
    /// Time constant for easing the rendered angle toward the sensor's. The lid
    /// sensor reports whole degrees, and with ~100° of physical travel mapped
    /// onto ±200° of visual range each 1° step lands as roughly 2° of animation.
    /// Rendering those steps directly is what made the effect feel like the lid
    /// being shoved rather than gliding. Raising this smooths harder but adds
    /// visible lag behind the physical lid, which breaks the illusion faster
    /// than the jitter does.
    private static let smoothingTau: CFTimeInterval = 0.055
    /// Below this the eased value is snapped and the loop can idle.
    private static let settleEpsilon = 0.02
    private static let fadeSeconds: CFTimeInterval = 0.14
    /// How stale the last delta change may be when a capture lands. A gesture
    /// that has already gone still must not drop a frozen screenshot over the
    /// live desktop. Kept just inside `MotionTracker.stillnessSeconds`.
    private static let motionGracePeriod: CFTimeInterval = 0.18

    private let window: NSWindow
    private let stageView: NSView
    /// Carries the hinge-anchored perspective transform. Everything that must
    /// stay glued to the screen panel lives inside it, so the dissolve and the
    /// blur bands travel with the image instead of sitting in stage space.
    private let panelView: NSView
    private let imageView: NSImageView
    private let blurViews: [NSImageView]
    private let blurMasks: [CAGradientLayer]
    /// Masks the whole panel. Opaque at the hinge, transparent at the moving
    /// edge, so the screenshot's straight top edge melts into the black
    /// background rather than ending on a visible rectangular line.
    private let edgeDissolveLayer: CAGradientLayer
    private let sideFadeLayer: CAGradientLayer
    private var generation = 0
    private var captureTask: Task<Void, Never>?
    /// Rendering runs off a display link rather than the sensor callback, so the
    /// animation is resampled at the screen's refresh rate instead of inheriting
    /// the sensor's 60 Hz quantised steps.
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var fadeStart: CFTimeInterval?
    /// What is actually drawn; eases toward `delta`.
    private var visibleDelta: Double = 0
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    /// Building a CIContext per call is expensive and the blur ladder needs
    /// four of them per gesture.
    private let ciContext = CIContext(options: nil)
    var onError: ((String) -> Void)?
    /// Raised when ScreenCaptureKit itself refuses. Distinct from `onError`
    /// because the only sane response is to stop arming the effect: every
    /// retry is another permission prompt in the user's face.
    var onCaptureRefused: ((String) -> Void)?
    private(set) var active = false
    private(set) var visible = false
    /// False for previews, which legitimately hold a still image at a fixed delta.
    private var requiresMotion = true
    private var lastMovementTime: CFTimeInterval = 0
    /// The angle the lid is at. Treated as a target: the display link eases
    /// `visibleDelta` toward it rather than snapping the transform here.
    var delta: Double = 0 {
        didSet {
            if abs(delta - oldValue) > 0.01 {
                lastMovementTime = CACurrentMediaTime()
                resumeTicking()
            }
        }
    }

    static var builtInScreen: NSScreen? {
        NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsAsleep(id) == 0
        }
    }

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        stageView = NSView(frame: .zero)
        stageView.wantsLayer = true
        stageView.layer?.backgroundColor = NSColor.black.cgColor
        stageView.autoresizingMask = [.width, .height]

        panelView = NSView(frame: .zero)
        panelView.wantsLayer = true
        panelView.autoresizingMask = [.width, .height]

        imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.autoresizingMask = [.width, .height]
        imageView.isHidden = true

        // Sharp copy at the bottom of the stack, then increasingly blurred
        // copies above it. Each one is revealed only near the moving edge, so
        // sharpness falls off with distance from the hinge.
        var levels: [NSImageView] = []
        var masks: [CAGradientLayer] = []
        for _ in Self.blurRadii {
            let view = NSImageView(frame: .zero)
            view.imageScaling = .scaleAxesIndependently
            view.imageAlignment = .alignCenter
            view.wantsLayer = true
            view.autoresizingMask = [.width, .height]
            view.isHidden = true
            let mask = CAGradientLayer()
            mask.type = .axial
            mask.startPoint = CGPoint(x: 0.5, y: 0.0)
            mask.endPoint = CGPoint(x: 0.5, y: 1.0)
            view.layer?.mask = mask
            levels.append(view)
            masks.append(mask)
        }
        blurViews = levels
        blurMasks = masks

        edgeDissolveLayer = CAGradientLayer()
        edgeDissolveLayer.type = .axial
        edgeDissolveLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        edgeDissolveLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

        sideFadeLayer = CAGradientLayer()
        sideFadeLayer.type = .axial
        sideFadeLayer.colors = [
            NSColor.black.withAlphaComponent(0.72).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.72).cgColor
        ]
        sideFadeLayer.locations = [0.0, 0.5, 1.0]
        sideFadeLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        sideFadeLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        sideFadeLayer.frame = stageView.bounds
        sideFadeLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        panelView.addSubview(imageView)
        for view in blurViews { panelView.addSubview(view) }
        panelView.layer?.mask = edgeDissolveLayer
        stageView.addSubview(panelView)
        stageView.layer?.addSublayer(sideFadeLayer)
        window.contentView = stageView
    }

    func invalidateDisplay() {
        content = nil
        contentDate = .distantPast
        cancel()
    }

    /// `requiresMotion` gates the late-capture suppression below. Previews pass
    /// false because they deliberately hold one frozen frame at a fixed delta.
    func begin(delta: Double, requiresMotion: Bool = true) {
        cancel()
        guard CGPreflightScreenCaptureAccess() else {
            onError?("Allow Screen Recording to enable the effect.")
            return
        }
        guard let screen = Self.builtInScreen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            onError?("The built-in display is unavailable.")
            return
        }
        active = true
        self.requiresMotion = requiresMotion
        self.lastMovementTime = CACurrentMediaTime()
        self.delta = delta
        // Snap rather than easing in from the previous gesture's angle.
        self.visibleDelta = delta
        let token = generation
        // Establish the destination before capturing; never fall back to an external display.
        window.setFrame(screen.frame, display: false)
        let width = Int(screen.frame.width * screen.backingScaleFactor)
        let height = Int(screen.frame.height * screen.backingScaleFactor)
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let shareable: SCShareableContent
                if let cached = self.content, Date().timeIntervalSince(self.contentDate) < 5 {
                    shareable = cached
                } else {
                    shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    self.content = shareable
                    self.contentDate = Date()
                }
                guard !Task.isCancelled, token == self.generation, self.active else { return }
                guard let display = shareable.displays.first(where: { $0.displayID == displayID }) else {
                    throw PlaneError.unavailable("The built-in display changed during capture.")
                }
                let ownApps = shareable.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.showsCursor = false
                config.capturesAudio = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard !Task.isCancelled, token == self.generation, self.active,
                      Coordinator.sessionIsUnlocked else { return }
                // After `.ended` the tracker rebases its reference to the
                // settled angle, so the lid merely coming to rest can start a
                // fresh gesture. Its capture would land on a desktop that is no
                // longer moving and paint a frozen screenshot over live
                // content. Drop the capture instead of presenting it.
                if self.requiresMotion,
                   CACurrentMediaTime() - self.lastMovementTime > Self.motionGracePeriod {
                    self.cancel()
                    return
                }
                let size = NSSize(width: screen.frame.width, height: screen.frame.height)
                let captured = NSImage(cgImage: image, size: size)
                self.imageView.image = captured
                for (level, view) in self.blurViews.enumerated() {
                    let blurred = self.makeBlurredImage(image, radius: Self.blurRadii[level])
                    // A level that fails to render is dropped rather than
                    // substituted with the sharp image, which would put a
                    // hard-edged copy on top of the ladder.
                    view.image = blurred.map { NSImage(cgImage: $0, size: size) }
                    view.isHidden = blurred == nil
                }
                self.imageView.isHidden = false
                self.applyFallbackTransform()
                self.window.alphaValue = 1
                self.window.orderFrontRegardless()
                self.visible = true
                self.captureTask = nil
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.content = nil
                self.cancel()
                // PlaneError covers our own recoverable cases, such as the
                // display changing mid-capture. Anything else came out of
                // ScreenCaptureKit and almost always means the grant is
                // missing or no longer matches this build's signature.
                if error is PlaneError {
                    self.onError?("Capture unavailable: \(error.localizedDescription)")
                } else {
                    self.onCaptureRefused?(error.localizedDescription)
                }
            }
        }
    }

    func finish() {
        active = false
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        guard visible else { cancel(); return }
        // The fade rides the same display link as the easing, so the image keeps
        // settling toward its final angle while it dissolves instead of freezing
        // mid-motion.
        fadeStart = CACurrentMediaTime()
        resumeTicking()
        // Dispatch work runs in every run loop mode, so this is the backstop
        // that guarantees teardown even if the fade timer never fires.
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.visible else { return }
                self.cancel()
            }
        }
    }

    func cancel() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        stopTicking()
        active = false
        visible = false
        window.orderOut(nil)
        window.alphaValue = 0
        imageView.image = nil
        imageView.isHidden = true
        for view in blurViews {
            view.image = nil
            view.isHidden = true
        }
        panelView.layer?.transform = CATransform3DIdentity
        visibleDelta = 0
    }

    /// Starts, or wakes, the render loop.
    private func resumeTicking() {
        if let link = displayLink {
            if link.isPaused { lastTick = 0; link.isPaused = false }
            return
        }
        let link = stageView.displayLink(target: self, selector: #selector(tick))
        // Must survive menu tracking and drags, like every other timed path here.
        link.add(to: .main, forMode: .common)
        lastTick = 0
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
        lastTick = 0
        fadeStart = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // A long gap means the loop was starved; clamp so it never lurches.
        let dt = lastTick == 0 ? 1.0 / 60.0 : min(now - lastTick, 0.1)
        lastTick = now

        let remaining = delta - visibleDelta
        var moved = false
        if abs(remaining) > Self.settleEpsilon {
            // Frame-rate independent exponential ease, so the motion is identical
            // on 60 Hz and 120 Hz panels.
            visibleDelta += remaining * (1 - exp(-dt / Self.smoothingTau))
            moved = true
        } else if visibleDelta != delta {
            visibleDelta = delta
            moved = true
        }
        if moved { applyFallbackTransform() }

        if let start = fadeStart {
            let progress = min(1, (now - start) / Self.fadeSeconds)
            window.alphaValue = 1 - progress
            if progress >= 1 { cancel() }
            return
        }

        // Nothing left to animate; idle rather than burning a frame callback.
        if !moved { link.isPaused = true }
    }

    private func applyFallbackTransform() {
        guard stageView.bounds.width > 0, stageView.bounds.height > 0 else { return }
        // Every gradient below is rewritten every frame. Implicit CALayer
        // animations would each start a quarter-second interpolation, so the
        // blur bands would lag behind the panel they are supposed to be glued
        // to. Disable actions for the whole update.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Mask layers do not follow an NSView's autoresizing. Keep their
        // geometry in sync so the bands always line up with the screenshot.
        panelView.frame = stageView.bounds
        edgeDissolveLayer.frame = panelView.bounds
        for mask in blurMasks { mask.frame = panelView.bounds }
        sideFadeLayer.frame = stageView.bounds

        // `visibleDelta` is the eased calibrated visual range (±200°). Compress
        // it into a bounded physical-looking bend, bottom edge fixed.
        let progress = max(-1.0, min(1.0, visibleDelta / 200.0))
        // A full visual range bends by about 36°. This keeps a small physical
        // adjustment from reading like a near-closed lid.
        let radians = CGFloat(progress) * (.pi * 0.20)
        if let layer = panelView.layer {
            // Anchor at the hinge, then use perspective so the top narrows as
            // it recedes. The bottom edge never translates or scales.
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.0)
            layer.position = CGPoint(x: stageView.bounds.midX, y: 0.0)
            var transform = CATransform3DIdentity
            transform.m34 = -1.0 / 1700.0
            layer.transform = CATransform3DRotate(transform, radians, 1, 0, 0)
        }

        let amount = CGFloat(abs(progress))
        // Reveal each blur level from the moving edge downward. The gentlest
        // radius reaches furthest toward the hinge and the strongest stays
        // near the edge, so the stack reads as one continuous falloff.
        // Negative progress is the lid closing toward the keyboard. That
        // direction defocuses harder: the ladder ramps in sooner and the
        // deepest radius is only ever used here. Closing also measures its
        // progress against ±90 rather than the full ±200 visual range, so the
        // entire blur ramp lands inside the travel that is actually visible.
        let closing = progress < 0
        let blurAmount = closing
            ? CGFloat(min(1.0, abs(visibleDelta) / Self.closingBlurFullScale))
            : amount
        for (level, mask) in blurMasks.enumerated() {
            let usable = level != Self.closingOnlyLevel || closing
            let reach = usable ? blurAmount * (0.95 - 0.19 * CGFloat(level)) : 0
            let start = max(0.0, 1.0 - reach)
            let soft = min(0.22, max(0.06, reach * 0.5))
            // At rest the ramp collapses onto the top edge, which would leave
            // a hairline of the blurred copy showing. Switch the level off.
            blurViews[level].layer?.opacity = reach > 0.002 ? 1 : 0
            mask.colors = [
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
                NSColor.white.cgColor
            ]
            mask.locations = [
                0.0,
                NSNumber(value: Double(start)),
                NSNumber(value: Double(min(1.0, start + soft)))
            ]
        }

        // Fade the panel's own alpha toward the moving edge. Because the
        // window behind it is black, the screenshot dissolves into the
        // background instead of ending on a hard rectangular line. The hinge
        // end also dims slightly so the whole panel reads as receding.
        let hingeAlpha = 1.0 - amount * 0.12
        // The ramp covers at most the moving 60% of the panel. Spanning the
        // whole panel dimmed the middle so heavily that the hinge end stopped
        // reading as the sharp, fixed side.
        let dissolveStart = max(0.0, 1.0 - amount * 0.6)
        edgeDissolveLayer.colors = [
            NSColor.white.withAlphaComponent(hingeAlpha).cgColor,
            NSColor.white.withAlphaComponent(hingeAlpha).cgColor,
            NSColor.clear.cgColor
        ]
        edgeDissolveLayer.locations = [
            0.0,
            NSNumber(value: Double(dissolveStart)),
            1.0
        ]

        let sideFade = min(0.72, amount * 0.85)
        sideFadeLayer.colors = [
            NSColor.black.withAlphaComponent(sideFade).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(sideFade).cgColor
        ]
    }

    private func makeBlurredImage(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        // A gaussian is low-frequency, so the wide radii are rendered at
        // reduced resolution and scaled back up by the image view. Without
        // this the 120px level alone costs more than the rest of the gesture.
        let scale = min(1.0, 22.0 / max(radius, 1.0))
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        // Clamping first stops the gaussian from pulling transparent black in
        // from outside the frame, which left a dark rim on all four sides.
        filter.setValue(scaled.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius * scale, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: scaled.extent)
    }
}
