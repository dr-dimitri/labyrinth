import Foundation
import simd

public enum VegetationKind: String, Sendable { case tallGrass, brush }

/// A simplified plant envelope. The shared ellipse and terrain-relative layer
/// define both visible plants and perception; decorative blades have no rules.
public struct EnvironmentZone: Sendable {
    public static let minimumFootprintSpan: Float = 0.6
    public static let minimumHeight: Float = 0.25
    public static let plantsPerSquareMetre: Float = 2.2
    public static let maximumPlantCount = 96
    public static let maximumTotalPlantCount = 512
    /// Fixed visual density, independent of the number of zones or graphics
    /// quality. Invalid authoring is rejected by MapDefinition, never thinned.
    public var requiredPlantCount: Int {
        let radius = radii
        guard radius.x.isFinite, radius.y.isFinite, radius.x > 0, radius.y > 0 else { return Int.max }
        let area = Double(radius.x) * Double(radius.y) * (elliptical ? Double.pi : 4)
        let count = ceil(area * Double(Self.plantsPerSquareMetre))
        guard count.isFinite, count >= 1, count < Double(Int.max) else { return Int.max }
        return Int(count)
    }
    public let id: String
    /// X/Z are world coordinates; Y is a terrain offset when terrainRelative.
    public let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    public let density: Float
    public let kind: VegetationKind
    public let terrainRelative: Bool
    public let elliptical: Bool
    public var center: SIMD2<Float> { SIMD2((minimum.x + maximum.x) * 0.5, (minimum.z + maximum.z) * 0.5) }
    public var radii: SIMD2<Float> { SIMD2((maximum.x - minimum.x) * 0.5, (maximum.z - minimum.z) * 0.5) }
    public var height: Float { maximum.y - minimum.y }

    public init(id: String, center: SIMD2<Float>, radii: SIMD2<Float>, height: Float,
                density: Float, kind: VegetationKind, baseOffset: Float = 0) {
        self.id = id; minimum = SIMD3(center.x - radii.x, baseOffset, center.y - radii.y)
        maximum = SIMD3(center.x + radii.x, baseOffset + height, center.y + radii.y)
        self.density = density; self.kind = kind; terrainRelative = true; elliptical = true
    }

    /// Compatibility for authored world-space box metadata from the first map
    /// definition revision. New vegetation uses the terrain-relative initializer.
    public init(id: String, minimum: SIMD3<Float>, maximum: SIMD3<Float>, density: Float) {
        self.id = id; self.minimum = minimum; self.maximum = maximum; self.density = density
        kind = .brush; terrainRelative = false; elliptical = false
    }

    /// A consistent, soft density boundary in the outer 15% of the ellipse.
    /// Height stays terrain + plant height, so sparse tips never create a wall.
    public func footprintWeight(x: Float, z: Float) -> Float {
        guard x.isFinite, z.isFinite, maximum.x > minimum.x, maximum.z > minimum.z,
              x >= minimum.x, x <= maximum.x, z >= minimum.z, z <= maximum.z else { return 0 }
        guard elliptical else { return 1 }
        let p = (SIMD2(x, z) - center) / radii
        let t = clamp((1 - simd_length(p)) / 0.15, 0, 1)
        return t * t * (3 - 2 * t)
    }
    public func bottomHeight(x: Float, z: Float, terrain: TerrainProfile) -> Float {
        minimum.y + (terrainRelative ? terrain.height(x: x, z: z) : 0)
    }
    public func topHeight(x: Float, z: Float, terrain: TerrainProfile) -> Float {
        maximum.y + (terrainRelative ? terrain.height(x: x, z: z) : 0)
    }
    public func contains(_ point: SIMD3<Float>, terrain: TerrainProfile) -> Bool {
        footprintWeight(x: point.x, z: point.z) > 0 && point.y.isFinite &&
            point.y >= bottomHeight(x: point.x, z: point.z, terrain: terrain) &&
            point.y <= topHeight(x: point.x, z: point.z, terrain: terrain)
    }

    /// Actual metres inside the envelope, clipped to the finite sight segment.
    public func pathLength(from: SIMD3<Float>, to: SIMD3<Float>, terrain: TerrainProfile) -> Float {
        integrate(from: from, to: to, terrain: terrain).length
    }
    public func opticalDepth(from: SIMD3<Float>, to: SIMD3<Float>, terrain: TerrainProfile) -> Float {
        integrate(from: from, to: to, terrain: terrain).weighted * clamp(density, 0, 1)
    }

