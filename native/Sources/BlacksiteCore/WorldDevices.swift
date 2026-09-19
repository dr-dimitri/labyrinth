import Foundation
import simd

public enum WorldDeviceKind: String, Sendable { case generator, serviceGate }
public enum DeviceAction: String, Sendable { case enableGenerator, disableGenerator, openGate, closeGate }
public enum DeviceInterruption: String, Sendable {
    case outOfRange, notGrounded, occluded, interactionReleased, releaseRequired, moving, blockedByActor, destroyed
}

/// All authored positions are offsets above terrain, like map obstacles.
public struct WorldInteractableDefinition: Sendable {
    public let id: Int
    public let kind: WorldDeviceKind
    public let ownerObstacleID: Int
    public let interactionPoints: [SIMD3<Float>]
    public let generatorID: Int?
    public let noiseEmitterIDs: [Int], lightIDs: [Int]
    public let openOffset: SIMD3<Float>
    public init(id: Int, kind: WorldDeviceKind, ownerObstacleID: Int, interactionPoints: [SIMD3<Float>],
                generatorID: Int? = nil, noiseEmitterIDs: [Int] = [], lightIDs: [Int] = [], openOffset: SIMD3<Float> = .zero) {
        self.id = id; self.kind = kind; self.ownerObstacleID = ownerObstacleID; self.interactionPoints = interactionPoints
        self.generatorID = generatorID; self.noiseEmitterIDs = noiseEmitterIDs; self.lightIDs = lightIDs; self.openOffset = openOffset
    }
}
public struct WorldInteractableState: Sendable {
    public let id: Int
    public let kind: WorldDeviceKind
    public let ownerObstacleID: Int
    public let interactionPoints: [SIMD3<Float>]
    public var enabled = true
    public var powered = true
    public var destroyed = false
    public var gateProgress: Float = 0
    public var targetOpen = false
    public var isMoving = false
    public var blockedByActor = false
    public var interactionProgress: Float = 0
    var closedPosition: SIMD3<Float>
    var navigationClear = false
    var manualMotion = false
}
public struct DeviceInteractionStatus: Sendable {
    public let id: Int
    public let kind: WorldDeviceKind
    public let action: DeviceAction
    public let enabled: Bool, powered: Bool, manual: Bool
    public let position: SIMD3<Float>
    public let distance: Float
    public let progress: Float, requiredProgress: Float, gateProgress: Float
    public let isMoving: Bool, blockedByActor: Bool, destroyed: Bool, interactionAvailable: Bool
    public let interruption: DeviceInterruption?
    public init(id: Int, kind: WorldDeviceKind, action: DeviceAction, enabled: Bool = true, powered: Bool = true,
                manual: Bool = false, position: SIMD3<Float> = .zero, distance: Float = 0, progress: Float = 0,
                requiredProgress: Float = 1, gateProgress: Float = 0, isMoving: Bool = false,
                blockedByActor: Bool = false, destroyed: Bool = false, interactionAvailable: Bool = true,
                interruption: DeviceInterruption? = nil) {
        self.id = id; self.kind = kind; self.action = action; self.enabled = enabled; self.powered = powered; self.manual = manual
        self.position = position; self.distance = distance; self.progress = progress; self.requiredProgress = requiredProgress
        self.gateProgress = gateProgress; self.isMoving = isMoving; self.blockedByActor = blockedByActor
        self.destroyed = destroyed; self.interactionAvailable = interactionAvailable; self.interruption = interruption
    }
}

public struct WorldSpotlightDefinition: Sendable {
    public let id: Int
    public let position: SIMD3<Float>, direction: SIMD3<Float>
    public let range: Float, innerCos: Float, outerCos: Float, power: Float
    public let color: SIMD3<Float>
    public let ownerObstacleID: Int?
    public init(id: Int, position: SIMD3<Float>, direction: SIMD3<Float>, range: Float = 16,
                innerCos: Float = 0.9063, outerCos: Float = 0.8090, power: Float = 1,
                color: SIMD3<Float> = SIMD3(0.95,0.83,0.63), ownerObstacleID: Int? = nil) {
        self.id = id; self.position = position; self.direction = direction; self.range = range
        self.innerCos = innerCos; self.outerCos = outerCos; self.power = power; self.color = color; self.ownerObstacleID = ownerObstacleID
    }
}
public struct WorldSpotlightState: Sendable {
    public let id: Int
    public let position: SIMD3<Float>, direction: SIMD3<Float>
    public let range: Float, innerCos: Float, outerCos: Float, power: Float
    public let color: SIMD3<Float>
    public var enabled: Bool
    public let ownerObstacleID: Int?
    public init(id: Int, position: SIMD3<Float>, direction: SIMD3<Float>, range: Float = 16,
                innerCos: Float = 0.9063, outerCos: Float = 0.8090, power: Float = 1,
                color: SIMD3<Float> = SIMD3(0.95,0.83,0.63), enabled: Bool = true, ownerObstacleID: Int? = nil) {
        self.id = id; self.position = position; self.direction = direction; self.range = range
        self.innerCos = innerCos; self.outerCos = outerCos; self.power = power; self.color = color
        self.enabled = enabled; self.ownerObstacleID = ownerObstacleID
    }
}
public struct WorldLightSample: Sendable {
    /// Independent direct-sun visibility and bounded artificial illumination.
    public let directSun: Float, artificial: Float
    public var recognitionMultiplier: Float { 0.8 + 0.2 * directSun + 0.2 * artificial }
}

extension CombatSimulation {
    /// The same cone and range falloff used by the renderer; fixed walls and the
    /// selected terrain are authoritative for light visibility, never exposure settings.
    public func lightSample(at point: SIMD3<Float>) -> WorldLightSample {
        let sun = simd_normalize(map.environment.sunDirection)
        let sunHit = wallHit(origin: point + sun * 0.02, direction: sun, maximumDistance: 180)
        let direct: Float = sunHit.obstacleIndex == nil && !sunHit.hitGround ? 1 : 0
        var artificial: Float = 0
        for light in spotlights where light.enabled {
            let offset = point - light.position, distance = simd_length(offset)
            guard distance.isFinite, distance > 0.001, distance < light.range else { continue }
            let cone = simd_dot(offset / distance, light.direction)
            guard cone > light.outerCos else { continue }
            let excluded = light.ownerObstacleID.flatMap { id in obstacles.firstIndex { $0.id == id } }
            guard clearLine(light.position, point, excludingObstacle: excluded) else { continue }
            let angle = clamp((cone - light.outerCos) / (light.innerCos - light.outerCos), 0, 1)
            let falloff = 1 - distance / light.range
            artificial += light.power * angle * angle * (3 - 2 * angle) * falloff * falloff
        }
        return WorldLightSample(directSun: direct, artificial: min(1, artificial))
    }
}
