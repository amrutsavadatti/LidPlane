# LidPlane — local prototype

A native macOS menu-bar app for Amrut's M4 MacBook Air (macOS Tahoe 26.3).
Written independently in Swift, AppKit, ScreenCaptureKit, and Metal. No third-party dependencies.

## First-time setup

```sh
./setup-dev.sh
```

Run this once before anything else. It walks you through creating a self-signed
code-signing certificate, then rebuilds, verifies the signature, and clears any
stale Screen Recording grant.

It matters more than it sounds. An ad-hoc signature (`codesign --sign -`) makes
the app's designated requirement its own `cdhash`, so **every rebuild is a
different app as far as TCC is concerned** and the Screen Recording grant stops
matching. The symptom is a permission prompt on every single lid movement. With
a stable certificate the requirement becomes:

```
identifier "com.amrutsavadatti.LidPlane" and certificate leaf = H"…"
```

which survives rebuilds, so you approve the permission once.

No Apple Developer Program is involved. A self-signed certificate is untrusted —
`security find-identity -v` will not list it — but `codesign` signs with it
perfectly well. Only Gatekeeper cares about trust, and Gatekeeper is not
involved in a locally built app.

On the first build after creating the certificate, macOS asks permission to use
the signing key. Choose **Always Allow**; later builds are then silent.

### The certificate expires after one year

Certificate Assistant defaults to a one-year validity, and `setup-dev.sh` does
not override it. When it lapses, `build.sh` fails to sign and the Screen
Recording grant stops matching again, since the certificate leaf in the
designated requirement no longer exists.

The fix is to repeat the setup: create a fresh certificate with the same name,
re-run `./setup-dev.sh`, and re-grant Screen Recording once. To avoid it
entirely, tick **Let me override defaults** in Certificate Assistant and set the
validity to something like 3650 days — it adds several wizard pages, which is
why it is not the default advice here.

The same applies to any release signed with that certificate: re-signing
releases with a *different* certificate forces every user to re-grant Screen
Recording, so keep one certificate for as long as possible.

## Run

```sh
bash build.sh
open build/LidPlane.app
```

`build.sh` resolves a signing identity in this order: the
`LIDPLANE_SIGN_IDENTITY` environment variable, then the `.signing-identity` file
written by `setup-dev.sh`, then ad-hoc. It prints a warning whenever it falls
back to ad-hoc.

The app has no Dock icon and no window. Everything lives in the menu bar:

- **Left click** the icon for a popover with a single switch, plus the
  calibrated lid range. The icon dims while the effect is off.
- **Right click** for **Calibrate Lid…** and **Quit**. An `LSUIElement` app has
  no Dock icon or app menu, so this is the only way to quit.
- **Escape** cancels an effect in flight.

On first launch it opens the setup walkthrough instead: Screen Recording,
maximum open angle, visual cutoff angle, done. The switch position and the
calibration are remembered between launches.

If Screen Recording is refused, the effect switches itself off and the popover
shows a warning row. This is deliberate — leaving it armed means another system
permission prompt on every lid movement.

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

## Calibration

The hinge endpoints are measured per machine by the setup walkthrough and stored
in `~/Library/Application Support/LidPlane/config.json`:

- **Maximum open angle** — how far back the lid physically travels.
- **Visual cutoff angle** — where the screen stops being visible to the eye.
  This lands well above 0°, and driving the effect below it would spend most of
  the animation on travel nobody can see.

The cutoff only remaps the physical endpoints. The ±200° visual range stays an
artistic constant, so calibration changes *when* the effect happens rather than
*how* it looks, and the blur tuning holds on every machine.

Delete that file to get the walkthrough back, or use **Calibrate Lid…** from the
menu bar. There is no preview or slider; the lid is the only input.

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
`--calibrate` is a raw diagnostic that logs the minimum and maximum angles seen
over fifteen seconds. It does not write any configuration — the in-app
walkthrough is what actually calibrates the effect. Use this only to check what
the sensor reports.

Manual acceptance: adjust in each direction; close farther; reverse before stopping;
hold still; start a second gesture; switch to an external display; lock/sleep during
an effect; revoke capture permission. Judge perspective anchoring and latency visually.
Do not treat the existence of sensor hardware as proof these behaviors have passed.
