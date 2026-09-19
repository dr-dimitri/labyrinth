import Foundation
import CoreGraphics
import ImageIO
import Metal
import MetalKit

enum NativeTextureProfile: String, CaseIterable, Sendable {
    case high, balanced

    var dimensionDivisor: Int { self == .high ? 1 : 2 }

    /// ImageIO preserves the aspect ratio under this limit. Rounding upward
    /// keeps odd source dimensions usable; a one-pixel image stays one pixel.
    func maximumDimension(width: Int, height: Int) -> Int {
        let source = max(1, max(width, height))
        return source / dimensionDivisor + (source % dimensionDivisor == 0 ? 0 : 1)
    }
}

enum NativeTextureOrigin: Sendable {
    case topLeft, bottomLeft

    var metalOrigin: MTKTextureLoader.Origin {
        self == .topLeft ? .topLeft : .bottomLeft
    }
}

/// Fractions of the unrotated source image, before Metal applies its origin.
/// The pine shader uses exactly this island rather than the unused atlas cards.
struct NativeTextureCrop: Equatable, Sendable {
    let normalizedX: Double
    let normalizedY: Double
    let width: Double
    let height: Double

    static let pineAtlasIsland = NativeTextureCrop(normalizedX: 0, normalizedY: 0, width: 0.25, height: 0.5)

    fileprivate func rectangle(width imageWidth: Int, height imageHeight: Int) throws -> CGRect {
        guard normalizedX.isFinite, normalizedY.isFinite, width.isFinite, height.isFinite,
              normalizedX >= 0, normalizedY >= 0, width > 0, height > 0,
              normalizedX + width <= 1, normalizedY + height <= 1 else {
            throw NativeTextureLoadError.invalidCrop
        }
        let x = floor(normalizedX * Double(imageWidth))
        let y = floor(normalizedY * Double(imageHeight))
        let right = ceil((normalizedX + width) * Double(imageWidth))
        let bottom = ceil((normalizedY + height) * Double(imageHeight))
        return CGRect(x: x, y: y, width: max(1, right - x), height: max(1, bottom - y))
    }
}

enum NativeTextureLoadError: LocalizedError {
    case invalidImage(String), invalidDimensions, invalidCrop, decodeFailed, uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage(let name): return "Texturbild konnte nicht gelesen werden: \(name)"
        case .invalidDimensions: return "Das Texturbild enthält keine gültigen Pixelmaße."
        case .invalidCrop: return "Der Texturausschnitt muss vollständig innerhalb des Bildes liegen."
        case .decodeFailed: return "Das Texturbild konnte nicht in der gewählten Größe dekodiert werden."
        case .uploadFailed(let detail): return "Die Textur konnte nicht korrekt auf die GPU geladen werden: \(detail)"
        }
    }
}

/// Decodes the chosen size before GPU allocation. The loader owns no texture
/// cache: callers can prepare a complete replacement set and swap it atomically.
final class NativeTextureLoader {
    let profile: NativeTextureProfile
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private lazy var mipmapQueue: MTLCommandQueue? = device.makeCommandQueue()

    init(device: MTLDevice, profile: NativeTextureProfile) {
        self.profile = profile
        self.device = device
        loader = MTKTextureLoader(device: device)
    }

    convenience init(device: MTLDevice, highQuality: Bool) {
        self.init(device: device, profile: highQuality ? .high : .balanced)
    }

    func load(url: URL, srgb: Bool, origin: NativeTextureOrigin = .topLeft,
              crop: NativeTextureCrop? = nil) throws -> MTLTexture {
        try autoreleasepool {
            let image = try Self.decode(url: url, profile: profile, crop: crop)
            return try upload(image: image, srgb: srgb, origin: origin)
        }
    }

    func load(data: Data, srgb: Bool, origin: NativeTextureOrigin = .topLeft,
              crop: NativeTextureCrop? = nil) throws -> MTLTexture {
        try autoreleasepool {
            let image = try Self.decode(data: data, profile: profile, crop: crop)
            return try upload(image: image, srgb: srgb, origin: origin)
        }
    }

    /// These explicit options preserve the previous color/data distinction and
    /// the opposite vertical convention of external SWAT PNGs versus GLB data.
    static func uploadOptions(srgb: Bool, origin: NativeTextureOrigin,
                              profile: NativeTextureProfile = .high) -> [MTKTextureLoader.Option: Any] {
        var options: [MTKTextureLoader.Option: Any] = [.SRGB: srgb, .generateMipmaps: true, .origin: origin.metalOrigin,
         .textureUsage: MTLTextureUsage.shaderRead.rawValue,
         .textureStorageMode: MTLStorageMode.private.rawValue]
        if profile == .balanced {
            // A CG bitmap-context image can cause MTK to ignore .SRGB. Allocate
            // the chain here, but generate it only after fixing the final format.
            options[.generateMipmaps] = false
            options[.allocateMipmaps] = true
            options[.textureUsage] = MTLTextureUsage.shaderRead.union(.pixelFormatView).rawValue
        }
        return options
    }

