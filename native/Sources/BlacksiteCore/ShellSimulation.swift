import Foundation
import simd

/// An empty spent case. Its long axis is local +Y; orientation stores xyzw.
public struct ShellCasing: Sendable {
    public let id: Int
    public let weapon: WeaponKind
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var orientation: SIMD4<Float>
    public var age: Float
    public var resting: Bool
    public var length: Float { weapon == .rifle ? 0.055 : 0.072 }
    public var radius: Float { weapon == .rifle ? 0.006 : 0.007 }

    fileprivate var angularVelocity: SIMD3<Float>
    fileprivate var supportIndex: Int?
    fileprivate var supportID: Int?
    fileprivate var lastImpactAge: Float = -1
}

public struct ShellImpact: Sendable {
    public let position: SIMD3<Float>
    public let speed: Float
    public init(position: SIMD3<Float>, speed: Float) { self.position = position; self.speed = speed }
}

/// Small visual rigid bodies, isolated from gameplay damage and collision rules.
/// A bounded array and a fixed 240 Hz accumulator keep cost and results stable.
public struct ShellSimulation: Sendable {
    public private(set) var casings: [ShellCasing] = []
    private let initialSeed: UInt64
    private var seed: UInt64
    private var nextID = 1
    private var accumulator: Double = 0
    private static let stepDuration = 1.0 / 240.0
    private static let lifetime: Float = 14
    private static let capacity = 96

    public init(seed: UInt64 = 0x5348_454C) {
        initialSeed = seed & 0xffff_ffff; self.seed = initialSeed
        casings.reserveCapacity(Self.capacity)
    }

    public mutating func eject(weapon: WeaponKind, position: SIMD3<Float>, velocity: SIMD3<Float>, orientation: SIMD4<Float>) {
        guard finite(position), finite(velocity), orientation.x.isFinite, orientation.y.isFinite,
              orientation.z.isFinite, orientation.w.isFinite else { return }
        // Scale first: finite Float components can still overflow length_squared.
        let largest = max(max(abs(orientation.x), abs(orientation.y)), max(abs(orientation.z), abs(orientation.w)))
        let scaled = largest > 0.000_001 ? orientation / largest : SIMD4<Float>(0, 0, 0, 1)
        let rotation = scaled / sqrt(simd_length_squared(scaled))
        let spin = SIMD3<Float>((random() - 0.5) * 48, (random() - 0.5) * 36, (random() - 0.5) * 48)
        let speed = simd_length(velocity)
        guard speed.isFinite else { return }
        if casings.count == Self.capacity { casings.removeFirst() }
        casings.append(ShellCasing(id: nextID, weapon: weapon, position: position,
                                  velocity: speed > 80 ? velocity * (80 / speed) : velocity,
                                  orientation: rotation, age: 0, resting: false, angularVelocity: spin))
        nextID += 1
    }

    @discardableResult public mutating func step(deltaTime: Float, obstacles: [Obstacle], terrain: TerrainProfile = .flat) -> [ShellImpact] {
        guard deltaTime.isFinite, deltaTime > 0 else { return [] }
        guard !casings.isEmpty else { accumulator = 0; return [] }
        // A suspended app cannot turn into seconds of catch-up work on resume.
        accumulator += min(Double(deltaTime), 0.15)
        var impacts: [ShellImpact] = []
        while accumulator + 1e-9 >= Self.stepDuration {
            integrate(Float(Self.stepDuration), obstacles: obstacles, terrain: terrain, impacts: &impacts)
            accumulator -= Self.stepDuration
        }
        accumulator = max(0, accumulator)
        return impacts
    }

    public mutating func reset() {
        casings.removeAll(keepingCapacity: true)
        accumulator = 0; nextID = 1; seed = initialSeed
    }

    private mutating func random() -> Float {
        seed = (1_664_525 &* seed &+ 1_013_904_223) & 0xffff_ffff
        return Float(Double(seed) / 4_294_967_296)
    }

