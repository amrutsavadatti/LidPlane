# LidPlane

Your screen folds away with the lid, and comes back when you stop.

LidPlane is a small macOS menu-bar app. When you move your MacBook's lid it
freezes the display, tilts that frozen image back from the hinge, and softens
its far edge into nothing — then returns you to the live desktop the moment you
stop moving.

**[Download the latest release →](https://github.com/amrutsavadatti/LidPlane/releases)**

Requires macOS 14 or later on an Apple Silicon MacBook. It reads the built-in
lid-angle sensor, so it does nothing on a desktop Mac.

## Installing

LidPlane is signed, but not notarized by Apple — notarization requires a paid
developer account. macOS therefore blocks it on first launch, and you have to
allow it once by hand:

1. Open the disk image and drag LidPlane to Applications.
2. Open it. macOS refuses, saying it cannot verify the developer. Click
   **Done** — never "Move to Trash".
3. Open **System Settings → Privacy & Security**, scroll to the bottom, and
   click **Open Anyway** beside the message about LidPlane.
4. Open it once more and choose **Open**. That is the last time you will see any
   of this.

## Using it

There is no window and no Dock icon. LidPlane lives in the menu bar.

- **Click** the icon for a switch that turns the effect on and off. The icon
  dims while it is off.
- **Right-click** for **Calibrate Lid…** and **Quit**.
- **Escape** cancels an effect in flight.

On first launch it asks for Screen Recording permission, then measures your
hinge. That takes about a minute and is described below.

## Privacy

LidPlane captures your display in order to animate it. Those captures are held
in memory, used for one movement of the lid, and discarded when the effect ends.

Nothing is written to disk. Nothing is uploaded. There is no network code in the
binary at all — `otool -L` shows AppKit, CoreImage, IOKit and ScreenCaptureKit,
and no CFNetwork or Network.framework. No analytics, no accounts.

---

# Building from source

```sh
./setup-dev.sh     # once
bash build.sh
open build/LidPlane.app
```

## Why setup-dev.sh exists

An ad-hoc signature (`codesign --sign -`) makes the app's designated requirement
its own `cdhash`:

```
designated => cdhash H"ae713aa0..."
```

TCC keys the Screen Recording grant to that, so **every rebuild is a different
app as far as macOS is concerned** and the grant stops matching. The symptom is
a permission prompt on every single lid movement.

`setup-dev.sh` walks you through creating a self-signed code-signing
certificate. The requirement then becomes:

```
designated => identifier "com.amrutsavadatti.LidPlane" and certificate leaf = H"..."
```

which survives rebuilds, so you approve the permission once. No Apple Developer
Program is involved.

Two traps, both of which cost real time to find:

- **A self-signed certificate is untrusted, and that is fine.**
  `security find-identity -v` filters to identities with a trusted chain and
  will not list it, but `codesign` signs with it perfectly well. Using `-v` in a
  detection check silently falls back to ad-hoc and undoes the whole fix.
- **Certificate Assistant, not openssl.** An openssl-generated key imports
  without a codesign ACL, so `codesign` blocks on a keychain dialog that no
  script can answer.

The certificate expires after a year. When it does, create a fresh one, re-run
`setup-dev.sh`, and re-grant Screen Recording once.

## Layout

```
Sources/
  main.swift          entry point, plus --probe and --calibrate diagnostics
  AppDelegate.swift   the menu-bar item, popover and right-click menu
  Coordinator.swift   owns the sensor, lifecycle, and angle→visual mapping
  LidSensor.swift     IOKit HID reader for the lid-angle sensor, 60 Hz
  Motion.swift        one gesture's state machine: reference, deadband, stillness
  Overlay.swift       capture, the full-screen window, and the effect itself
  SetupWindow.swift   first-run walkthrough
  Calibration.swift   measured hinge angles, persisted as JSON
Tools/                DMG background generator
Tests/MotionTests.swift
build.sh  test.sh  setup-dev.sh  package.sh
```

## How the effect works

The overlay is AppKit layers, not Metal. A `panelView` carries a hinge-anchored
`CATransform3D` rotation with perspective, and everything that must stay glued
to the screen lives inside it.

**Progressive blur.** Five copies of the screenshot at 10/26/58/120/200px,
stacked sharp-to-blurriest, each revealed by its own vertical gradient mask. The
gentlest radius reaches furthest toward the hinge and the strongest stays near
the moving edge, so sharpness falls off in stages. A single blurred copy
cross-faded against the sharp one — the obvious approach — reads as a flat
translucent sheet laid over the screenshot.

Two details matter: the gaussian is clamped to the image extent first, or it
pulls transparent black in from outside the frame and leaves a dark rim on all
four sides; and the wide radii render downscaled, because a gaussian is
low-frequency and the 200px level at full resolution costs more than the rest of
the gesture.

**The moving edge.** A mask on the panel itself, opaque at the hinge and
transparent at the moving edge. Because it is inside the transform it tracks the
image's real top edge, and alpha reaching zero reveals the black window, so the
edge melts instead of ending on a rectangular line. A stage-space gradient
cannot do this — it can never line up with where the panel actually ends.

**Direction.** Closing defocuses harder than opening: a closing-only 200px level,
and blur progress measured against 90 visual degrees rather than the full 200,
so the whole ramp lands inside the travel that is actually visible. The
perspective transform stays symmetric.

All per-sample updates run inside a `CATransaction` with actions disabled.
Every gradient is rewritten at sensor rate, and each implicit CALayer animation
would otherwise start a quarter-second interpolation, leaving the blur bands
lagging the panel they are glued to.

## Calibration

Two angles differ per machine, measured once by the walkthrough and stored in
`~/Library/Application Support/LidPlane/config.json`:

- **Maximum open angle** — how far back the lid physically travels.
- **Visual cutoff angle** — where the screen stops being visible to the eye.
  This lands well above 0°; driving the effect below it spends most of the
  animation on travel nobody can see.

The cutoff only remaps the physical endpoints. The ±200° visual range is an
artistic constant, so calibration changes *when* the effect happens rather than
*how* it looks, and the blur tuning holds on every machine.

The cutoff is measured by filling the screen with one line of large text and
asking the user to press Space when they can no longer read it. Space rather
than a click, because you cannot aim a pointer at a screen you can no longer
see.

## Checks

```sh
bash test.sh                                       # motion state machine
build/LidPlane.app/Contents/MacOS/LidPlane --probe # raw HID readings
build/LidPlane.app/Contents/MacOS/LidPlane --calibrate
```

The motion tests cover reference angles, signed deltas, reversals, the stillness
timeout, new gestures, slow movement, jitter and invalid readings. `--probe`
checks the sensor without touching screen capture. `--calibrate` logs the raw
angle range and writes no configuration — the in-app walkthrough is what
calibrates the effect.

Everything visual has to be judged on hardware. There is no automated coverage
of the animation.

## Packaging

```sh
bash package.sh
```

Builds, refuses to continue if the app is ad-hoc signed, stages a disk image
with a drag-install symlink and a Finder-styled window, and writes
`dist/LidPlane-<version>.dmg`.

If a `Website/` directory is present — or `LIDPLANE_SITE_DIR` points at one — it
also copies the image there and rewrites the download link, version, size and
SHA-256 in `index.html`. A stale checksum on a page whose job is convincing
people an unsigned-looking app is safe is worse than having none at all, so
those are generated rather than typed.

## Known limitations

- The perspective uses a fixed virtual eye, not head tracking. It is an
  approximation, and the extreme-angle aesthetic still needs work.
- First-frame capture is asynchronous, so a very short flick can end before the
  capture lands. Nothing is shown in that case rather than a late flash.
- SDR/sRGB capture only. No HDR or wide-gamut parity is claimed.
- Lock and sleep cancellation leans on distributed notifications that Apple does
  not document. It works, but it is not a contract.
- The overlay is click-through, so avoid interacting with what is underneath
  while a frozen image is on screen.
- No launch-at-login, updater, or notarization.

## Licence

[MIT](LICENSE). A hobby project, shared as-is — no warranty, and no liability
for how it behaves on your machine. Fork it and improve it.
