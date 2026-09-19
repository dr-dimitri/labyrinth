import Foundation
import simd

public struct TerrainIntersection: Sendable, Equatable {
    /// World-space distance along the normalized input ray, in metres.
    public let distance: Float
    public let normal: SIMD3<Float>
    public init(distance: Float, normal: SIMD3<Float>) {
        self.distance = distance; self.normal = normal
    }
}

/// One height field shared by geometry, actors, projectiles and visual physics.
/// Render each integer-aligned cell with triangles A,C,B and B,C,D, where
/// A=(x,z), B=(x+1,z), C=(x,z+1), D=(x+1,z+1). The diagonal is B--C.
/// Height queries interpolate those exact planes, rather than a different
/// analytic/bilinear surface between the rendered vertices.
public enum TerrainProfile: Sendable, Equatable {
    case flat
    case battlefield
    case heightField(TerrainHeightField)

    /// Conservative world-height bounds shared by ray and render traversal.
    public var minimumHeight: Float {
        switch self { case .flat: return 0; case .battlefield: return -3; case .heightField(let field): return field.minimumHeight }
    }
    public var maximumHeight: Float {
        switch self { case .flat: return 0; case .battlefield: return 12; case .heightField(let field): return field.maximumHeight }
    }

    private func plane(x: Int, z: Int, upper: Bool) -> TerrainPlane {
        switch self {
        case .flat: return TerrainPlane(originHeight: 0, dx: 0, dz: 0)
        case .battlefield: return BattlefieldGrid.plane(x: x, z: z, upper: upper)
        case .heightField(let field):
            let a = field.vertex(x, z), b = field.vertex(x + 1, z), c = field.vertex(x, z + 1)
            if !upper { return TerrainPlane(originHeight: a, dx: b - a, dz: c - a) }
            let d = field.vertex(x + 1, z + 1)
            return TerrainPlane(originHeight: b + c - d, dx: d - c, dz: d - b)
        }
    }

    public static let gridSpacing: Float = 1

    public func height(x: Float, z: Float) -> Float {
        guard x.isFinite, z.isFinite,
              abs(x) < 1_000_000, abs(z) < 1_000_000 else { return 0 }
        let ix = Int(floor(x)), iz = Int(floor(z))
        let u = x - Float(ix), v = z - Float(iz)
        let plane = plane(x: ix, z: iz, upper: u + v > 1)
        return plane.originHeight + plane.dx * u + plane.dz * v
    }

    /// Normal of the same surface triangle used by height and ray queries.
    public func normal(x: Float, z: Float) -> SIMD3<Float> {
        guard x.isFinite, z.isFinite,
              abs(x) < 1_000_000, abs(z) < 1_000_000 else { return SIMD3(0, 1, 0) }
        let ix = Int(floor(x)), iz = Int(floor(z))
        let plane = plane(x: ix, z: iz, upper: x - Float(ix) + z - Float(iz) > 1)
        return simd_normalize(SIMD3(-plane.dx, 1, -plane.dz))
    }

