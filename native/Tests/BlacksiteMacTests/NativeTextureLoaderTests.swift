import Foundation
import CoreGraphics
import ImageIO
import MetalKit
import Testing
import UniformTypeIdentifiers
@testable import BlacksiteMac

struct NativeTextureLoaderTests {
    private func source(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            // Deliberately distinct atlas regions catch a crop from the wrong
            // side or an accidental EXIF/Metal-origin flip during CPU decode.
            let color: [UInt8] = x < max(1, width / 4)
                ? (y < max(1, height / 2) ? [255,0,0,255] : [0,255,0,255]) : [0,0,255,255]
            for channel in 0..<4 { pixels[(y * width + x) * 4 + channel] = color[channel] }
        } }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let type = orientation == nil ? UTType.png.identifier : UTType.tiff.identifier
        let destination = try #require(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
        let metadata = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, metadata)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func centerPixel(_ image: CGImage) throws -> [UInt8] {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 4))
    }

    @Test func balancedHalvesPixelsBeforeTheSamePineIslandIsCropped() throws {
        let data = try source(width: 64, height: 32)
        let high = try NativeTextureLoader.decode(data: data, profile: .high)
        let balanced = try NativeTextureLoader.decode(data: data, profile: .balanced)
        #expect(high.width == 64 && high.height == 32)
        #expect(balanced.width == 32 && balanced.height == 16)
        for (profile, width, height): (NativeTextureProfile, Int, Int) in [(.high,16,16),(.balanced,8,8)] {
            let island = try NativeTextureLoader.decode(data: data, profile: profile, crop: .pineAtlasIsland)
            #expect(island.width == width && island.height == height)
            let pixel = try centerPixel(island)
            #expect(pixel[0] > 240 && pixel[1] < 15 && pixel[2] < 15 && pixel[3] == 255)
        }
    }

    @Test func urlAndEmbeddedImagesUseTheSameDimensionsAndColorSpace() throws {
        let data = try source(width: 32, height: 16)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blacksite-texture-\(UUID().uuidString).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        for profile in NativeTextureProfile.allCases {
            let file = try NativeTextureLoader.decode(url: url, profile: profile, crop: .pineAtlasIsland)
            let embedded = try NativeTextureLoader.decode(data: data, profile: profile, crop: .pineAtlasIsland)
            #expect(file.width == embedded.width && file.height == embedded.height)
            #expect(file.colorSpace?.model == .rgb && embedded.colorSpace?.model == .rgb)
            #expect(file.colorSpace?.name == embedded.colorSpace?.name)
            #expect(try centerPixel(file) == centerPixel(embedded))
        }
    }

    @Test func decodingDoesNotRotateExifImagesOrShrinkOnePixelFallbacks() throws {
        let oriented = try source(width: 32, height: 16, orientation: 6)
        let onePixel = try source(width: 1, height: 1)
        for (profile, width, height): (NativeTextureProfile, Int, Int) in [(.high,32,16),(.balanced,16,8)] {
            let image = try NativeTextureLoader.decode(data: oriented, profile: profile)
            #expect(image.width == width && image.height == height)
            let fallback = try NativeTextureLoader.decode(data: onePixel, profile: profile)
            #expect(fallback.width == 1 && fallback.height == 1)
        }
        #expect(NativeTextureProfile.balanced.maximumDimension(width: 8192, height: 4096) == 4096)
        #expect(NativeTextureProfile.balanced.maximumDimension(width: 17, height: 9) == 9)
    }

    @Test func uploadKeepsColorDataAndExternalSoldierOriginsExplicit() {
        let color = NativeTextureLoader.uploadOptions(srgb: true, origin: .topLeft)
        let normal = NativeTextureLoader.uploadOptions(srgb: false, origin: .bottomLeft)
        #expect(color[.SRGB] as? Bool == true)
        #expect(normal[.SRGB] as? Bool == false)
        #expect(color[.origin] as? MTKTextureLoader.Origin == .topLeft)
        #expect(normal[.origin] as? MTKTextureLoader.Origin == .bottomLeft)
        #expect(color[.generateMipmaps] as? Bool == true)
        #expect(normal[.textureStorageMode] as? UInt == MTLStorageMode.private.rawValue)
        #expect(normal[.textureUsage] as? UInt == MTLTextureUsage.shaderRead.rawValue)
        let balanced = NativeTextureLoader.uploadOptions(srgb: true, origin: .topLeft, profile: .balanced)
        #expect(balanced[.generateMipmaps] as? Bool == false)
        #expect(balanced[.allocateMipmaps] as? Bool == true)
        #expect(balanced[.textureUsage] as? UInt == MTLTextureUsage.shaderRead.union(.pixelFormatView).rawValue)
    }

    @Test func invalidSourcesAndOutOfBoundsCropsFailWithoutSilentFallback() throws {
        #expect(throws: (any Error).self) {
            try NativeTextureLoader.decode(data: Data([0,1,2,3]), profile: .balanced)
        }
        let data = try source(width: 16, height: 8)
        for crop in [NativeTextureCrop(normalizedX: -0.1, normalizedY: 0, width: 0.5, height: 0.5),
                     NativeTextureCrop(normalizedX: 0.9, normalizedY: 0, width: 0.5, height: 0.5),
                     NativeTextureCrop(normalizedX: 0, normalizedY: 0, width: 0, height: 0.5),
                     NativeTextureCrop(normalizedX: .nan, normalizedY: 0, width: 0.5, height: 0.5)] {
            #expect(throws: NativeTextureLoadError.self) {
                try NativeTextureLoader.decode(data: data, profile: .balanced, crop: crop)
            }
        }
    }
}
