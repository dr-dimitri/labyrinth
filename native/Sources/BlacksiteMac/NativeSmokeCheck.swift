import Foundation
import simd
import BlacksiteCore

/// Small authored diagnostic maps. Every cloud comes from an ordinary emitter
/// or throwable and advances on simulation ticks, never a renderer-only setter.
@MainActor
enum NativeSmokeCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["smoke-through", "smoke-edge", "smoke-inside", "smoke-wall", "smoke-overlap"]

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("smoke-") else { return nil }
        var seconds = 3.0
        if let time = arguments.firstIndex(of: "--seconds") {
            guard time + 1 < arguments.count, let value = Double(arguments[time + 1]) else {
                throw Failure(message: "Smoke --seconds requires a finite number from 0 to 20.")
            }
            seconds = value
        }
        let result = try makeScenario(scene: arguments[index + 1], seconds: seconds,
            above: arguments.contains("--above"), aiming: arguments.contains("--aim"),
            gateOpen: arguments.contains("--gate-open"), loadout: loadout)
        try renderer.setMap(result.simulation.map)
        // Old lifecycle events are metadata, not new combat FX at capture time.
        return result
    }

    static func makeScenario(scene: String, seconds: Double = 3, above: Bool = false,
                             aiming: Bool = false, gateOpen: Bool = false,
                             loadout: LoadoutDefinition = .init()) throws -> Result {
        guard scenes.contains(scene), seconds.isFinite, (0...20).contains(seconds),
              !above || scene == "smoke-through", !gateOpen || scene == "smoke-wall" else {
            throw Failure(message: "Smoke scenes: \(scenes.joined(separator: ", ")); --seconds 0…20, --above only through, --gate-open only wall.")
        }
        let wall = scene == "smoke-wall", overlap = scene == "smoke-overlap"
        let setupSeconds: Double = wall ? 12 : 0
        let map = try makeMap(wall: wall, overlap: overlap, above: above, emitterDelay: Float(setupSeconds))
        let lateral: Float = scene == "smoke-edge" ? 3.8 : 0
        let height: Float = above ? 5 : 0
        let camera = SIMD3<Float>(lateral, height, scene == "smoke-inside" ? 0.5 : 8)
        var player = PlayerState(position: wall ? SIMD3(6.9, 0, 0.8) : camera)
        let target = SIMD3<Float>(lateral, height + 1.62, -8)
        let direction = target - (player.position + SIMD3(0, 1.62, 0))
        player.yaw = atan2(-direction.x, -direction.z)
        player.pitch = overlap ? -0.8 : atan2(direction.y, simd_length(SIMD2(direction.x, direction.z)))
        var soldier = EnemyState(id: 9850, position: SIMD3(lateral, height, -8))
        soldier.yaw = .pi // Faces away initially; fixture metadata reports any later real perception.
        let game = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
            startingPlayer: player, startingEnemies: above ? [] : [soldier], startingWave: 3,
            map: map, loadout: loadout)
        if aiming { game.selectWeapon(.sniper) }
        var records: [GameEvent] = []
        var walked: Float = 0
        var input = GameInput(); input.yaw = player.yaw; input.pitch = player.pitch; input.aim = aiming
        func tick(_ controls: GameInput) {
            let before = game.player.position
            game.step(deltaTime: 1.0 / 120, input: controls)
            walked += simd_length(SIMD2(game.player.position.x - before.x, game.player.position.z - before.z))
            records.append(contentsOf: game.drainEvents())
        }
        func walk(to point: SIMD3<Float>) throws {
            for _ in 0..<1200 {
                let delta = SIMD2(point.x - game.player.position.x, point.z - game.player.position.z)
                if simd_length(delta) < 0.075 { return }
                var controls = GameInput(); controls.yaw = atan2(-delta.x, -delta.y); controls.moveForward = 1
                tick(controls)
            }
            throw Failure(message: "Smoke fixture could not walk its real gate route; reached \(game.player.position).")
        }
        if wall {
            guard game.deviceInteractionStatus?.id == 9802 else { throw Failure(message: "Smoke gate control is not reachable.") }
            input.interact = gateOpen
            for _ in 0..<240 { tick(input) }
            input.interact = false
            for _ in 0..<490 { tick(input) }
            guard let gate = game.devices.first(where: { $0.id == 9802 }),
                  gateOpen ? gate.gateProgress == 1 : gate.gateProgress == 0 else {
                throw Failure(message: "Real held interaction did not establish the requested gate state.")
            }
            try walk(to: SIMD3(6.9, 0, 8))
            try walk(to: camera)
            guard game.elapsed < setupSeconds else { throw Failure(message: "Gate preparation exceeded its explicit emitter delay.") }
        }

        var acceptedThrows = 0
        if overlap {
            guard game.throwSmokeGrenade() else { throw Failure(message: "First real smoke throw was rejected.") }
            acceptedThrows += 1
        }
        let finalTime = setupSeconds + max(1.0 / 120, seconds)
        while game.elapsed + 0.0000001 < finalTime {
            if overlap, acceptedThrows == 1, game.elapsed + 0.0000001 >= 0.75 {
                guard game.throwSmokeGrenade() else { throw Failure(message: "Second real smoke throw was rejected.") }
                acceptedThrows += 1
            }
            let aimDelta = target - game.eyePosition
            input.yaw = atan2(-aimDelta.x, -aimDelta.z)
            // Retain the downward launch pose until the second ordinary throw.
            input.pitch = overlap && acceptedThrows < 2 ? -0.8 : atan2(aimDelta.y, simd_length(SIMD2(aimDelta.x, aimDelta.z)))
            input.aim = aiming; input.interact = false; input.moveForward = 0
            tick(input)
        }
        guard game.state == .active, game.smokeVolumes.count <= SmokeVolumeState.maximumCount,
              game.smokeGrenadeCount == loadout.smokeGrenades - acceptedThrows else {
            throw Failure(message: "Smoke fixture lost its live state, volume bound, or real inventory accounting.")
        }
        let sample = game.smokeVisibility(from: game.eyePosition, to: target)
        let behindWall = SIMD3<Float>(0, 1.3, -1.8)
        let densityBehindWall = game.smokeVolumes.reduce(Float(0)) { $0 + $1.density(at: behindWall) }
        func vector(_ point: SIMD3<Float>) -> [Float] { [point.x, point.y, point.z] }
        let volumes: [[String: Any]] = game.smokeVolumes.map { volume in
            ["id": volume.id, "sourceEmitterID": volume.sourceEmitterID.map { $0 as Any } ?? NSNull(),
             "kind": volume.kind.rawValue, "age": volume.age, "lifetime": volume.lifetime,
             "position": vector(volume.position), "origin": vector(volume.origin),
             "radii": vector(volume.radii), "density": volume.density,
             "clipMinimum": vector(volume.clipMinimum), "clipMaximum": vector(volume.clipMaximum)]
        }
        return Result(simulation: game, metadata: [
            "scene": scene, "fixtureMap": map.id, "fixtureScope": "small diagnostic map; actual emitter, gate interaction and smoke throws",
            "requestedEffectSeconds": seconds, "preparationSeconds": setupSeconds, "fixtureElapsed": game.elapsed,
            "aboveSmoke": above, "scopeRequested": aiming, "gateOpen": gateOpen,
            "gateProgress": game.devices.first(where: { $0.id == 9802 })?.gateProgress as Any? ?? NSNull(),
            "playerFeet": vector(game.player.position), "playerEye": vector(game.eyePosition), "probeTarget": vector(target),
            "playerHealth": game.player.health, "walkedDistance": walked,
            "smokeVolumeCount": volumes.count, "smokeVolumes": volumes,
            "acceptedSmokeThrows": acceptedThrows, "smokeGrenadeInventory": game.smokeGrenadeCount,
            "flyingSmokeGrenades": game.smokeGrenades.count,
            "activatedSmokeEvents": records.filter { $0.kind == .smokeActivated }.count,
            "expiredSmokeEvents": records.filter { $0.kind == .smokeDissipated }.count,
            "opticalDepthToProbe": sample.opticalDepth, "transmissionToProbe": sample.transmission,
            "opaqueToProbe": sample.opaque, "cameraDensity": game.smokeVolumes.reduce(Float(0)) { $0 + $1.density(at: game.eyePosition) },
            "densityBehindWall": densityBehindWall,
            "soldierSeesPlayer": game.enemies.first?.seesPlayer ?? false,
            "soldierRecognition": game.enemies.first?.detectionProgress ?? 0
        ], events: records)
    }

    private static func makeMap(wall: Bool, overlap: Bool, above: Bool, emitterDelay: Float) throws -> MapDefinition {
        var world = [Obstacle(id: 9800, kind: .bunker, position: SIMD3(0, 0, -12), size: SIMD3(16, 4, 0.8)),
                     Obstacle(id: 9803, kind: .crate, position: SIMD3(-6, 0, -5), size: SIMD3(1.6, 1.7, 1.6))]
        var environment = MapEnvironmentDefinition()
        environment.shadowExtent = 40
        environment.smokeEmitters = [SmokeEmitterDefinition(id: 9820, kind: wall ? .steam : .smoke,
            position: SIMD3(0, 0, wall ? 0.5 : 0), radii: SIMD3(3, 2, 3),
            lifetime: 10, interval: 120, startDelay: emitterDelay)]
        if overlap {
            environment.smokeEmitters.append(SmokeEmitterDefinition(id: 9821, kind: .smoke,
                position: SIMD3(0.8, 0, 1.1), radii: SIMD3(3, 2, 3), lifetime: 10, interval: 120, startDelay: 0))
        }
        if wall {
            world.append(Obstacle(id: 9801, kind: .container, position: SIMD3(0, 0, -0.7), size: SIMD3(12, 2.8, 0.45)))
            environment.devices = [WorldInteractableDefinition(id: 9802, kind: .serviceGate,
                ownerObstacleID: 9801, interactionPoints: [SIMD3(6.9, 0, 0.8)], openOffset: SIMD3(0, 3.4, 0))]
        }
        if above {
            world.append(Obstacle(id: 9810, kind: .bunker, position: SIMD3(0, 0, 8), size: SIMD3(3, 5, 3)))
            world.append(Obstacle(id: 9811, kind: .bunker, position: SIMD3(0, 0, -8), size: SIMD3(3, 5, 3)))
        }
        return try MapDefinition(id: "diagnostic-smoke-\(wall ? "gate" : "volume")", displayName: "Rauchprüfung",
            minimum: SIMD3(-24, -1, -24), maximum: SIMD3(24, 12, 24), terrain: .flat, obstacles: world,
            playerStart: PlayerState(position: SIMD3(0, 0, 18)),
            reinforcementEntries: [SIMD3(20, 0, 20)], waveStaging: [SIMD3(18, 0, -18)],
            extraction: SIMD3(0, 0, -20), dataSite: SIMD3(-16, 0, 16), radioSite: SIMD3(16, 0, 16),
            environment: environment, resources: .testRange)
    }
}
