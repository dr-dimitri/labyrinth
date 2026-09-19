import Foundation
import simd
import BlacksiteCore

/// Deterministic, real interactions. Diagnostic light maps contain actual wall
/// or height-field occluders; their CPU probes do not replace image inspection.
@MainActor
enum NativeDeviceCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["device-generator-on", "device-generator-off", "device-gate-closed",
        "device-gate-moving", "device-gate-open", "device-gate-blocked", "device-gate-manual",
        "device-light-wall", "device-light-terrain", "device-light-daylight", "device-light-soldier"]

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("device-") else { return nil }
        let result = try makeScenario(scene: arguments[index + 1],
            generatorOff: arguments.contains("--generator-off"), loadout: loadout)
        try renderer.setMap(result.simulation.map)
        renderer.handle(events: result.events, simulation: result.simulation)
        return result
    }

    /// Also exercised by CPU-only fixture tests, without creating an audio or
    /// Metal device. Production states can only change through ordinary input.
    static func makeScenario(scene: String, generatorOff: Bool = false,
                             loadout: LoadoutDefinition = .init()) throws -> Result {
        guard scenes.contains(scene) else { throw Failure(message: "Device scenes: \(scenes.joined(separator: ", ")).") }
        let lighting = scene.hasPrefix("device-light-")
        let soldierScene = scene == "device-light-soldier"
        let manual = scene == "device-gate-manual"
        let gateScene = scene.hasPrefix("device-gate-")
        let map = lighting ? try lightMap(occluder: scene) : MapDefinition.blacksite
        guard let generator = map.environment.devices.first(where: { $0.kind == .generator }),
              let generatorPoint = generator.interactionPoints.first else {
            throw Failure(message: "The device fixture requires a real authored generator and interaction point.")
        }
        let gateDefinition = map.environment.devices.first { $0.kind == .serviceGate }
        let gatePoint = gateDefinition?.interactionPoints.last
        let start = gateScene && !manual ? gatePoint : generatorPoint
        guard let start else { throw Failure(message: "The gate fixture has no authored control point.") }
        let offset: SIMD3<Float> = lighting || manual ? .zero : SIMD3(0, 0, 1.2)
        let player = PlayerState(position: soldierScene && !generatorOff ? SIMD3(2, 0, 1) : map.grounded(start + offset))
        var enemies: [EnemyState] = []
        if soldierScene {
            var soldier = EnemyState(id: 9850, position: SIMD3(0, 0, -3))
            soldier.yaw = atan2(player.position.x - soldier.position.x, player.position.z - soldier.position.z)
            soldier.aimBlend = 0.35
            enemies.append(soldier)
        }
        let game = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
            startingPlayer: player, startingEnemies: enemies, startingWave: 3, map: map, loadout: loadout)
        var records: [GameEvent] = []
        let sunProbe = lighting ? SIMD3<Float>(12, 1.2, -12) : map.grounded(SIMD3(0, 1.2, 28))
        let sunBefore = game.lightSample(at: sunProbe).directSun

        func advance(_ seconds: Double, interact: Bool = false) {
            var input = GameInput(); input.yaw = game.player.yaw; input.pitch = game.player.pitch
            input.interact = interact
            for _ in 0..<max(1, Int((seconds * 120).rounded())) {
                game.step(deltaTime: 1.0 / 120, input: input)
                records.append(contentsOf: game.drainEvents())
            }
        }
        func aim(at target: SIMD3<Float>) {
            let delta = target - game.eyePosition
            var input = GameInput()
            input.yaw = atan2(-delta.x, -delta.z)
            input.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
            game.step(deltaTime: 1.0 / 120, input: input)
            records.append(contentsOf: game.drainEvents())
        }
        func walk(to target: SIMD3<Float>) throws {
            for _ in 0..<2400 {
                let delta = SIMD2(target.x - game.player.position.x, target.z - game.player.position.z)
                if simd_length(delta) < 0.075 { return }
                var input = GameInput(); input.yaw = atan2(-delta.x, -delta.y)
                input.pitch = 0; input.moveForward = 1
                game.step(deltaTime: 1.0 / 120, input: input)
                records.append(contentsOf: game.drainEvents())
            }
            throw Failure(message: "The device fixture could not walk its real route to \(target.x), \(target.z); reached \(game.player.position).")
        }
        func state(_ id: Int) throws -> WorldInteractableState {
            guard let value = game.devices.first(where: { $0.id == id }) else {
                throw Failure(message: "A device vanished from the fixture: \(id).")
            }
            return value
        }
        let switchOff = scene == "device-generator-off" || manual || (lighting && generatorOff)
        if switchOff {
            guard game.deviceInteractionStatus?.id == generator.id,
                  game.deviceInteractionStatus?.interactionAvailable == true else {
                throw Failure(message: "The generator's authored control point is not usable.")
            }
            // Continue holding beyond completion to exercise the release latch.
            advance(2.2, interact: true)
            guard try !state(generator.id).enabled,
                  records.filter({ $0.kind == .deviceActivated && $0.id == generator.id }).count == 1 else {
                throw Failure(message: "A held generator interaction did not switch it off exactly once.")
            }
            advance(1.0 / 120)
        }

        if gateScene {
            guard let gateDefinition, let gatePoint else { throw Failure(message: "No service gate in this fixture.") }
            if manual {
                // Use the established central road instead of cutting through
                // the steep eastern hills along the generator's X coordinate.
                try walk(to: SIMD3(0, 0, generatorPoint.z))
                try walk(to: SIMD3(0, 0, gatePoint.z + 3))
                try walk(to: gatePoint + SIMD3(0, 0, 1.2))
                guard game.deviceInteractionStatus?.id == gateDefinition.id,
                      game.deviceInteractionStatus?.manual == true else {
                    throw Failure(message: "The unpowered gate did not offer its manual route.")
                }
            }
            if scene != "device-gate-closed" {
                advance(manual ? 2.05 : 1.05, interact: true)
                advance(scene == "device-gate-moving" ? 0.65 : manual ? 4.15 : 2.15)
            }
            if scene == "device-gate-blocked" {
                advance(1.05, interact: true)
                try walk(to: SIMD3(3, 0, gatePoint.z))
                advance(0.8)
            }
            var gate = try state(gateDefinition.id)
            guard let collider = game.obstacles.first(where: { $0.id == gate.ownerObstacleID }),
                  let authored = map.obstacles.first(where: { $0.id == gate.ownerObstacleID }) else {
                throw Failure(message: "The service gate lost its physical collider.")
            }
            let target = collider.position + SIMD3(0, collider.size.y * 0.5, 0)
            aim(at: target)
            gate = try state(gateDefinition.id)
            switch scene {
            case "device-gate-closed":
                guard gate.gateProgress == 0 && !gate.isMoving else { throw Failure(message: "The closed gate moved unexpectedly.") }
            case "device-gate-moving":
                guard gate.gateProgress > 0.1 && gate.gateProgress < 0.9 && gate.isMoving else { throw Failure(message: "The moving gate did not preserve an intermediate state.") }
            case "device-gate-blocked":
                guard gate.blockedByActor, gate.gateProgress > 0, game.player.health == 100 else { throw Failure(message: "The closing gate did not safely wait for the player.") }
            default:
                guard gate.gateProgress == 1 && !gate.isMoving else { throw Failure(message: "The gate did not finish opening.") }
            }
            let currentCollider = game.obstacles.first { $0.id == gate.ownerObstacleID }!
            let expected = map.grounded(authored.position) + gateDefinition.openOffset * gate.gateProgress
            guard simd_distance(currentCollider.position, expected) < 0.001 else { throw Failure(message: "Gate progress and collider position disagree.") }
            if scene == "device-gate-blocked" {
                guard currentCollider.position.y >= game.player.position.y + game.player.height - 0.025 else {
                    throw Failure(message: "The blocked gate overlaps the player's body.")
                }
            }
        } else if lighting {
            if soldierScene && generatorOff { try walk(to: SIMD3(2, 0, 1)) }
            aim(at: soldierScene ? SIMD3(0, 1.1, -3) : SIMD3(0, 1, 0))
        } else if let owner = game.obstacles.first(where: { $0.id == generator.ownerObstacleID }) {
            aim(at: owner.position + SIMD3(0, owner.size.y * 0.55, 0))
        }
        guard game.loadout == loadout, game.state == .active else { throw Failure(message: "The device fixture changed its loadout or ended unexpectedly.") }
        let sunAfter = game.lightSample(at: sunProbe).directSun
        guard sunBefore == sunAfter, sunAfter > 0 else { throw Failure(message: "A device changed the unobstructed direct-sun probe.") }
        let generatorState = try state(generator.id)
        guard generatorState.enabled == !switchOff else { throw Failure(message: "The final generator state differs from its input history.") }
        var metadata: [String: Any] = [
            "scene": scene, "fixtureMap": map.id, "fixtureElapsed": game.elapsed,
            "generatorEnabled": generatorState.enabled, "activeSpotlights": game.spotlights.filter(\.enabled).count,
            "directSunBefore": sunBefore, "directSunAfter": sunAfter,
            "deviceActivations": records.filter { $0.kind == .deviceActivated }.count,
            "gateBlocks": records.filter { $0.kind == .gateBlocked }.count,
            "playerFeet": vector(game.player.position), "playerHealth": game.player.health,
            "devices": game.devices.map { value -> [String: Any] in
                ["id": value.id, "kind": value.kind.rawValue, "enabled": value.enabled, "powered": value.powered,
                 "destroyed": value.destroyed, "progress": value.gateProgress,
                 "moving": value.isMoving, "blockedByActor": value.blockedByActor]
            },
        ]
        if let gate = game.devices.first(where: { $0.kind == .serviceGate }),
           let collider = game.obstacles.first(where: { $0.id == gate.ownerObstacleID }) {
            metadata["gateColliderPosition"] = vector(collider.position)
            metadata["gateColliderSize"] = vector(collider.size)
            metadata["gatePowered"] = gate.powered
            metadata["gateProgress"] = gate.gateProgress
        }
        if lighting {
            let probe = SIMD3<Float>(0, 1, -3)
            let sample = game.lightSample(at: probe)
            let referenceMap = try lightMap(occluder: "device-light-daylight")
            let reference = CombatSimulation(world: referenceMap.obstacles, startingEnemies: [], startingWave: 3, map: referenceMap)
            let unblocked = reference.lightSample(at: probe).artificial
            guard unblocked > 0.05 else { throw Failure(message: "The reference light misses the actual diagnostic probe.") }
            let occluded = scene == "device-light-wall" || scene == "device-light-terrain"
            guard (occluded || switchOff) ? sample.artificial == 0 : sample.artificial > 0.05 else {
                throw Failure(message: "Light visibility disagrees with the wall, terrain or generator state.")
            }
            metadata["lightProbe"] = vector(probe)
            metadata["artificialAtProbe"] = sample.artificial
            metadata["unoccludedArtificialAtProbe"] = unblocked
            metadata["recognitionMultiplierAtProbe"] = sample.recognitionMultiplier
            if soldierScene, let soldier = game.enemies.first(where: { $0.id == 9850 }) {
                let eye = EnemyPose(soldier).eyePosition
                metadata["lightReceiverEnemyID"] = soldier.id
                metadata["lightReceiverEye"] = vector(eye)
                metadata["artificialAtSoldierEye"] = game.lightSample(at: eye).artificial
            }
        }
        return Result(simulation: game, metadata: metadata, events: records)
    }

    private static func vector(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }

    private static func lightMap(occluder: String) throws -> MapDefinition {
        var environment = MapEnvironmentDefinition()
        environment.devices = [WorldInteractableDefinition(id: 1001, kind: .generator, ownerObstacleID: 9802,
            interactionPoints: [SIMD3(8, 0, 8)], lightIDs: [8001])]
        environment.spotlights = [WorldSpotlightDefinition(id: 8001, position: SIMD3(0, 5.2, 5),
            direction: simd_normalize(SIMD3(0, -0.6, -1)))]
        var world = [Obstacle(id: 9802, kind: .container, position: SIMD3(8, 0, 6), size: SIMD3(1.6, 1.4, 1.2))]
        if occluder == "device-light-wall" {
            world.append(Obstacle(id: 9801, kind: .bunker, position: SIMD3(0, 0, 1), size: SIMD3(8, 5, 0.7)))
        }
        let terrain: TerrainProfile
        if occluder == "device-light-terrain" {
            var samples: [Float] = []
            for z in -20...20 { for x in -20...20 {
                let ridge = max(0, 1 - abs(Float(z) - 1) / 2)
                let width = max(0, 1 - max(0, abs(Float(x)) - 3) / 3)
                samples.append(ridge * width * 6)
            } }
            terrain = .heightField(try TerrainHeightField(origin: SIMD2(-20, -20), width: 41, depth: 41, samples: samples))
        } else { terrain = .flat }
        var scenery = MapSceneryDefinition()
        scenery.renderMinimum = SIMD2(-22, -22); scenery.renderMaximum = SIMD2(22, 22)
        scenery.denseMinimum = SIMD2(-20, -20); scenery.denseMaximum = SIMD2(20, 20)
        scenery.lightPoles = [SIMD3(-0.32, 0, 5)]
        return try MapDefinition(id: "diagnostic-\(occluder)", displayName: "Lichtprüfung", minimum: SIMD3(-20, 0, -20), maximum: SIMD3(20, 0, 20),
            terrain: terrain, obstacles: world, playerStart: PlayerState(position: SIMD3(8, 0, 8)),
            reinforcementEntries: [SIMD3(12, 0, -15)], waveStaging: [SIMD3(12, 0, -12)],
            extraction: SIMD3(12, 0, -15), dataSite: SIMD3(-12, 0, 12), radioSite: SIMD3(12, 0, 12),
            scenery: scenery, environment: environment, resources: .testRange)
    }
}
