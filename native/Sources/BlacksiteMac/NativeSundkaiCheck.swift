import Foundation
import simd
import BlacksiteCore

/// Real short water actions on Sundkai, plus an explicitly separate compact
/// relay-order diagnosis. These captures do not claim a full combat playthrough.
@MainActor
enum NativeSundkaiCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["sundkai-overview", "sundkai-shore", "sundkai-wade", "sundkai-landing", "sundkai-impact", "sundkai-aftermath", "sundkai-contact", "sundkai-relays"]
    static let seed: UInt64 = 1745

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("sundkai-") else { return nil }
        return try makeScenario(scene: arguments[index + 1], noWater: arguments.contains("--no-water"),
            reverseRelays: arguments.contains("--reverse-relays"), loadout: loadout, renderer: renderer)
    }

    static func makeScenario(scene: String, noWater: Bool = false, reverseRelays: Bool = false,
                             loadout: LoadoutDefinition = .init(), renderer: NativeRenderer? = nil) throws -> Result {
        guard scenes.contains(scene), !reverseRelays || scene == "sundkai-relays",
              !noWater || scene != "sundkai-relays" else {
            throw Failure(message: "Sundkai scenes: \(scenes.joined(separator: ", ")); --reverse-relays only for relays, --no-water only for the real water-map views.")
        }
        let relayScene = scene == "sundkai-relays", contactScene = scene == "sundkai-contact"
        guard scene != "sundkai-aftermath" || loadout.fragmentationGrenades >= 3 else {
            throw Failure(message: "The Sundkai aftermath check needs a selected kit with at least three fragmentation grenades.")
        }
        let map = relayScene ? try relayMap() : try definition(disablingWater: noWater)
        let original = MapDefinition.sundkai
        guard let pool = original.environment.shallowWaterZones.first else {
            throw Failure(message: "Sundkai diagnostics require an authored shallow-water pool.")
        }
        let center = SIMD3<Float>((pool.minimum.x + pool.maximum.x) * 0.5, pool.surfaceHeight,
                                 (pool.minimum.y + pool.maximum.y) * 0.5)
        var feet = map.grounded(map.playerStart.position), target = map.scenery.menuTarget
        switch scene {
        case "sundkai-shore", "sundkai-wade", "sundkai-aftermath":
            feet = map.grounded(SIMD3(center.x, 0, pool.maximum.y + 1.4))
            target = center
        case "sundkai-landing", "sundkai-impact":
            feet = map.grounded(SIMD3(center.x, 0, center.z))
            target = map.grounded(SIMD3(center.x, 0, center.z - 2))
        case "sundkai-relays":
            feet = SIMD3(reverseRelays ? 2 : -2, 0, 1.25)
            target = SIMD3(feet.x, 0.7, 0)
        case "sundkai-contact":
            feet = map.grounded(SIMD3(5, 0, pool.maximum.y + 1.4))
            target = SIMD3(11, 2, 18)
        default: break
        }
        var player = PlayerState(position: feet)
        let initialLook = target - (feet + SIMD3(0, player.height - 0.1, 0))
        player.yaw = atan2(-initialLook.x, -initialLook.z)
        player.pitch = atan2(initialLook.y, simd_length(SIMD2(initialLook.x, initialLook.z)))
        if scene == "sundkai-aftermath" { player.yaw = 0; player.pitch = -0.26 }
        var soldierPositions = map.spawns.map { map.grounded($0) }
        if contactScene {
            guard let roof = map.obstacles.first(where: { $0.id == 2810 }) else {
                throw Failure(message: "The contact diagnostic requires actual container 2810.")
            }
            soldierPositions = [map.grounded(SIMD3(7.5,0,19)), map.grounded(SIMD3(11.1,0,19)),
                map.grounded(roof.position) + SIMD3(0,roof.size.y,0)]
        }
        let soldiers: [EnemyState] = relayScene ? [] : soldierPositions.enumerated().map { index, position in
            var soldier = EnemyState(id: 9880 + index, position: position)
            soldier.yaw = atan2(soldier.position.x - feet.x, soldier.position.z - feet.z)
            return soldier
        }
        guard relayScene || soldiers.count == (contactScene ? 3 : 9) else {
            throw Failure(message: "The Sundkai visual reference needs its nine authored, normally simulated guards.")
        }
        let game = CombatSimulation(difficulty: .easy, seed: seed, world: map.obstacles,
            startingPlayer: player, startingEnemies: soldiers, startingWave: 3,
            mission: relayScene ? .operation : .waves, map: map, loadout: loadout)
        try renderer?.setMap(map); renderer?.reset()
        var events: [GameEvent] = [], walkedDistance: Float = 0
        var airborneTicks = 0, airborneFootsteps = 0, acceptedJumps = 0, acceptedThrows = 0
        var firstCompleted: [String] = [], firstPhase = "", firstExitsLocked = false
        var input = GameInput(); input.yaw = player.yaw; input.pitch = player.pitch
        func tick(_ supplied: GameInput? = nil) throws {
            guard game.state == .active else { throw Failure(message: "Sundkai \(scene) ended during real simulation at \(game.elapsed)s: \(game.state.rawValue).") }
            let before = game.player.position
            game.step(deltaTime: 1.0 / 120, input: supplied ?? input)
            walkedDistance += simd_length(SIMD2(game.player.position.x - before.x, game.player.position.z - before.z))
            let batch = game.drainEvents()
            if !game.player.grounded {
                airborneTicks += 1
                airborneFootsteps += batch.filter { $0.kind == .footstep && $0.hearing?.source == .player }.count
            }
            events.append(contentsOf: batch)
            renderer?.handle(events: batch, simulation: game)
            renderer?.advanceEffects(deltaTime: 1.0 / 120, simulation: game)
        }
        func hold(_ ticks: Int, interact: Bool = false) throws {
            var stationary = input; stationary.moveForward = 0; stationary.moveRight = 0
            stationary.interact = interact; stationary.fire = false
            for _ in 0..<ticks { try tick(stationary) }
        }
        func look(at point: SIMD3<Float>) {
            let delta = point - game.eyePosition
            input.yaw = atan2(-delta.x, -delta.z)
            input.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
        }
        func walk(to point: SIMD3<Float>) throws {
            for _ in 0..<1800 {
                let delta = SIMD2(point.x - game.player.position.x, point.z - game.player.position.z)
                if simd_length(delta) < 0.055 { return }
                var movement = input; movement.interact = false; movement.fire = false
                movement.yaw = atan2(-delta.x, -delta.y); movement.moveForward = 1
                try tick(movement)
            }
            throw Failure(message: "Sundkai \(scene) could not walk to \(point.x),\(point.z); reached \(game.player.position).")
        }
        if relayScene {
            let order = reverseRelays ? ["east", "west"] : ["west", "east"]
            try hold(1)
            for (index, id) in order.enumerated() {
                guard let relay = map.operation?.requiredStages.first?.targets.first(where: { $0.id == id }) else {
                    throw Failure(message: "Diagnostic relay \(id) is missing.")
                }
                if index > 0 { try walk(to: relay.position + SIMD3(0, 0, 1.25)) }
                look(at: map.grounded(relay.position) + SIMD3(0, 0.7, 0))
                guard game.missionInteractionAvailable else { throw Failure(message: "Reached relay \(id) is not genuinely usable.") }
                try hold(120, interact: true)
                try hold(1)
                let completed = game.operationStatus?.stages.first?.targets.filter(\.completed).map(\.id) ?? []
                if index == 0 {
                    firstCompleted = completed; firstPhase = game.missionStatus.phase.rawValue
                    firstExitsLocked = game.operationStatus?.extractions.allSatisfy({ !$0.unlocked }) == true
                    guard completed == [id], game.missionStatus.phase == .activateRelays, firstExitsLocked else {
                        throw Failure(message: "One relay incorrectly completed the group or unlocked extraction.")
                    }
                }
            }
            guard game.missionStatus.phase == .collectData else { throw Failure(message: "Both relays did not unlock the real data stage.") }
            try walk(to: map.dataSite + SIMD3(0, 0, 1.2))
            look(at: map.grounded(map.dataSite) + SIMD3(0, 0.7, 0))
            try hold(96, interact: true); try hold(1)
            guard game.missionStatus.phase == .extract,
                  game.operationStatus?.stages.allSatisfy(\.completed) == true,
                  game.operationStatus?.extractions.allSatisfy(\.unlocked) == true else {
                throw Failure(message: "The real relay/data sequence failed to unlock both exits.")
            }
            look(at: SIMD3(0, 0.1, -9)); try hold(1)
        } else if scene == "sundkai-wade" {
            try walk(to: SIMD3(center.x, 0, center.z))
            look(at: center + SIMD3(0, -0.1, -3)); try hold(8)
        } else if scene == "sundkai-landing" {
            try hold(1)
            guard game.jump() else { throw Failure(message: "The ordinary jump from the water bed was rejected.") }
            acceptedJumps = 1
            for _ in 0..<240 {
                try tick()
                if game.player.grounded { break }
            }
            guard game.player.grounded, airborneTicks > 0, airborneFootsteps == 0 else {
                throw Failure(message: "The jump did not land physically or produced unsupported steps.")
            }
            try hold(6)
        } else if scene == "sundkai-aftermath" {
            let throwTimes = [0.0, 0.75, 1.5]
            while game.elapsed + 0.0000001 < 4.45 {
                if acceptedThrows < throwTimes.count, game.elapsed + 0.0000001 >= throwTimes[acceptedThrows] {
                    guard game.throwGrenade() else { throw Failure(message: "An ordinary Sundkai grenade throw was rejected.") }
                    acceptedThrows += 1
                }
                if acceptedThrows == 3 { look(at: center) }
                try tick()
            }
            guard acceptedThrows == 3, game.grenades.isEmpty,
                  events.filter({ $0.kind == .explosion }).count == 3 else {
                throw Failure(message: "The aftermath view did not complete all three ordinary grenade fuses.")
            }
        } else if scene == "sundkai-impact" {
            try hold(1)
            var shot = input; shot.fire = true; try tick(shot)
            try hold(7)
            guard events.filter({ $0.kind == .shot }).count == 1 else { throw Failure(message: "The water/bed fixture did not fire exactly one real round.") }
        } else { try hold(30) }
        let waterSteps = events.filter { $0.kind == .footstep && $0.hearing?.source == .player && $0.hearing?.surface == .water }
        let waterLandings = events.filter { $0.kind == .land && $0.hearing?.source == .player && $0.hearing?.surface == .water }
        let shots = events.filter { $0.kind == .shot }
        if !relayScene {
            let live = game.enemies.filter { $0.health > 0 }
            let originalIDs = Set(soldiers.map(\.id))
            let arrivals = Set(events.filter { $0.kind == .reinforcementsArrived && $0.alarmReportID != nil }.map(\.id))
            guard live.filter({ originalIDs.contains($0.id) }).count == soldiers.count, arrivals.count <= 2,
                  live.filter({ !originalIDs.contains($0.id) }).allSatisfy({ arrivals.contains($0.id) }) else {
                throw Failure(message: "Sundkai reference lost an authored guard or added an unexplained actor: live \(live.count), alarms \(arrivals.count).")
            }
            if !noWater {
                if scene == "sundkai-wade", waterSteps.isEmpty { throw Failure(message: "Real wading produced no actual water footsteps.") }
                if scene == "sundkai-landing", waterLandings.count != 1 { throw Failure(message: "The actual wet landing did not produce one water landing stimulus.") }
                if scene == "sundkai-impact", shots.first?.waterImpact == nil || shots.first?.surfaceImpact == nil {
                    throw Failure(message: "A downward shot must cross the water and stop at a physical bed surface.")
                }
            } else if !waterSteps.isEmpty || !waterLandings.isEmpty || events.contains(where: { $0.waterImpact != nil }) {
                throw Failure(message: "The explicitly water-disabled map still emitted a water contact or impact.")
            }
        }
        guard game.state == .active, game.loadout == loadout,
              game.grenadeCount == loadout.fragmentationGrenades - acceptedThrows else {
            throw Failure(message: "Sundkai fixture lost active state, selected loadout or real grenade inventory.")
        }
        func vector(_ point: SIMD3<Float>) -> [Float] { [point.x, point.y, point.z] }
        let contact = game.waterContact(at: game.player.position, grounded: game.player.grounded)
        let objectives = events.compactMap(\.operationObjective).map(\.id)
        let metadata: [String: Any] = [
            "scene": scene, "fixtureMap": map.id, "fixtureMapVersion": map.version, "fixtureSeed": seed,
            "fixtureScope": relayScene ? "small separate relay-order diagnosis: real held E and walking, not a Sundkai combat playthrough" : contactScene ? "separate three-soldier contact diagnosis: normal simulation on actual pool bed, shore and container roof; not a nine-guard budget scene or mission playthrough" : "short real Sundkai actions with nine normal authored guards and any actual alarm arrivals; not a mission playthrough",
            "waterDisabled": noWater, "reverseRelays": reverseRelays, "fixtureElapsed": game.elapsed,
            "playerFeet": vector(game.player.position), "playerEye": vector(game.eyePosition),
            "cameraYaw": game.player.yaw, "cameraPitch": game.player.pitch, "playerHealth": game.player.health,
            "walkedDistance": walkedDistance, "grounded": game.player.grounded,
            "waterContact": contact.map { ["zoneID": $0.zoneID, "depth": $0.depth, "surfaceHeight": $0.surfaceHeight, "supportHeight": $0.supportHeight, "movementMultiplier": $0.movementMultiplier] as Any } ?? NSNull(),
            "waterZones": map.environment.shallowWaterZones.map { ["id": $0.id, "surfaceHeight": $0.surfaceHeight, "minimum": [$0.minimum.x,$0.minimum.y], "maximum": [$0.maximum.x,$0.maximum.y]] as [String: Any] },
            "acceptedJumps": acceptedJumps, "airborneTicks": airborneTicks, "airborneFootsteps": airborneFootsteps,
            "waterFootsteps": waterSteps.count, "waterLandings": waterLandings.count,
            "waterSounds": (waterSteps + waterLandings).compactMap(\.hearing).map { ["kind": $0.kind.rawValue, "position": vector($0.position), "time": $0.time, "ageAtCapture": game.elapsed - $0.time] as [String: Any] },
            "shotEvents": shots.count, "waterImpactEvents": shots.filter { $0.waterImpact != nil }.count,
            "shotEndpoints": shots.map { vector($0.endPosition) }, "waterImpactPositions": shots.compactMap(\.waterImpact).map { vector($0.position) },
            "acceptedGrenadeThrows": acceptedThrows, "grenadeInventory": game.grenadeCount,
            "explosionEvents": events.filter { $0.kind == .explosion }.count,
            "waterExplosionEvents": events.filter { $0.kind == .explosion && $0.waterImpact != nil }.count,
            "explosions": events.filter { $0.kind == .explosion }.map {
                ["position": vector($0.position), "time": $0.hearing?.time ?? 0,
                 "ageAtCapture": game.elapsed - ($0.hearing?.time ?? game.elapsed),
                 "waterImpactPosition": $0.waterImpact.map { vector($0.position) as Any } ?? NSNull()] as [String: Any]
            },
            "initialLiveSoldiers": soldiers.count, "liveSoldiers": game.enemies.filter { $0.health > 0 }.count,
            "soldierContacts": game.enemies.filter { $0.health > 0 }.map { soldier in
                ["id": soldier.id, "feet": vector(soldier.position), "grounded": soldier.grounded,
                 "waterDepth": game.waterContact(at: soldier.position, grounded: soldier.grounded)?.depth ?? 0] as [String: Any]
            },
            "alarmArrivalEvents": events.filter { $0.kind == .reinforcementsArrived && $0.alarmReportID != nil }.count,
            "missionPhase": game.missionStatus.phase.rawValue, "objectiveCompletionOrder": objectives,
            "firstRelayCompletedIDs": firstCompleted, "phaseAfterFirstRelay": firstPhase, "exitsLockedAfterFirstRelay": firstExitsLocked,
            "unlockedExits": game.operationStatus?.extractions.filter(\.unlocked).map(\.id) ?? [],
            "operatorClass": loadout.operatorClass.rawValue, "camouflage": loadout.camouflage.rawValue
        ]
        return Result(simulation: game, metadata: metadata, events: events)
    }

    static func definition(disablingWater: Bool) throws -> MapDefinition {
        let map = MapDefinition.sundkai
        guard disablingWater else { return map }
        var environment = map.environment; environment.shallowWaterZones = []
        return try MapDefinition(id: map.id, version: map.version, displayName: map.displayName,
            minimum: map.minimum, maximum: map.maximum, terrain: map.terrain, obstacles: map.obstacles,
            playerStart: map.playerStart, spawns: map.spawns, reinforcementEntries: map.reinforcementEntries,
            waveStaging: map.waveStaging, extraction: map.extraction, extractionRadius: map.extractionRadius,
            dataSite: map.dataSite, radioSite: map.radioSite, serviceApproach: map.serviceApproach,
            roads: map.roads, supportSurfaces: map.supportSurfaces, levelProps: map.levelProps,
            scenery: map.scenery, environment: environment, resources: map.resources,
            operation: map.operation, breaches: map.breaches)
    }

    private static func relayMap() throws -> MapDefinition {
        let west = OperationTargetDefinition(id: "west", title: "Relais West", position: SIMD3(-2,0,0), ownerObstacleID: 2900)
        let east = OperationTargetDefinition(id: "east", title: "Relais Ost", position: SIMD3(2,0,0), ownerObstacleID: 2901)
        let housings = [-2.0 as Float, 2.0].enumerated().map { index, x in
            Obstacle(id: 2900 + index, kind: .bunker, position: SIMD3(x,0,-0.7), size: SIMD3(0.7,1.1,0.45))
        }
        let data = OperationTargetDefinition(id: "data", title: "Versanddaten", position: SIMD3(0,0,-3))
        let stages = [OperationStageDefinition(id: "relays", title: "Beide Relais", kind: .relayGroup, targets: [west,east]),
            OperationStageDefinition(id: "data", title: "Versanddaten", kind: .collectData, targets: [data], interactionDuration: 0.8)]
        let exits = [ExtractionDefinition(id: "service", title: "Service", detail: "Diagnose ohne Schutzversprechen", position: SIMD3(-8,0,-12), radius: 2, routeKind: .exposed),
            ExtractionDefinition(id: "harbor", title: "Hafen", detail: "Diagnose ohne Schutzversprechen", position: SIMD3(8,0,-12), radius: 2, routeKind: .exposed)]
        return try MapDefinition(id: "diagnostic-sundkai-relays", displayName: "Relais-Reihenfolge",
            minimum: SIMD3(-24,0,-24), maximum: SIMD3(24,10,24), terrain: .flat, obstacles: housings,
            playerStart: PlayerState(position: SIMD3(-2,0,1.25)), reinforcementEntries: [SIMD3(20,0,20)],
            waveStaging: [SIMD3(18,0,18)], extraction: exits[0].position, dataSite: data.position, radioSite: east.position,
            resources: MapDefinition.testRange.resources, operation: MapOperationDefinition(extractions: exits, requiredStages: stages))
    }
}
