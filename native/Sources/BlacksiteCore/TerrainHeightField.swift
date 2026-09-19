import Foundation
import simd

public enum TerrainDefinitionError: Error, LocalizedError, Equatable {
    case invalidDimensions, invalidOrigin, invalidSamples
    public var errorDescription: String? {
        switch self {
        case .invalidDimensions: return "Ein Höhenfeld benötigt 2 bis 513 Rasterpunkte je Achse."
        case .invalidOrigin: return "Der Ursprung des Höhenfelds muss endlich und am 1-m-Raster ausgerichtet sein."
        case .invalidSamples: return "Das Höhenfeld enthält fehlende oder ungültige Höhenwerte."
        }
    }
}

/// Immutable, one-metre samples in row-major Z/X order. Outside the authored
/// rectangle the nearest edge height continues, so collision and scenery agree.
public struct TerrainHeightField: Sendable, Equatable {
    public let origin: SIMD2<Float>
    public let width: Int
    public let depth: Int
    public let samples: [Float]
    public let minimumHeight: Float
    public let maximumHeight: Float

    public init(origin: SIMD2<Float>, width: Int, depth: Int, samples: [Float]) throws {
        guard (2...513).contains(width), (2...513).contains(depth) else { throw TerrainDefinitionError.invalidDimensions }
        guard origin.x.isFinite, origin.y.isFinite, abs(origin.x) < 100_000, abs(origin.y) < 100_000,
              origin.x.rounded() == origin.x, origin.y.rounded() == origin.y else { throw TerrainDefinitionError.invalidOrigin }
        guard samples.count == width * depth, samples.allSatisfy({ $0.isFinite && abs($0) < 10_000 }) else {
            throw TerrainDefinitionError.invalidSamples
        }
        self.origin = origin; self.width = width; self.depth = depth; self.samples = samples
        minimumHeight = samples.min()!; maximumHeight = samples.max()!
    }

    @inline(__always) func vertex(_ x: Int, _ z: Int) -> Float {
        let column = clamp(x - Int(origin.x), 0, width - 1)
        let row = clamp(z - Int(origin.y), 0, depth - 1)
        return samples[row * width + column]
    }
}
