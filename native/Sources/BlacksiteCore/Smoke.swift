import Foundation
import simd

public enum SmokeKind: String, Sendable { case smoke, steam, spray }

/// One finite authored emission per cycle. Position is terrain-relative. The
/// current implementation reserves one of the four cloud slots for each source.
public struct SmokeEmitterDefinition: Sendable {
    public let id: Int
    public let kind: SmokeKind
    public let position: SIMD3<Float>, radii: SIMD3<Float>
    public let density: Float, lifetime: Float, interval: Float, startDelay: Float
    public let powerDeviceID: Int?
    public let warningLeadTime: Float, seededDelayRange: Float
    public let warningIndicatorPosition: SIMD3<Float>?
    public init(id: Int, kind: SmokeKind = .steam, position: SIMD3<Float>, radii: SIMD3<Float> = SIMD3(2.5,2,2.5),
                density: Float = 2.2, lifetime: Float = 10, interval: Float = 24, startDelay: Float = 2,
                powerDeviceID: Int? = nil, warningLeadTime: Float = 0, seededDelayRange: Float = 0,
                warningIndicatorPosition: SIMD3<Float>? = nil) {
        self.id = id; self.kind = kind; self.position = position; self.radii = radii
        self.density = density; self.lifetime = lifetime; self.interval = interval; self.startDelay = startDelay
        self.powerDeviceID = powerDeviceID; self.warningLeadTime = warningLeadTime
        self.seededDelayRange = seededDelayRange; self.warningIndicatorPosition = warningIndicatorPosition
    }

    /// A reproducible phase offset, independent of combat RNG and frame rate.
    /// Subsequent emissions keep the authored period, so warnings are learnable.
    public func firstEmissionTime(seed: UInt64) -> Double {
        guard seededDelayRange.isFinite, seededDelayRange > 0 else { return Double(startDelay) }
        var hash = seed ^ UInt64(bitPattern: Int64(id)) &* 0x9e3779b97f4a7c15
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        hash ^= hash >> 31
        let ticks = UInt64((Double(min(4, seededDelayRange)) * 120).rounded())
        return Double(startDelay) + Double(hash % (ticks + 1)) / 120
    }
}

/// A real, finite advance cue; it never grants enemies hostile knowledge.
public struct SmokeWarning: Sendable, Equatable {
    public let emitterID: Int, cycle: Int
    public let kind: SmokeKind
    public let position: SIMD3<Float>
    public let beginsAt: Double, startsAt: Double
    public init(emitterID: Int, kind: SmokeKind, position: SIMD3<Float>, startsAt: Double, cycle: Int, beginsAt: Double = 0) {
        self.emitterID = emitterID; self.kind = kind; self.position = position
        self.startsAt = startsAt; self.cycle = cycle; self.beginsAt = beginsAt
    }
}

public struct SmokeGrenadeState: Sendable {
    public let id: Int
    public internal(set) var position: SIMD3<Float>, velocity: SIMD3<Float>
    public var fuse: Float { Float(remainingTicks) / 120 }
    var remainingTicks = 180
    public init(id: Int, position: SIMD3<Float>, velocity: SIMD3<Float>) {
        self.id = id; self.position = position; self.velocity = velocity
    }
}

/// Authoritative optical envelope shared with the renderer. Radii and density
/// already include growth/fade. Noise may vary its colour, never its opacity.
public struct SmokeVolumeState: Sendable {
    public static let maximumCount = 4
    public static let opaqueOpticalDepth: Float = 4.6
    public let id: Int
    public let kind: SmokeKind
    public let position: SIMD3<Float>, origin: SIMD3<Float>
    public let maximumRadii: SIMD3<Float>
    public let peakDensity: Float, lifetime: Float
    public let createdAt: Double, sourceEmitterID: Int?
    public internal(set) var age: Float
    public internal(set) var clipMinimum: SIMD3<Float>, clipMaximum: SIMD3<Float>
    public var radii: SIMD3<Float> { maximumRadii * (0.2 + 0.8 * growth) }
    public var density: Float {
        let fadeDuration = min(3, lifetime * 0.3)
        let remaining = smokeSmoothstep((lifetime - age) / fadeDuration)
        return peakDensity * growth * remaining
    }
    private var growth: Float { smokeSmoothstep(age / min(1, lifetime * 0.2)) }

