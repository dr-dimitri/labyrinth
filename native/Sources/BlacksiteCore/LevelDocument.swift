import Foundation
import simd

/// Editable, value-semantic authoring data. No renderer handles or live combat state.
public struct LevelDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumFileBytes = 8 * 1024 * 1024
    public var formatVersion = currentVersion
    public var id: String
    public var revision = 1
    public var name: String
    public var description = ""
    public var bounds: LevelBounds
    public var terrain: LevelTerrain
    public var environment = LevelEnvironment()
    public var resourceSet = "blacksite"
    public var objects: [LevelObject] = []
    public var groups: [LevelGroup] = []
    public var markers: [LevelMarker] = []

    public init(id: String = UUID().uuidString, name: String = "Neues Level", bounds: LevelBounds = .init()) {
        self.id = id; self.name = name; self.bounds = bounds
        // Invalid dimensions remain reportable instead of overflowing allocation arithmetic.
        let count = (12...128).contains(bounds.width) && (12...128).contains(bounds.depth)
            ? (bounds.width + 1) * (bounds.depth + 1) : 0
        terrain = LevelTerrain(heights: Array(repeating: 0, count: count))
    }

    public func encoded() throws -> Data {
        try validateDraft()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileBytes else { throw LevelDocumentError("Die Leveldatei ist größer als 8 MiB.") }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw LevelDocumentError("Die Leveldatei ist größer als 8 MiB.") }
        do {
            struct Header: Decodable { let formatVersion: Int }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.formatVersion == currentVersion else {
                throw LevelDocumentError("Level-Formatversion \(header.formatVersion) wird nicht unterstützt (erwartet: \(currentVersion)).")
            }
            let document = try decoder.decode(Self.self, from: data)
            try document.validateDraft()
            return document
        } catch let error as LevelDocumentError { throw error }
        catch let error as DecodingError {
            let context: DecodingError.Context
            switch error {
            case .dataCorrupted(let value), .keyNotFound(_, let value), .typeMismatch(_, let value), .valueNotFound(_, let value): context = value
            @unknown default: throw LevelDocumentError("Die Leveldatei kann nicht gelesen werden.")
            }
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw LevelDocumentError("Ungültige Leveldaten\(field.isEmpty ? "" : " bei \(field)"): \(context.debugDescription)")
        }
    }
}

public struct LevelDocumentError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Right-handed world coordinates in metres; +Y is up. Angles are radians.
public struct LevelVector: Codable, Equatable, Sendable {
    public var x: Float, y: Float, z: Float
    public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) { self.x = x; self.y = y; self.z = z }
    public var value: SIMD3<Float> { SIMD3(x, y, z) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

public struct LevelBounds: Codable, Equatable, Sendable {
    public var x: Int, z: Int, width: Int, depth: Int
    public init(x: Int = -16, z: Int = -16, width: Int = 32, depth: Int = 32) {
        self.x = x; self.z = z; self.width = width; self.depth = depth
    }
}

public struct LevelTerrain: Codable, Equatable, Sendable {
    public var seed: UInt64
    /// Absolute world heights, one-metre samples in Z-major/X-minor order.
    /// Exactly (bounds.width + 1) * (bounds.depth + 1) samples.
    public var heights: [Float]
    public init(seed: UInt64 = 1, heights: [Float]) { self.seed = seed; self.heights = heights }
}

public struct LevelEnvironment: Codable, Equatable, Sendable {
    public var sunDirection = LevelVector(-0.68, 0.24, -0.69)
    public var sunIntensity: Float = 1
    public var fogColor = LevelVector(0.40, 0.49, 0.54)
    public var surfaces: [LevelSurface] = []
    public init() {}
}

public enum LevelGroundMaterial: String, Codable, CaseIterable, Sendable {
    case earth, grass, rock, asphalt
}
public struct LevelSurface: Codable, Equatable, Sendable {
    public var id: String
    public var x: Float, z: Float, width: Float, depth: Float
    public var material: LevelGroundMaterial
    public init(id: String = UUID().uuidString, x: Float, z: Float, width: Float, depth: Float, material: LevelGroundMaterial) {
        self.id = id; self.x = x; self.z = z; self.width = width; self.depth = depth; self.material = material
    }
}

public enum LevelHeightMode: String, Codable, Sendable { case ground, absolute }
public struct LevelObject: Codable, Equatable, Sendable {
    public var id: String
    public var catalogID: String
    /// Base-centre position: y is terrain-relative in ground mode, absolute otherwise.
    public var position: LevelVector
    /// Axis-aligned collision supports quarter turns, not arbitrary yaw or tilt.
    public var quarterTurns = 0
    public var scale = LevelVector(1, 1, 1)
    public var heightMode: LevelHeightMode = .ground
    public var groupID: String?
    public var locked = false
    /// Editor visibility only; hidden objects still participate in the playable map.
    public var hidden = false
    public init(id: String = UUID().uuidString, catalogID: String, position: LevelVector = .init()) {
        self.id = id; self.catalogID = catalogID; self.position = position
    }
}
public struct LevelGroup: Codable, Equatable, Sendable {
    public var id: String, name: String
    public init(id: String = UUID().uuidString, name: String) { self.id = id; self.name = name }
}
public enum LevelMarkerKind: String, Codable, CaseIterable, Sendable {
    case playerStart, enemySpawn, reinforcement, waveStaging, extraction, dataSite, radioSite, serviceApproach, patrol
}
public struct LevelMarker: Codable, Equatable, Sendable {
    public var id: String
    public var kind: LevelMarkerKind
    /// Marker y is always a terrain-relative offset. Playable foot points require zero.
    public var position: LevelVector
    public var yaw: Float = 0
    public var radius: Float = 2
    public init(id: String = UUID().uuidString, kind: LevelMarkerKind, position: LevelVector) {
        self.id = id; self.kind = kind; self.position = position
    }
}