    private func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    private mutating func integrate(_ dt: Float, obstacles: [Obstacle], terrain: TerrainProfile, impacts: inout [ShellImpact]) {
        for index in casings.indices {
            casings[index].age += dt
            guard casings[index].age < Self.lifetime else { continue }
            var casing = casings[index]
            if casing.resting {
                if let supportIndex = casing.supportIndex {
                    if obstacles.indices.contains(supportIndex), !obstacles[supportIndex].destroyed,
                       obstacles[supportIndex].id == casing.supportID { casings[index] = casing; continue }
                    casing.resting = false; casing.supportIndex = nil; casing.supportID = nil
                } else { casings[index] = casing; continue }
            }
            let angularSpeed = simd_length(casing.angularVelocity)
            if angularSpeed > 0.001 {
                let spin = simd_quatf(angle: angularSpeed * dt, axis: casing.angularVelocity / angularSpeed)
                casing.orientation = simd_normalize(spin * simd_quatf(vector: casing.orientation)).vector
                casing.angularVelocity *= 1 - 0.16 * dt
            }
            let axis = simd_quatf(vector: casing.orientation).act(SIMD3<Float>(0, 1, 0))
            let halfBody = max(0, casing.length * 0.5 - casing.radius)
            let extent = simd_abs(axis) * halfBody + SIMD3<Float>(repeating: casing.radius)
            casing.velocity.y -= 9.81 * dt
            resolvePenetration(&casing, extent: extent, obstacles: obstacles, terrain: terrain)
            var remaining = dt
            for _ in 0..<3 {
                let speed = simd_length(casing.velocity)
                if speed < 0.000_01 || remaining < 0.000_001 || casing.resting { break }
                let direction = casing.velocity / speed
                let hit = trace(casing.position, direction: direction, distance: speed * remaining,
                                extent: extent, obstacles: obstacles, terrain: terrain)
                if hit.normal == .zero {
                    casing.position += casing.velocity * remaining
                    break
                }
                casing.position += direction * max(0, hit.distance - 0.0001)
                remaining = max(0, remaining - hit.distance / speed)
                let incoming = max(0, -simd_dot(casing.velocity, hit.normal))
                if incoming > 0.6 && casing.age - casing.lastImpactAge >= 0.055 {
                    impacts.append(ShellImpact(position: casing.position - hit.normal * simd_dot(extent, simd_abs(hit.normal)), speed: incoming))
                    casing.lastImpactAge = casing.age
                }
                if incoming > 0 {
                    let tangent = casing.velocity + incoming * hit.normal
                    casing.velocity = tangent * 0.69 + hit.normal * incoming * 0.31
                    casing.angularVelocity *= 0.57
                }
                casing.position += hit.normal * 0.0002
                if hit.normal.y > 0.7 && incoming < 0.7 && simd_length(casing.velocity - hit.normal * simd_dot(casing.velocity, hit.normal)) < 0.28 {
                    settle(&casing, on: hit.obstacleIndex, obstacles: obstacles, terrain: terrain)
                }
            }
            casings[index] = casing
        }
        casings.removeAll { $0.age >= Self.lifetime }
    }

    private struct Collision {
        var distance: Float
        var normal: SIMD3<Float> = .zero
        var obstacleIndex: Int?
    }

    private func trace(_ origin: SIMD3<Float>, direction: SIMD3<Float>, distance: Float,
                       extent: SIMD3<Float>, obstacles: [Obstacle], terrain: TerrainProfile) -> Collision {
        var closest = Collision(distance: distance)
        if let hit = terrain.rayIntersection(origin: origin, direction: direction, maximumDistance: distance, padding: extent.y),
           simd_dot(direction, hit.normal) < 0 {
            closest = Collision(distance: hit.distance, normal: hit.normal)
        }
        for index in obstacles.indices where !obstacles[index].destroyed {
            let box = obstacles[index]
            if let hit = rayBox(origin: origin, direction: direction, minimum: box.minimum - extent, maximum: box.maximum + extent),
               hit.distance <= closest.distance, simd_dot(direction, hit.normal) < 0 {
                closest = Collision(distance: hit.distance, normal: hit.normal, obstacleIndex: index)
            }
        }
        return closest
    }

    private func resolvePenetration(_ casing: inout ShellCasing, extent: SIMD3<Float>, obstacles: [Obstacle], terrain: TerrainProfile) {
        // Rotation can expand a body's support interval between fixed steps.
        // Also recover gracefully when an ejection port is initially inside cover.
        let floor = terrain.height(x: casing.position.x, z: casing.position.z) + extent.y
        if casing.position.y < floor { casing.position.y = floor }
        for box in obstacles where !box.destroyed {
            let low = box.minimum - extent, high = box.maximum + extent, p = casing.position
            guard p.x > low.x, p.x < high.x, p.y > low.y, p.y < high.y, p.z > low.z, p.z < high.z else { continue }
            var nearest: Float = .infinity, axis = 0, positive = false
            for candidate in 0..<3 {
                if p[candidate] - low[candidate] < nearest { nearest = p[candidate] - low[candidate]; axis = candidate; positive = false }
                if high[candidate] - p[candidate] < nearest { nearest = high[candidate] - p[candidate]; axis = candidate; positive = true }
            }
            casing.position[axis] = positive ? high[axis] + 0.0001 : low[axis] - 0.0001
        }
    }

    private func settle(_ casing: inout ShellCasing, on support: Int?, obstacles: [Obstacle], terrain: TerrainProfile) {
        let axis = simd_quatf(vector: casing.orientation).act(SIMD3<Float>(0, 1, 0))
        let normal = support == nil ? terrain.normal(x: casing.position.x, z: casing.position.z) : SIMD3<Float>(0, 1, 0)
        var tangent = axis - normal * simd_dot(axis, normal)
        if simd_length_squared(tangent) < 0.0001 { tangent = simd_cross(normal, SIMD3(0, 0, 1)) }
        casing.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(tangent)).vector
        casing.position.y = (support.map { obstacles[$0].maximum.y } ?? terrain.height(x: casing.position.x, z: casing.position.z)) + casing.radius / max(0.2, normal.y)
        casing.velocity = .zero; casing.angularVelocity = .zero; casing.resting = true
        casing.supportIndex = support; casing.supportID = support.map { obstacles[$0].id }
    }
}
