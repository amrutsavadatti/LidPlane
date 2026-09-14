import AppKit
import CoreImage
import ScreenCaptureKit

@MainActor
final class Overlay {
    let renderer: PlaneRenderer
    private let window: NSWindow
    private let stageView: NSView
    private let blurView: NSImageView
    private let imageView: NSImageView
    private let edgeFadeLayer: CAGradientLayer
    private let sideFadeLayer: CAGradientLayer
    private let sharpMaskLayer: CAGradientLayer
    private var generation = 0
    private var captureTask: Task<Void, Never>?
    private var fadeTimer: Timer?
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    var onError: ((String) -> Void)?
    private(set) var active = false
    private(set) var visible = false
    var delta: Double = 0 {
        didSet {
            renderer.targetDelta = delta
            applyFallbackTransform()
            updateMotionBlur()
        }
    }

    static var builtInScreen: NSScreen? {
        NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsAsleep(id) == 0
        }
    }

    init() throws {
        renderer = try PlaneRenderer(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
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

        blurView = NSImageView(frame: .zero)
        blurView.imageScaling = .scaleAxesIndependently
        blurView.imageAlignment = .alignCenter
        blurView.wantsLayer = true
        blurView.autoresizingMask = [.width, .height]
        blurView.alphaValue = 0.96

        imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.autoresizingMask = [.width, .height]
        imageView.isHidden = true

        sharpMaskLayer = CAGradientLayer()
        sharpMaskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        sharpMaskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        sharpMaskLayer.frame = imageView.bounds
        sharpMaskLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageView.layer?.mask = sharpMaskLayer

        // The fade follows the lid motion: black grows down from the top.
        // A radial mask made the bottom look like a dark circular vignette.
        edgeFadeLayer = CAGradientLayer()
        edgeFadeLayer.type = .axial
        edgeFadeLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.92).cgColor
        ]
        edgeFadeLayer.locations = [0.0, 0.52, 1.0]
        edgeFadeLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        edgeFadeLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        edgeFadeLayer.frame = stageView.bounds
        edgeFadeLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

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
        // Keep the native Metal view available for later GPU validation, but
        // use the image-backed path for the visible prototype. This guarantees
        // a capture cannot be replaced by a black CAMetalLayer while we tune
        // the projection math on real hardware.
        renderer.view.isHidden = true
        stageView.addSubview(blurView)
        stageView.addSubview(imageView)
        stageView.layer?.addSublayer(edgeFadeLayer)
        stageView.layer?.addSublayer(sideFadeLayer)
        window.contentView = stageView
    }

    func invalidateDisplay() {
        content = nil
        contentDate = .distantPast
        cancel()
    }

    func begin(delta: Double) {
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
        self.delta = delta
        let token = generation
        // Establish the destination before capturing; never fall back to an external display.
        window.setFrame(screen.frame, display: false)
        let width = Int(screen.frame.width * screen.backingScaleFactor)
        let height = Int(screen.frame.height * screen.backingScaleFactor)
        let fps = screen.maximumFramesPerSecond
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
                #if RENDER_TEST
                RenderDiagnostics.inspect(image, renderer: self.renderer)
                #endif
                let captured = NSImage(cgImage: image, size: NSSize(width: screen.frame.width, height: screen.frame.height))
                self.imageView.image = captured
                if let blurred = self.makeBlurredImage(image, radius: 24.0) {
                    self.blurView.image = NSImage(cgImage: blurred, size: NSSize(width: screen.frame.width, height: screen.frame.height))
                } else {
                    self.blurView.image = captured
                }
                self.imageView.isHidden = false
                self.applyFallbackTransform()
                try self.renderer.install(image, delta: self.delta, fps: fps)
                self.window.alphaValue = 1
                self.window.orderFrontRegardless()
                self.visible = true
                self.captureTask = nil
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.content = nil
                self.cancel()
                self.onError?("Capture unavailable: \(error.localizedDescription)")
            }
        }
    }

    func finish() {
        active = false
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        guard visible else { cancel(); return }
        let start = CACurrentMediaTime()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (CACurrentMediaTime() - start) / 0.14)
                self.window.alphaValue = 1 - progress
                if progress >= 1 { self.cancel() }
            }
        }
    }

    func cancel() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        active = false
        visible = false
        window.orderOut(nil)
        window.alphaValue = 0
        imageView.image = nil
        imageView.isHidden = true
        blurView.image = nil
        blurView.layer?.filters = nil
        imageView.layer?.transform = CATransform3DIdentity
        imageView.layer?.mask = sharpMaskLayer
        renderer.clear()
    }

    private func applyFallbackTransform() {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
        // Mask layers do not reliably follow an NSView's autoresizing. Keep
        // their geometry in sync so the top fade always covers the screenshot.
        sharpMaskLayer.frame = imageView.bounds
        edgeFadeLayer.frame = stageView.bounds
        sideFadeLayer.frame = stageView.bounds
        // `delta` is the calibrated visual range (±200°). Compress it into a
        // bounded physical-looking bend while keeping the bottom edge fixed.
        let progress = max(-1.0, min(1.0, delta / 200.0))
        // A full visual range bends by about 36°. This keeps a small physical
        // adjustment from reading like a near-closed lid.
        let radians = CGFloat(progress) * (.pi * 0.20)
        for layer in [imageView.layer, blurView.layer].compactMap({ $0 }) {
            // Anchor at the hinge, then use perspective so the top narrows as
            // it recedes. The bottom edge never translates or scales.
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.0)
            layer.position = CGPoint(x: stageView.bounds.midX, y: 0.0)
            var transform = CATransform3DIdentity
            transform.m34 = -1.0 / 1700.0
            layer.transform = CATransform3DRotate(transform, radians, 1, 0, 0)
        }
        let amount = CGFloat(abs(progress))
        // Keep the hinge end sharp and dissolve the moving top into the
        // pre-blurred copy. At full travel the top of the sharp image is gone.
        let topSharpness = max(0.0, 1.0 - amount * 1.55)
        sharpMaskLayer.colors = [
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(min(1.0, topSharpness + 0.12)).cgColor,
            NSColor.white.withAlphaComponent(topSharpness).cgColor
        ]
        sharpMaskLayer.locations = [0.0, 0.48, 1.0]

        let fade = min(0.92, amount * 1.15)
        edgeFadeLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(fade).cgColor
        ]
        let sideFade = min(0.72, amount * 0.85)
        sideFadeLayer.colors = [
            NSColor.black.withAlphaComponent(sideFade).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(sideFade).cgColor
        ]
    }

    private func updateMotionBlur() {
        // The blurred copy is precomputed once per screenshot. Modulating its
        // opacity keeps the center readable while the moving edge fogs out.
        let amount = min(1.0, abs(delta) / 200.0)
        blurView.alphaValue = 0.35 + amount * 0.65
    }

    private func makeBlurredImage(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: nil).createCGImage(output, from: input.extent)
    }
}