    /// Finds the first contact, including hills hit by horizontal rays. Padding
    /// raises the height field vertically (useful for feet or small particles).
    /// Direction is normalized internally, so returned distances are metres.
    /// Starting on/below the padded surface is an immediate distance-zero hit.
    public func rayIntersection(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                maximumDistance: Float, padding: Float = 0) -> TerrainIntersection? {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
              maximumDistance.isFinite, maximumDistance >= 0, padding.isFinite,
              abs(origin.x) < 1_000_000, abs(origin.z) < 1_000_000 else { return nil }
        let largest = max(abs(direction.x), abs(direction.y), abs(direction.z))
        guard largest > 0 else { return nil }
        let scaled = direction / largest
        let ray = scaled / sqrt(simd_length_squared(scaled))
        if origin.y <= height(x: origin.x, z: origin.z) + padding + 0.000_01 {
            return TerrainIntersection(distance: 0, normal: normal(x: origin.x, z: origin.z))
        }
        if self == .flat {
            guard ray.y < 0 else { return nil }
            let distance = (padding - origin.y) / ray.y
            return distance <= maximumDistance ? TerrainIntersection(distance: distance, normal: SIMD3(0, 1, 0)) : nil
        }
        // Skip only air above this selected profile, including elevated maps.
        let ceiling = maximumHeight + padding
        if ray.y >= 0 && origin.y > ceiling { return nil }
        var entry: Float = ray.y < 0 ? max(0, (ceiling - origin.y) / ray.y) : 0
        guard entry <= maximumDistance else { return nil }
        let start = origin + ray * entry
        guard start.x.isFinite, start.z.isFinite,
              abs(start.x) < 1_000_000, abs(start.z) < 1_000_000 else { return nil }
        var ix = Int(floor(start.x)), iz = Int(floor(start.z))
        let stepX = ray.x >= 0 ? 1 : -1, stepZ = ray.z >= 0 ? 1 : -1
        let deltaX = ray.x == 0 ? Float.infinity : 1 / abs(ray.x)
        let deltaZ = ray.z == 0 ? Float.infinity : 1 / abs(ray.z)
        var boundaryX = ray.x == 0 ? Float.infinity : (Float(ix + (stepX > 0 ? 1 : 0)) - origin.x) / ray.x
        var boundaryZ = ray.z == 0 ? Float.infinity : (Float(iz + (stepZ > 0 ? 1 : 0)) - origin.z) / ray.z
        // The safety bound only concerns malformed, million-metre queries;
        // game rays cross at most a few hundred cells. No sample gaps exist.
        for _ in 0..<2_000_000 {
            let exit = min(maximumDistance, boundaryX, boundaryZ)
            var first: TerrainIntersection?
            for upper in [false, true] {
                let plane = plane(x: ix, z: iz, upper: upper)
                let slope = ray.y - plane.dx * ray.x - plane.dz * ray.z
                guard slope < -0.000_000_1 else { continue }
                let above = origin.y - padding - plane.originHeight -
                    plane.dx * (origin.x - Float(ix)) - plane.dz * (origin.z - Float(iz))
                let distance = -above / slope
                guard distance >= entry - 0.000_1, distance <= exit + 0.000_1,
                      distance >= 0, distance <= maximumDistance else { continue }
                let point = origin + ray * distance
                let u = point.x - Float(ix), v = point.z - Float(iz)
                guard u >= -0.000_1, u <= 1.000_1, v >= -0.000_1, v <= 1.000_1,
                      upper ? u + v >= 0.999_9 : u + v <= 1.000_1 else { continue }
                if first == nil || distance < first!.distance {
                    first = TerrainIntersection(distance: distance, normal: simd_normalize(SIMD3(-plane.dx, 1, -plane.dz)))
                }
            }
            if let first { return first }
            if exit >= maximumDistance { return nil }
            let next = min(boundaryX, boundaryZ)
            if boundaryX <= next { ix += stepX; boundaryX += deltaX }
            if boundaryZ <= next { iz += stepZ; boundaryZ += deltaZ }
            entry = next
        }
        return nil
    }
}

private struct TerrainPlane {
    var originHeight: Float
    var dx: Float
    var dz: Float
}

private struct FoundationPad {
    let x: Float, z: Float, halfWidth: Float, halfDepth: Float, height: Float
}

private enum BattlefieldGrid {
    static let radius = 256
    static let width = radius * 2 + 1

    // Fixed footprints of the original arena structures. Kept independent of
    // GameMap.obstacles: that map may itself query this field for object bases.
    // Each pad's elevation comes from the unmodified landscape at its centre.
    static let pads: [FoundationPad] = {
        let definitions: [(Float, Float, Float, Float)] = [
            (-22, -12, 13, 13), (24, -27, 12, 14),
            (-15, 14, 3.6, 11), (15, -5, 11, 3.6), (-25, 26, 9, 3.6),
            (-3.9, 18, 5.4, 0.85), (5.5, 6, 5.8, 0.85),
            (-4, -9, 5.8, 0.85), (4.5, -24, 5.4, 0.85),
            (20, 19, 3.2, 2.6), (-9, -25, 2.8, 2.8),
            (27, 7, 3, 3), (-29, 4, 3.2, 3.2),
            (-12, -35, 7, 0.8), (12, -35, 7, 0.8),
            (10, -1, 0.8, 0.8), (-11, 11, 0.8, 0.8),
            (18, 17, 0.8, 0.8), (-12, -22, 0.8, 0.8),
        ]
        // Nearby foundations share an elevation; otherwise a barrel next to a
        // container could create a steep step between their independently
        // flattened pads. Grouping is entirely local to this fixed layout.
        var groups = Array(definitions.indices)
        for i in definitions.indices { for j in definitions.indices where j > i {
            let a = definitions[i], b = definitions[j]
            let dx = max(0, abs(a.0 - b.0) - (a.2 + b.2) * 0.5)
            let dz = max(0, abs(a.1 - b.1) - (a.3 + b.3) * 0.5)
            if dx * dx + dz * dz < 3.5 * 3.5 {
                let old = groups[j], replacement = groups[i]
                for k in groups.indices where groups[k] == old { groups[k] = replacement }
            }
        } }
        var heights: [Float] = definitions.indices.map { index in
            var total: Float = 0, area: Float = 0, clearance: Float = 100
            for j in definitions.indices where groups[j] == groups[index] {
                let pad = definitions[j], size = pad.2 * pad.3
                total += base(pad.0, pad.1) * size; area += size
                clearance = min(clearance, max(0, abs(pad.0) - pad.2 * 0.5 - 1 - 7))
            }
            return min(clearance * 0.55, max(-clearance * 0.55, total / area))
        }
        // Impose compatible elevations on adjacent platforms before shaping
        // their ramps. This prevents short, steep cliffs between separate pads.
        for _ in definitions.indices {
            for i in definitions.indices { for j in definitions.indices where i != j {
                let a = definitions[i], b = definitions[j]
                let dx = max(0, abs(a.0 - b.0) - (a.2 + b.2) * 0.5 - 2)
                let dz = max(0, abs(a.1 - b.1) - (a.3 + b.3) * 0.5 - 2)
                let ceiling = heights[j] + 0.50 * sqrt(dx * dx + dz * dz)
                if heights[i] > ceiling {
                    for k in groups.indices where groups[k] == groups[i] { heights[k] = ceiling }
                }
            } }
        }
        return definitions.indices.map { index in
            let pad = definitions[index]
            return FoundationPad(x: pad.0, z: pad.1, halfWidth: pad.2 * 0.5 + 1,
                                 halfDepth: pad.3 * 0.5 + 1, height: heights[index])
        }
    }()