    public init(id: Int, kind: SmokeKind = .smoke, position: SIMD3<Float>, radii: SIMD3<Float> = SIMD3(3,2,3),
                origin: SIMD3<Float>? = nil, density: Float = 2.2, age: Float = 0, lifetime: Float = 10,
                createdAt: Double = 0, sourceEmitterID: Int? = nil,
                clipMinimum: SIMD3<Float>? = nil, clipMaximum: SIMD3<Float>? = nil) {
        self.id = id; self.kind = kind; self.position = position; self.origin = origin ?? position
        maximumRadii = radii; peakDensity = density; self.age = age; self.lifetime = lifetime
        self.createdAt = createdAt; self.sourceEmitterID = sourceEmitterID
        self.clipMinimum = clipMinimum ?? position - radii
        self.clipMaximum = clipMaximum ?? position + radii
    }

    /// Extinction per metre; the C1 kernel has no hidden opaque bounding box.
    public func density(at point: SIMD3<Float>) -> Float {
        guard valid, smokeFinite(point), point.x >= clipMinimum.x, point.x <= clipMaximum.x,
              point.y >= clipMinimum.y, point.y <= clipMaximum.y, point.z >= clipMinimum.z, point.z <= clipMaximum.z else { return 0 }
        let p = (point - position) / radii, q = simd_dot(p,p)
        return q < 1 ? density * (1-q) * (1-q) : 0
    }

    /// Exact integral of density*(1-q)^2 on a finite segment, after clipping to
    /// the ellipsoid and physical planes. Three-point Gauss-Legendre integrates
    /// this quartic exactly; the GPU uses the identical nodes and weights.
    public func opticalDepth(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        guard valid, smokeFinite(from), smokeFinite(to) else { return 0 }
        let delta = to - from, metres = simd_length(delta)
        guard metres.isFinite, metres > 0.000001 else { return 0 }
        let p = (from-position)/radii, d = delta/radii
        let a = simd_dot(d,d), b = simd_dot(p,d), c = simd_dot(p,p)-1
        let discriminant = b*b-a*c
        guard a > 0, discriminant > 0, discriminant.isFinite else { return 0 }
        let root = sqrt(discriminant)
        var lo = max(0,(-b-root)/a), hi = min(1,(-b+root)/a)
        for axis in 0..<3 {
            if abs(delta[axis]) < 0.000001 {
                guard from[axis] >= clipMinimum[axis], from[axis] <= clipMaximum[axis] else { return 0 }
            } else {
                let first = (clipMinimum[axis]-from[axis])/delta[axis], last = (clipMaximum[axis]-from[axis])/delta[axis]
                lo = max(lo,min(first,last)); hi = min(hi,max(first,last))
            }
        }
        guard hi > lo else { return 0 }
        let middle = (lo+hi)*0.5, half = (hi-lo)*0.5, node: Float = 0.7745966692414834
        func value(_ t: Float) -> Float {
            let sample = p+d*t, edge = max(0,1-simd_dot(sample,sample))
            return edge*edge
        }
        let integral = half * (Float(5)/9 * value(middle-half*node) + Float(8)/9 * value(middle) + Float(5)/9 * value(middle+half*node))
        return min(20,max(0,integral*metres*density))
    }

