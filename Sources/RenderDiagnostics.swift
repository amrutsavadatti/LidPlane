#if RENDER_TEST
import AppKit
import MetalKit

/// Opt-in diagnostic builds record numeric evidence only, never screenshot files.
enum RenderDiagnostics {
    private static let lock = NSLock()
    private static let url = URL(fileURLWithPath: "/private/tmp/lidplane-render-diagnostic.log")
    static func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let data = ("[render-check] \(message)\n").data(using: .utf8)!
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func inspect(_ image: CGImage, renderer: PlaneRenderer) {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0,y: 0,width: 8,height: 8))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let colors = (0..<64).flatMap { i in [Int(bytes[i*4]),Int(bytes[i*4+1]),Int(bytes[i*4+2])] }
        record("capture=\(image.width)x\(image.height), RGB mean=\(colors.reduce(0,+)/colors.count), max=\(colors.max()!), view=\(renderer.view.frame), drawable=\(renderer.view.drawableSize)")
        renderer.view.framebufferOnly = false
        var remaining = 3
        renderer.frameProbe = { texture, command in
            guard remaining > 0 else { return }
            remaining -= 1
            let buffer = texture.device.makeBuffer(length: 9 * 256, options: .storageModeShared)!
            let blit = command.makeBlitCommandEncoder()!
            for i in 0..<9 {
                let x = texture.width * (1 + i % 3) / 4
                let y = texture.height * (1 + i / 3) / 4
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: x,y: y,z: 0), sourceSize: MTLSize(width: 1,height: 1,depth: 1),
                    to: buffer, destinationOffset: i * 256, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            }
            blit.endEncoding()
            let delta = renderer.targetDelta
            command.addCompletedHandler { command in
                let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
                let values = (0..<9).flatMap { i in [Int(bytes[i*256]),Int(bytes[i*256+1]),Int(bytes[i*256+2])] }
                record("output delta=\(delta), mean=\(values.reduce(0,+)/values.count), max=\(values.max()!), error=\(String(describing: command.error))")
            }
        }
    }
}
#endif
