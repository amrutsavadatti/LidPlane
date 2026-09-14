# LidPlane — planned work

Two independent pieces. They can ship in either order, but (1) is what makes the
effect correct on someone else's MacBook, and (2) is what lets them get it.

---

## 1. Per-laptop hinge calibration

**Why.** `Coordinator` currently hardcodes the endpoints measured on one machine:

```swift
closedLidAngle = 0.0
openLidAngle   = 128.0
```

Every other MacBook has a different maximum hinge angle, and — more importantly —
the screen stops being readable well before the sensor reads 0°. Driving the
effect all the way to 0 spends most of the animation on travel nobody can see.

**What to build.** A guided measurement the user runs once, which records two
angles specific to their laptop:

- **Maximum open angle.** Prompt them to open the lid as far back as it goes.
  Track the running maximum from the live sensor while they do it.
- **Visual-cutoff angle.** Prompt them to close the lid slowly and signal the
  moment the screen stops being visible to their eyes. This lands somewhere
  above 0°, and it becomes the effective "closed" endpoint.

The signal has to be a key press, not a click — they cannot aim a mouse at a
screen they can no longer see. Space bar, pressed blind, while the app window
is key.

**Then.** Persist both values, have `Coordinator.scaledVisualDelta` normalize
against them instead of the constants, and offer a re-run for when the numbers
feel wrong. Ship sane fallbacks so an uncalibrated launch still works.

**Open question.** Whether the visual-cutoff angle should also shorten the
`±200°` visual range or only remap the physical endpoints.

---

## 2. Distributable app experience

**Why.** Right now the app is `bash build.sh` and an ad-hoc signature. That is a
development artifact, not something a stranger can download and trust.

**What to build.**

- **Onboarding.** A first-run flow that explains what the app does, walks
  through granting Screen Recording, runs the calibration from (1), and hands
  off to normal use. Reachable again later from the menu.
- **In-app guidance.** Enough of a "how to use" surface that the menu-bar icon
  is not the only affordance.
- **Packaging.** A `package.sh` that produces a versioned `.dmg` fit for a
  download link.

**Constraint worth knowing up front.** "Download from my website" requires more
than a build script. Gatekeeper blocks ad-hoc-signed apps downloaded from the
internet outright. To avoid that, the app needs:

1. An Apple Developer Program membership (~$99/yr).
2. A **Developer ID Application** certificate — not the ad-hoc `-` identity
   `build.sh` uses today.
3. Signing with hardened runtime enabled.
4. **Notarization** through Apple's service, then stapling the ticket to the
   `.dmg`.

I can write and test every step of that pipeline, but steps 1 and 2 require
your Apple account and cannot be done for you. Without them the honest options
are to ship unsigned and tell users to right-click → Open (which looks
sketchy and is a bad first impression), or to hold distribution until the
certificate exists.

**Open question.** Whether to also do a Sparkle-style update mechanism, or
treat this as a manually-downloaded versioned release for now.

---

## Uncommitted work currently on `master`

`Sources/Overlay.swift` and `Sources/Coordinator.swift` carry the progressive
blur ladder, the moving-edge dissolve, the directional closing blur mapped to
0…−90, and the late-capture / stranded-overlay fixes. Reviewed on hardware but
not yet committed.

The earlier Metal renderer attempt lives on the `metal-renderer-attempt`
branch, where it still reproduces the black overlay.
