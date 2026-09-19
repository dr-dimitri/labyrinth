import Foundation
import CoreGraphics
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import BlacksiteMac

/// Opt in on a real Metal device. CPU decoding alone cannot catch a texture
/// uploader misinterpreting ImageIO's noneSkipFirst thumbnail byte layout.
struct NativeTextureUploadTests {
    private struct Upload {
        let texture: MTLTexture
        let top: [UInt8]
        let bottom: [UInt8]
        let origin: NativeTextureOrigin
        let srgb: Bool
        let diagnostic: String
    }

    private func opaquePattern(top: [UInt8], bottom: [UInt8]) throws -> Data {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let color = y < height / 2 ? top : bottom
            for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = color[channel] }
        } }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        // An opaque RGB source follows the same ImageIO thumbnail path as the
        // actual landscape JPEGs and original SWAT RGB PNGs.
        let bitmap = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmap,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixels(texture: MTLTexture, queue: MTLCommandQueue, level: Int = 0) throws -> (top: [UInt8], bottom: [UInt8]) {
        let supported: Set<MTLPixelFormat> = [.rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb]
        try #require(supported.contains(texture.pixelFormat), "Regression fixture needs an eight-bit RGBA/BGRA texture.")
        let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
        let bytesPerRow = ((width * 4 + 255) / 256) * 256
        let buffer = try #require(texture.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeBlitCommandEncoder())
        encoder.copy(from: texture, sourceSlice: 0, sourceLevel: level,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        #expect(command.status == .completed)
        func pixel(y: Int) -> [UInt8] {
            let start = buffer.contents().assumingMemoryBound(to: UInt8.self) + y * bytesPerRow + (width / 2) * 4
            var result = Array(UnsafeBufferPointer(start: start, count: 4))
            if texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb { result.swapAt(0, 2) }
            return result
        }
        return (pixel(y: height / 4), pixel(y: height * 3 / 4))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLACKSITE_TEST_METAL_TEXTURES"] == "1"))
    func consecutiveColorAndNormalUploadsKeepChannelsAlphaAndOrigins() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        // Dark clothing, a tangent normal and a warm metal color have different
        // RGB channels. A cyclic channel shift cannot accidentally pass.
        let patterns: [(top: [UInt8], bottom: [UInt8], srgb: Bool)] = [
            ([17, 43, 83], [93, 27, 11], true),
            ([128, 150, 247], [99, 114, 238], false),
            ([207, 159, 65], [73, 121, 181], true),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blacksite-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for profile in NativeTextureProfile.allCases {
            let loader = NativeTextureLoader(device: device, profile: profile)
            var uploads: [Upload] = []
            for repetition in 0..<3 { for (index, pattern) in patterns.enumerated() {
                let data = try opaquePattern(top: pattern.top, bottom: pattern.bottom)
                let url = directory.appendingPathComponent("\(repetition)-\(index).png")
                try data.write(to: url)
                for origin in [NativeTextureOrigin.topLeft, .bottomLeft] {
                    let texture = try autoreleasepool {
                        if repetition.isMultiple(of: 2) { return try loader.load(url: url, srgb: pattern.srgb, origin: origin) }
                        return try loader.load(data: data, srgb: pattern.srgb, origin: origin)
                    }
                    let diagnostic = "profile=\(profile.rawValue), repetition=\(repetition), pattern=\(index), origin=\(origin), source=\(repetition.isMultiple(of: 2) ? "url" : "data"), pixelFormat=\(texture.pixelFormat.rawValue), expectedSRGB=\(pattern.srgb)"
                    let dimension = profile == .high ? 32 : 16
                    #expect(texture.width == dimension && texture.height == dimension, "\(diagnostic)")
                    let isSRGB = texture.pixelFormat == .rgba8Unorm_srgb || texture.pixelFormat == .bgra8Unorm_srgb
                    #expect(isSRGB == pattern.srgb, "\(diagnostic)")
                    uploads.append(Upload(texture: texture, top: pattern.top, bottom: pattern.bottom, origin: origin, srgb: pattern.srgb, diagnostic: diagnostic))
                }
            } }
            // Read after every upload has finished, so later image loads must
            // not replace or corrupt earlier texture contents.
            for upload in uploads {
                let actual = try pixels(texture: upload.texture, queue: queue)
                let top = upload.origin == .topLeft ? upload.top : upload.bottom
                let bottom = upload.origin == .topLeft ? upload.bottom : upload.top
                for channel in 0..<3 {
                    #expect(abs(Int(actual.top[channel]) - Int(top[channel])) <= 3, "\(upload.diagnostic), top=\(actual.top), expected=\(top)")
                    #expect(abs(Int(actual.bottom[channel]) - Int(bottom[channel])) <= 3, "\(upload.diagnostic), bottom=\(actual.bottom), expected=\(bottom)")
                }
                #expect(actual.top[3] == 255 && actual.bottom[3] == 255, "\(upload.diagnostic), alpha=\(actual.top[3])/\(actual.bottom[3])")
                // Merely changing a linear texture's view format leaves its
                // already-generated mips wrong. Color filtering must average
                // linear light and encode the result back to sRGB; data maps
                // keep their ordinary arithmetic channel average.
                #expect(upload.texture.mipmapLevelCount > 1)
                let mip = try pixels(texture: upload.texture, queue: queue, level: upload.texture.mipmapLevelCount - 1).top
                for channel in 0..<3 {
                    let a = Double(upload.top[channel]) / 255, b = Double(upload.bottom[channel]) / 255
                    func decode(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
                    func encode(_ x: Double) -> Double { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
                    let expected = Int(((upload.srgb ? encode((decode(a) + decode(b)) / 2) : (a + b) / 2) * 255).rounded())
                    // Small tolerance covers integer mip rounding and ImageIO's
                    // antialiased half-size boundary between the two swatches.
                    #expect(abs(Int(mip[channel]) - expected) <= 4, "\(upload.diagnostic), mip=\(mip), channel=\(channel), expected=\(expected)")
                }
                #expect(mip[3] == 255, "\(upload.diagnostic), mipAlpha=\(mip[3])")
            }
        }
    }
}