    fileprivate func horizontalInterval(from: SIMD3<Float>, delta: SIMD3<Float>) -> (Float, Float)? {
        var lower: Float = 0, upper: Float = 1
        for axis in [0, 2] {
            if abs(delta[axis]) < 0.000_001 {
                guard from[axis] >= minimum[axis], from[axis] <= maximum[axis] else { return nil }
            } else {
                let a = (minimum[axis] - from[axis]) / delta[axis], b = (maximum[axis] - from[axis]) / delta[axis]
                lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
                if upper <= lower { return nil }
            }
        }
        if elliptical {
            let p = (SIMD2(from.x, from.z) - center) / radii, d = SIMD2(delta.x, delta.z) / radii
            let a = simd_dot(d, d), b = simd_dot(p, d), c = simd_dot(p, p) - 1
            if a < 0.000_000_01 { if c > 0 { return nil } }
            else {
                let discriminant = b * b - a * c
                guard discriminant > 0 else { return nil }
                let root = sqrt(discriminant)
                lower = max(lower, (-b - root) / a); upper = min(upper, (-b + root) / a)
            }
        }
        return upper > lower ? (lower, upper) : nil
    }

    private func integrate(from: SIMD3<Float>, to: SIMD3<Float>, terrain: TerrainProfile) -> (length: Float, weighted: Float) {
        guard from.x.isFinite, from.y.isFinite, from.z.isFinite, to.x.isFinite, to.y.isFinite, to.z.isFinite,
              abs(from.x) < 1_000_000, abs(from.z) < 1_000_000, abs(to.x) < 1_000_000, abs(to.z) < 1_000_000,
              maximum.x > minimum.x, maximum.z > minimum.z, maximum.y > minimum.y else { return (0, 0) }
        let delta = to - from, length = simd_length(delta)
        guard length.isFinite, length > 0.000_001, let interval = horizontalInterval(from: from, delta: delta) else { return (0, 0) }
        var metres: Float = 0, weighted: Float = 0
        func append(_ start: Float, _ end: Float) {
            guard end > start else { return }
            let p = from + delta * start, q = from + delta * end
            let a = p.y - (terrainRelative ? terrain.height(x: p.x, z: p.z) : 0)
            let b = q.y - (terrainRelative ? terrain.height(x: q.x, z: q.z) : 0)
            var lo: Float = 0, hi: Float = 1
            if abs(b - a) < 0.000_001 {
                guard a >= minimum.y, a <= maximum.y else { return }
            } else {
                let first = (minimum.y - a) / (b - a), last = (maximum.y - a) / (b - a)
                lo = max(0, min(first, last)); hi = min(1, max(first, last))
                guard hi > lo else { return }
            }
            let t0 = start + (end - start) * lo, t1 = start + (end - start) * hi
            let span = (t1 - t0) * length
            // Two bounded density samples per exact terrain-triangle interval.
            let first = from + delta * (t0 + (t1 - t0) * 0.211_324_87)
            let second = from + delta * (t0 + (t1 - t0) * 0.788_675_13)
            metres += span
            weighted += span * (footprintWeight(x: first.x, z: first.z) + footprintWeight(x: second.x, z: second.z)) * 0.5
        }
        if !terrainRelative || abs(delta.x) + abs(delta.z) < 0.000_001 {
            append(interval.0, interval.1); return (metres, weighted)
        }
        // The height field has one exact affine plane per B--C triangle. Split
        // on its cell edges and diagonal, then clip the plant layer analytically.
        // Validated zones span at most 32m/axis: 256 segments is a hard bound.
        var cursor = Double(interval.0)
        let finish = Double(interval.1), dx = Double(delta.x), dz = Double(delta.z)
        let ox = Double(from.x), oz = Double(from.z)
        let px = ox + dx * cursor, pz = oz + dz * cursor
        var ix = Int(floor(px)), iz = Int(floor(pz))
        if dx < 0 && px == Double(ix) { ix -= 1 }
        if dz < 0 && pz == Double(iz) { iz -= 1 }
        for _ in 0..<256 {
            guard cursor < finish else { break }
            let tx = abs(dx) < 0.000_001 ? Double.infinity : (Double(ix + (dx > 0 ? 1 : 0)) - ox) / dx
            let tz = abs(dz) < 0.000_001 ? Double.infinity : (Double(iz + (dz > 0 ? 1 : 0)) - oz) / dz
            let end = min(finish, tx, tz)
            guard end > cursor else { break }
            let diagonal = abs(dx + dz) < 0.000_001 ? Double.infinity :
                (Double(ix + iz + 1) - ox - oz) / (dx + dz)
            if diagonal > cursor && diagonal < end { append(Float(cursor), Float(diagonal)); append(Float(diagonal), Float(end)) }
            else { append(Float(cursor), Float(end)) }
            if tx <= end { ix += dx > 0 ? 1 : -1 }
            if tz <= end { iz += dz > 0 ? 1 : -1 }
            cursor = end
        }
        return (metres, weighted)
    }
}