    // Approximately 1MiB, initialized once and immutable afterwards. All normal
    // gameplay/ray/mesh queries reuse the same samples and avoid trig/exp calls.
    static let samples: [Float] = {
        var values = [Float](); values.reserveCapacity(width * width)
        for z in -radius...radius { for x in -radius...radius { values.append(authored(Float(x), Float(z))) } }
        return values
    }()

    @inline(__always) static func vertex(_ x: Int, _ z: Int) -> Float {
        if abs(x) <= radius && abs(z) <= radius { return samples[(z + radius) * width + x + radius] }
        return authored(Float(x), Float(z))
    }

    @inline(__always) static func plane(x: Int, z: Int, upper: Bool) -> TerrainPlane {
        let a = vertex(x, z), b = vertex(x + 1, z), c = vertex(x, z + 1)
        if !upper { return TerrainPlane(originHeight: a, dx: b - a, dz: c - a) }
        let d = vertex(x + 1, z + 1)
        return TerrainPlane(originHeight: b + c - d, dx: d - c, dz: d - b)
    }

    static func smooth(_ value: Float) -> Float {
        let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
    }
    static func bump(_ x: Float, _ z: Float, _ cx: Float, _ cz: Float,
                     _ rx: Float, _ rz: Float, _ amount: Float) -> Float {
        let dx = (x - cx) / rx, dz = (z - cz) / rz
        return amount * exp(-0.5 * (dx * dx + dz * dz))
    }
    static func base(_ x: Float, _ z: Float) -> Float {
        var near = bump(x, z, -14, 27, 8.5, 9, 4.7)
        near += bump(x, z, -25, 1, 10, 13, 4.4)
        near += bump(x, z, 16, 24, 9, 11, 4.6)
        near += bump(x, z, 26, -9, 10, 12, 4.2)
        near -= bump(x, z, -31, 34, 6.5, 7, 2.6)
        near -= bump(x, z, -30, -31, 7.5, 9, 2.2)
        near -= bump(x, z, 32, 5, 6.5, 7, 3.8)
        near = min(5, max(-2, near))
        let road = smooth((abs(x) - 6.5) / 7.5)
        near *= road
        let outside = max(abs(x) - 40, abs(z) - 45)
        let blend = smooth(outside / 30)
        let ridges = sin(x * 0.028 + 0.6) * cos(z * 0.032) * 4.3 +
            sin(x * 0.074 + z * 0.036) * 1.9 + sin(z * 0.095 - x * 0.043) * 0.8
        return near * (1 - blend) + (4.2 + ridges) * blend
    }
    static func authored(_ x: Float, _ z: Float) -> Float {
        if abs(x) <= 7 && abs(z) <= 45 { return 0 }
        let original = base(x, z)
        guard abs(x) < 64, abs(z) < 70 else { return original }
        var lower: Float = -.infinity, upper: Float = .infinity
        if abs(z) <= 45 {
            upper = max(0, abs(x) - 7) * 0.55
            lower = -upper
        }
        for pad in pads {
            let dx = max(0, abs(x - pad.x) - pad.halfWidth)
            let dz = max(0, abs(z - pad.z) - pad.halfDepth)
            let distance = sqrt(dx * dx + dz * dz)
            lower = max(lower, pad.height - distance * 0.55)
            upper = min(upper, pad.height + distance * 0.55)
        }
        return min(upper, max(lower, original))
    }
}
