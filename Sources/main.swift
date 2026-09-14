import AppKit

if CommandLine.arguments.contains("--probe") {
    let sensor = LidSensor()
    var readings = 0
    sensor.onStatus = { print($0) }
    sensor.onSample = { angle, _ in
        if readings < 3 { print("Lid angle: \(angle)°") }
        readings += 1
    }
    sensor.start()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    sensor.stop()
    print("Valid samples: \(readings)")
    exit(readings > 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--calibrate") {
    let sensor = LidSensor()
    var minimum = Double.greatestFiniteMagnitude
    var maximum = -Double.greatestFiniteMagnitude
    var readings = 0
    sensor.onStatus = { print($0) }
    sensor.onSample = { angle, _ in
        minimum = min(minimum, angle)
        maximum = max(maximum, angle)
        readings += 1
    }
    print("Calibration runs for 15 seconds. Slowly move the lid through its normal full range, then leave it open.")
    sensor.start()
    RunLoop.main.run(until: Date().addingTimeInterval(15.0))
    sensor.stop()
    guard readings > 0 else {
        print("No sensor readings received.")
        exit(1)
    }
    print(String(format: "Observed sensor range: %.2f° through %.2f° (%d samples)", minimum, maximum, readings))
    print("This is a raw sensor reading only. The in-app walkthrough is what calibrates the effect.")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
