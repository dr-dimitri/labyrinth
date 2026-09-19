import Foundation
import simd
import BlacksiteCore

/// Deterministic views of the actual shared foliage definitions. These scenes
/// report local environment conditions, never an assertion that an actor is safe.
@MainActor
enum NativeEnvironmentCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
    }
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer, loadout: LoadoutDefinition = .init()) throws -> Result? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let name = value("--scene"), name.hasPrefix("vegetation-") else { return nil }
        guard ["vegetation-ground", "vegetation-prone", "vegetation-edge", "vegetation-roof", "vegetation-overview"].contains(name) else {
            throw CheckFailure(message: "Vegetation scenes: vegetation-ground, vegetation-prone, vegetation-edge, vegetation-roof or vegetation-overview.")
        }
        let map = MapDefinition.blacksite
        let zones = map.environment.vegetationZones
        let requested = value("--vegetation-zone")
        guard let zone = requested.flatMap({ id in zones.first { $0.id == id } }) ?? (requested == nil ? zones.last : nil) else {
            throw CheckFailure(message: "Unknown vegetation zone. Available: \(zones.map(\.id).joined(separator: ", ")).")
        }
        let center = (zone.minimum + zone.maximum) * 0.5
        let half = (zone.maximum - zone.minimum) * 0.5
        var player = PlayerState(position: SIMD3(center.x, 0, center.z + half.z * 0.4))
        var world = map.obstacles
        if name == "vegetation-edge" { player.position.x = zone.maximum.x + 0.3 }
        if name == "vegetation-overview" {
            let offsets: [SIMD2<Float>] = [SIMD2(4, half.z + 5), SIMD2(-4, half.z + 5),
                                          SIMD2(half.x + 5, 4), SIMD2(-half.x - 5, 4)]
            guard let point = offsets.map({ SIMD3(center.x + $0.x, Float(0), center.z + $0.y) }).first(where: { point in
                point.x > map.minimum.x + 0.4 && point.x < map.maximum.x - 0.4 &&
                point.z > map.minimum.z + 0.4 && point.z < map.maximum.z - 0.4 &&
                !world.contains { abs(point.x - $0.position.x) < $0.size.x * 0.5 + 0.4 &&
                                  abs(point.z - $0.position.z) < $0.size.z * 0.5 + 0.4 }
            }) else { throw CheckFailure(message: "No clear overview position beside vegetation zone \(zone.id).") }
            player.position = point
        }
        if name == "vegetation-roof" {
            world.append(Obstacle(id: 9801, kind: .container,
                                  position: SIMD3(center.x, 0, center.z), size: SIMD3(3.8, 2.8, 5.8)))
            player.position.y = map.terrain.height(x: center.x, z: center.z) + 2.8
        }
        if name == "vegetation-prone" { player.prone = true; player.height = 0.57 }
        let feetY = player.position.y == 0 ? map.terrain.height(x: player.position.x, z: player.position.z) : player.position.y
        let target = SIMD3(center.x, map.terrain.height(x: center.x, z: center.z - half.z - 4) + 1.1, center.z - half.z - 4)
        let focus = name == "vegetation-overview" ? SIMD3(center.x, map.terrain.height(x: center.x, z: center.z) + 0.6, center.z) : target
        let delta = focus - SIMD3(player.position.x, feetY + player.height - 0.1, player.position.z)
        player.yaw = atan2(-delta.x, -delta.z)
        player.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
        var soldier = EnemyState(id: 9802, position: SIMD3(target.x, target.y - 1.1, target.z))
        soldier.yaw = atan2(player.position.x - target.x, player.position.z - target.z)
        soldier.aimBlend = 0.3
        let simulation = CombatSimulation(difficulty: .easy, seed: 1745, world: world,
                                          startingPlayer: player, startingEnemies: [soldier], startingWave: 3, map: map, loadout: loadout)
        try renderer.setMap(simulation.map)
        let sample = simulation.environmentSample(at: simulation.player.position)
        let eye = EnemyPose(soldier).eyePosition
        let opticalDepth = map.vegetationOpticalDepth(from: eye, to: simulation.eyePosition)
        if name == "vegetation-roof" {
            guard sample.supportingObstacleID == 9801, sample.camouflageGround == .none, sample.foliageDensity == 0 else {
                throw CheckFailure(message: "The roof fixture incorrectly inherited foliage or camouflage from the ground.")
            }
        } else if name == "vegetation-edge" || name == "vegetation-overview" {
            guard sample.foliageDensity == 0 else { throw CheckFailure(message: "Foliage extends beyond its authored footprint.") }
        } else {
            guard sample.camouflageGround == .vegetation, sample.foliageDensity > 0 else {
                throw CheckFailure(message: "The visible vegetation fixture has no matching local environment sample.")
            }
            if name == "vegetation-prone", opticalDepth <= 0 {
                throw CheckFailure(message: "The prone fixture has no foliage on its observer sight segment.")
            }
        }
        return Result(simulation: simulation, metadata: [
            "scene": name, "vegetationZone": zone.id, "vegetationZoneCount": zones.count,
            "localSurfaceMaterial": sample.surfaceMaterial.rawValue,
            "localCamouflageGround": sample.camouflageGround.rawValue,
            "localFoliageDensity": sample.foliageDensity,
            "supportingObstacleID": sample.supportingObstacleID.map { $0 as Any } ?? NSNull(),
            "observerEyeOpticalDepth": opticalDepth,
            "playerFeet": [simulation.player.position.x, simulation.player.position.y, simulation.player.position.z],
            "playerProne": simulation.player.prone
        ])
    }
}
