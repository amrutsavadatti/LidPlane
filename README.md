# LidPlane — local prototype

A native macOS menu-bar app for Amrut's M4 MacBook Air (macOS Tahoe 26.3).
Written independently in Swift, AppKit, ScreenCaptureKit, and Metal. No third-party dependencies.

## Run

```sh
bash build.sh
open build/LidPlane.app
```

In the app, choose **Allow Screen Recording…** and grant the macOS permission.
Return to the app, choose **Refresh**, then enable **Respond to lid movement**.
If macOS requests a relaunch, quit and reopen the app. Local ad-hoc signing can
require renewed permission after rebuilding the executable.

The app starts with the physical effect disabled. Closing its settings leaves
the menu-bar app running. Reopen controls from its angle indicator, or relaunch
the app. **Stop Effect** cancels the current gesture/preview. Escape also stops
a preview while LidPlane's window is focused; it is not a global keyboard hook.

## Behavior

- A movement's starting angle is its reference, with no fixed 90° threshold.
- A fresh screenshot is requested at gesture activation and held in memory.
- Current angle minus reference angle controls the signed perspective transform.
- The screenshot represents the original screen plane; the renderer intersects
  a virtual viewer's rays through the current screen with that original plane.
- 90° → 120° means +30°; 120° → 10° means −110°. Reversal retains the original reference.
- A 1.25° activation deadband filters one-degree sensor jitter. Slow movement accumulates.
- After 200 ms without meaningful movement, the image crossfades out over 140 ms.
- The settled position becomes the next gesture's reference. Its screenshot is fresh.
- Screen sleep, session changes, screen-lock notifications, display reconfiguration,
  or a stalled sensor cancel pending captures and remove the overlay.
- Only the awake built-in display is used. Capture failures leave the live desktop visible.
- Screenshots are never written to disk, uploaded, or reused across gestures.

## Controls

- Enable/pause physical gestures from the menu or settings.
- **Play Preview** demonstrates both signed directions with one frozen screenshot.
- The slider previews −110° through +60°. Settings stay above the preview so controls remain usable.
- **Fold and Sleep** runs an explicitly selected timed closing effect, then asks macOS to sleep.
  It is never triggered automatically by lid movement.
- Menu keyboard equivalents work when LidPlane is active; no system-wide shortcuts are registered.

## Implementation boundaries to validate on hardware

- Perspective uses a fixed virtual eye, not actual eye/head tracking. It is a visual
  approximation. At extreme angles the original plane can become edge-on or lie
  outside the projected view; the renderer clamps those samples and adds edge shading
  so an out-of-range projection cannot turn the whole overlay black. The extreme-angle
  aesthetic still needs tuning.
- The current visible prototype uses the calibrated 0°–128° sensor range and maps each
  gesture's remaining physical travel into a ±200° visual range. Its image-backed stage
  pivots at the bottom hinge; the top recedes through perspective while a blurred copy
  and black radial edge fade fill the displaced area.
- First-frame capture is asynchronous. Short/fast gestures may end before capture
  is ready, in which case no overlay is shown. The app never fills the delay with an old screenshot.
  A short-lived prewarmed capture stream is a future latency improvement, not implemented here.
- Sensor polling is 60 Hz on a dedicated queue. Rendering follows the built-in
  display's advertised refresh rate, up to 120 Hz, and stops when hidden. Adaptive
  idle polling and speed-based preparation remain future optimizations.
- SDR/sRGB capture is used. HDR/wide-gamut parity is not claimed.
- This prototype listens for macOS distributed lock/unlock notifications plus a
  supplemental session dictionary flag. These lock-specific signals are undocumented;
  there is no SkyLight/private window-server overlay. Lock/sleep cancellation needs
  direct verification on Tahoe before broader distribution.
- Typing/click-to-dismiss was not agreed yet. The overlay is currently click-through;
  avoid interacting with underlying controls while evaluating a frozen image.
- No launch-at-login, updater, installer, App Store submission, or notarization is included.

## Checks

```sh
bash test.sh
build/LidPlane.app/Contents/MacOS/LidPlane --probe
build/LidPlane.app/Contents/MacOS/LidPlane --calibrate
build/LidPlane.app/Contents/MacOS/LidPlane --validate-renderer
```

The motion tests cover reference angles, signed deltas, reversals, the stillness
timeout, new gestures, slow movement, jitter, and invalid readings. The probe
checks actual HID readings without screen capture. The renderer check compiles
the Metal shader at runtime, so full Xcode / the standalone Metal compiler is not required.
`--calibrate` records the actual minimum and maximum values observed while you
move the lid through its normal range; the animation should normalize against
those device-specific endpoints rather than a hardcoded 200° assumption.

Manual acceptance: adjust in each direction; close farther; reverse before stopping;
hold still; start a second gesture; switch to an external display; lock/sleep during
an effect; revoke capture permission. Judge perspective anchoring and latency visually.
Do not treat the existence of sensor hardware as proof these behaviors have passed.