    private func upload(image: CGImage, srgb: Bool, origin: NativeTextureOrigin) throws -> MTLTexture {
        let source = try loader.newTexture(cgImage: image,
            options: Self.uploadOptions(srgb: srgb, origin: origin, profile: profile))
        guard profile == .balanced else { return source }
        let desired: MTLPixelFormat
        switch source.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb: desired = srgb ? .rgba8Unorm_srgb : .rgba8Unorm
        case .bgra8Unorm, .bgra8Unorm_srgb: desired = srgb ? .bgra8Unorm_srgb : .bgra8Unorm
        default:
            guard !srgb else {
                throw NativeTextureLoadError.uploadFailed("sRGB-Format für Pixeltyp \(source.pixelFormat.rawValue) fehlt.")
            }
            desired = source.pixelFormat // Preserve compact linear R8 data maps.
        }
        let texture: MTLTexture
        if desired == source.pixelFormat { texture = source }
        else {
            guard let view = source.makeTextureView(pixelFormat: desired) else {
                throw NativeTextureLoadError.uploadFailed("Die benötigte Farbraumansicht konnte nicht angelegt werden.")
            }
            texture = view
        }
        if texture.mipmapLevelCount > 1 {
            guard let command = mipmapQueue?.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
                throw NativeTextureLoadError.uploadFailed("Der Mipmap-Auftrag konnte nicht angelegt werden.")
            }
            // Generating through the final sRGB view performs the reduction in
            // linear light. Merely relabelling already-generated linear mips
            // would retain incorrect colors at a distance.
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw NativeTextureLoadError.uploadFailed(command.error?.localizedDescription ?? "Mipmap-Berechnung fehlgeschlagen.")
            }
        }
        return texture
    }

    static func decode(url: URL, profile: NativeTextureProfile, crop: NativeTextureCrop? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw NativeTextureLoadError.invalidImage(url.lastPathComponent)
        }
        return try decode(source: source, profile: profile, crop: crop)
    }

    static func decode(data: Data, profile: NativeTextureProfile, crop: NativeTextureCrop? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw NativeTextureLoadError.invalidImage("eingebettete Bilddaten")
        }
        return try decode(source: source, profile: profile, crop: crop)
    }

    private static func decode(source: CGImageSource, profile: NativeTextureProfile,
                               crop: NativeTextureCrop?) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw NativeTextureLoadError.invalidDimensions }
        let maximum = profile.maximumDimension(width: width, height: height)
        let image: CGImage?
        if profile == .high || maximum == max(width, height) {
            // No automatic EXIF orientation transform: source UVs and the
            // explicit Metal origin remain authoritative, as in the old loader.
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else { throw NativeTextureLoadError.decodeFailed }
        let uploadImage = profile == .balanced ? try canonicalThumbnail(image) : image
        guard let crop else { return uploadImage }
        // Crop after downsampling, so even the unused atlas regions never need
        // a full-resolution GPU allocation or a full-sized decoded pixel cache.
        let rectangle = try crop.rectangle(width: uploadImage.width, height: uploadImage.height)
        guard let island = uploadImage.cropping(to: rectangle) else { throw NativeTextureLoadError.decodeFailed }
        return island
    }

    /// ImageIO's opaque RGB thumbnails use XRGB, whereas the corresponding full
    /// images use RGBX. MTK's CGImage upload misreads that thumbnail layout as
    /// RGBA on the tested Metal runtime, turning the blue channel into alpha.
    /// Normalize only this proven incompatible format; keep monochrome maps
    /// single-channel and leave full-resolution decoding completely unchanged.
    private static func canonicalThumbnail(_ image: CGImage) throws -> CGImage {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.alphaInfo == .noneSkipFirst,
              let colorSpace = image.colorSpace, colorSpace.model == .rgb else { return image }
        // Match the opaque RGBX layout used by the working high-resolution
        // decode. The upload separately enforces the requested GPU color format.
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: bitmap) else { throw NativeTextureLoadError.decodeFailed }
        // Matching source/destination profiles avoid a color-space conversion of
        // normal/data channels. Opaque source pixels acquire alpha=255.
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw NativeTextureLoadError.decodeFailed }
        return result
    }
}