    private var valid: Bool {
        smokeFinite(position) && smokeFinite(radii) && smokeFinite(clipMinimum) && smokeFinite(clipMaximum) &&
        radii.x > 0 && radii.y > 0 && radii.z > 0 && clipMaximum.x > clipMinimum.x &&
        clipMaximum.y > clipMinimum.y && clipMaximum.z > clipMinimum.z &&
        density.isFinite && density > 0 && age.isFinite && lifetime.isFinite && lifetime > 0
    }

    /// Conservative room containment, not fluid simulation: every intersecting
    /// solid contributes its separating face nearest the emission side. Mist
    /// never appears across that wall, including thin closed gate panels. These
    /// same planes are exposed to rendering and recomputed for moving doors.
    mutating func constrain(to obstacles: [Obstacle], terrain: TerrainProfile) {
        clipMinimum = position-radii; clipMaximum = position+radii
        clipMinimum.y = max(clipMinimum.y,terrain.height(x: origin.x,z: origin.z))
        for box in obstacles where !box.destroyed {
            let low = box.minimum, high = box.maximum
            guard high.x > clipMinimum.x, low.x < clipMaximum.x, high.y > clipMinimum.y,
                  low.y < clipMaximum.y, high.z > clipMinimum.z, low.z < clipMaximum.z else { continue }
            var axis = -1, separation: Float = -1, lowerSide = false
            for candidate in 0..<3 {
                if origin[candidate] < low[candidate], low[candidate]-origin[candidate] > separation {
                    axis = candidate; separation = low[candidate]-origin[candidate]; lowerSide = true
                } else if origin[candidate] > high[candidate], origin[candidate]-high[candidate] > separation {
                    axis = candidate; separation = origin[candidate]-high[candidate]; lowerSide = false
                }
            }
            guard axis >= 0 else { clipMaximum = clipMinimum; return }
            if lowerSide { clipMaximum[axis] = min(clipMaximum[axis],low[axis]) }
            else { clipMinimum[axis] = max(clipMinimum[axis],high[axis]) }
        }
    }
}

public struct SmokeVisibilitySample: Sendable {
    public let opticalDepth: Float
    public var transmission: Float { exp(-opticalDepth) }
    public var opaque: Bool { opticalDepth >= SmokeVolumeState.opaqueOpticalDepth }
    public init(opticalDepth: Float) { self.opticalDepth = opticalDepth.isFinite ? clamp(opticalDepth,0,20) : 0 }
}

private func smokeSmoothstep(_ value: Float) -> Float {
    guard value.isFinite else { return 0 }
    let x = clamp(value,0,1); return x*x*(3-2*x)
}
private func smokeFinite(_ point: SIMD3<Float>) -> Bool { point.x.isFinite && point.y.isFinite && point.z.isFinite }

extension CombatSimulation {
    public func smokeOpticalDepth(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        min(20,smokeVolumes.reduce(0) { $0 + $1.opticalDepth(from: from,to: to) })
    }
    public func smokeVisibility(from: SIMD3<Float>, to: SIMD3<Float>) -> SmokeVisibilitySample {
        SmokeVisibilitySample(opticalDepth: smokeOpticalDepth(from: from,to: to))
    }
    /// A clear head or torso segment still counts as remaining visibility.
    /// Only hard-visible samples may provide remaining optical visibility.
    /// The flag reuses the awareness pass's already verified head segment.
    func playerSmokeVisibility(from observer: SIMD3<Float>, eyeLineIsClear: Bool = false) -> SmokeVisibilitySample {
        var least = SmokeVisibilitySample(opticalDepth: 20)
        if eyeLineIsClear || sightLine(observer,eyePosition) {
            least = smokeVisibility(from: observer,to: eyePosition)
            if !least.opaque { return least }
        }
        for height in [player.height*0.62,player.height*0.3] {
            let point = player.position+SIMD3<Float>(0,height,0)
            if sightLine(observer,point) {
                let body = smokeVisibility(from: observer,to: point)
                if !body.opaque { return body }
                if body.opticalDepth < least.opticalDepth { least = body }
            }
        }
        return least
    }
}