public typealias MapVisibilityVolume = EnvironmentZone

public struct EnvironmentSample: Sendable {
    public let surfaceMaterial: SurfaceMaterial
    public let camouflageGround: CamouflageGround
    public let foliageDensity: Float
    public let groundHeight: Float
    public let supportHeight: Float
    public let supportingObstacleID: Int?
}

extension MapDefinition {
    public func vegetationOpticalDepth(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        var depth: Float = 0
        for zone in environment.vegetationZones { depth += zone.opticalDepth(from: from, to: to, terrain: terrain) }
        return min(12, depth)
    }
}

extension CombatSimulation {
    /// A local physical probe, never a claim that enemies cannot see the player.
    public func environmentSample(at point: SIMD3<Float>) -> EnvironmentSample {
        let ground = terrain.height(x: point.x, z: point.z)
        var floor = ground, owner: Obstacle?
        for obstacle in obstacles where !obstacle.destroyed {
            if point.x >= obstacle.minimum.x, point.x <= obstacle.maximum.x,
               point.z >= obstacle.minimum.z, point.z <= obstacle.maximum.z,
               obstacle.maximum.y > floor, obstacle.maximum.y <= point.y + 0.12 {
                floor = obstacle.maximum.y; owner = obstacle
            }
        }
        var material = map.groundMaterial(at: point), camouflage: CamouflageGround = .none, density: Float = 0
        if let owner {
            switch owner.kind { case .bunker, .barrier: material = .concrete; case .crate: material = .wood; case .container, .barrel: material = .metal }
        } else if abs(point.y - ground) <= 0.2 {
            camouflage = map.environment.groundRegions.last(where: { $0.contains(x: point.x, z: point.z) })?.camouflage ?? .earth
            if map.roads.contains(where: { $0.contains(x: point.x, z: point.z) }) { camouflage = .none }
        }
        if owner == nil {
            for zone in map.environment.vegetationZones {
                let weight = zone.footprintWeight(x: point.x, z: point.z)
                if zone.contains(point, terrain: terrain) { density += weight * zone.density }
                if weight > 0, abs(point.y - ground) <= 0.2 { camouflage = .vegetation }
            }
        }
        return EnvironmentSample(surfaceMaterial: material, camouflageGround: camouflage, foliageDensity: min(1, density),
                                 groundHeight: ground, supportHeight: floor, supportingObstacleID: owner?.id)
    }

    /// Only recognition speed is reduced. Hard eye sight remains authoritative,
    /// and confirmed visual contact is never cancelled merely by foliage.
    public func vegetationRecognitionFactor(from observer: SIMD3<Float>) -> Float {
        guard clearLine(observer, eyePosition) else { return 0 }
        return vegetationRecognitionFactor(from: observer, eyeLineIsClear: true)
    }

    /// Called by the 10Hz awareness check only after its existing hard eye ray.
    /// All body targets share X/Z, so one inexpensive 2D envelope check rejects
    /// empty sight corridors before either extra terrain/obstacle ray is cast.
    func vegetationRecognitionFactor(from observer: SIMD3<Float>, eyeLineIsClear: Bool) -> Float {
        guard eyeLineIsClear else { return 0 }
        let delta = eyePosition - observer
        guard map.environment.vegetationZones.contains(where: {
            $0.density > 0 && $0.horizontalInterval(from: observer, delta: delta) != nil
        }) else { return 1 }
        var factor: Float = 0, totalWeight: Float = 0
        for (height, weight) in [(player.height - 0.1, Float(0.5)), (player.height * 0.58, 0.35), (player.height * 0.28, 0.15)] {
            let target = player.position + SIMD3(0, height, 0)
            guard height == player.height - 0.1 || clearLine(observer, target) else { continue }
            let depth = map.vegetationOpticalDepth(from: observer, to: target)
            factor += max(0.25, exp(-depth * 0.8)) * weight; totalWeight += weight
        }
        return totalWeight > 0 ? max(0.25, factor / totalWeight) : 1
    }
}
