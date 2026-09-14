import Foundation
import IOKit
import IOKit.hid
import QuartzCore

/// Blocking HID reads never run on the app's main thread.
final class LidSensor {
    var onSample: ((Double, CFTimeInterval) -> Void)?
    var onStatus: ((String) -> Void)?
    private let queue = DispatchQueue(label: "local.lidplane.sensor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var failures = 0
    private var lastRetry: CFTimeInterval = 0

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.connect()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.read() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.disconnect()
        }
    }

    private func status(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(value) }
    }

    private func disconnect() {
        if let device { IOHIDDeviceClose(device, 0) }
        if let manager { IOHIDManagerClose(manager, 0) }
        device = nil
        manager = nil
    }

    private func connect() {
        disconnect()
        lastRetry = CACurrentMediaTime()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
            status("Cannot open the lid sensor")
            return
        }
        self.manager = manager
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }
            if Self.readAngle(candidate) != nil {
                device = candidate
                failures = 0
                status("Lid sensor connected")
                return
            }
            IOHIDDeviceClose(candidate, 0)
        }
        status("No readable continuous lid sensor")
    }

    private static func readAngle(_ device: IOHIDDevice) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 8)
        var size = bytes.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &size) == kIOReturnSuccess,
              size >= 3 else { return nil }
        let angle = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        return (0...180).contains(angle) ? angle : nil
    }

    private func read() {
        guard let device else {
            if CACurrentMediaTime() - lastRetry > 3 { connect() }
            return
        }
        guard let angle = Self.readAngle(device) else {
            failures += 1
            if failures >= 15 {
                disconnect()
                status("Lid sensor interrupted; reconnecting")
            }
            return
        }
        failures = 0
        let timestamp = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in self?.onSample?(angle, timestamp) }
    }
}
