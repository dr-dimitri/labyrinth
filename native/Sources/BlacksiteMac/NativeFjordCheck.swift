import Foundation
import simd
import BlacksiteCore

/// Fixed, authored camera starts for visual and budget checks, not a claimed
/// mission playthrough. AI, warning schedules and grenade physics run normally.
@MainActor
enum NativeFjordCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["fjord-overview", "fjord-rocks", "fjord-modules", "fjord-radome", "fjord-coast",
                         "fjord-warning", "fjord-spray", "fjord-aftermath"]
    static let seed: UInt64 = 1745

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("fjord-") else { return nil }
        var seconds: Double?
        if let time = arguments.firstIndex(of: "--seconds") {
            guard time + 1 < arguments.count, let value = Double(arguments[time + 1]) else {
                throw Failure(message: "Fjord --seconds requires a finite number from 0 to 12.")
            }
            seconds = value
        }
        return try makeScenario(scene: arguments[index + 1], seconds: seconds,
            noSpray: arguments.contains("--no-spray"), loadout: loadout, renderer: renderer)
    }

    static func makeScenario(scene: String, seconds: Double? = nil, noSpray: Bool = false,
                             loadout: LoadoutDefinition = .init(), renderer: NativeRenderer? = nil) throws -> Result {
        guard scenes.contains(scene), seconds.map({ $0.isFinite && (0...12).contains($0) }) ?? true else {
            throw Failure(message: "Fjord scenes: \(scenes.joined(separator: ", ")); --seconds 0…12.")
        }
        let original = MapDefinition.nebelwacht
        let map = try definition(disablingSpray: noSpray)
        guard original.spawns.count == 9, let source = original.environment.smokeEmitters.first else {
            throw Failure(message: "Nebelwacht diagnostics require its nine authored guard starts and first spray source.")
        }
        let emissionTime = source.firstEmissionTime(seed: seed)
        let defaultTime = scene == "fjord-warning" ? emissionTime - Double(source.warningLeadTime) + 0.5 :
            scene == "fjord-spray" ? emissionTime + 1.2 : scene == "fjord-aftermath" ? 4.45 : 0.25
        let finalTime = seconds ?? defaultTime
        guard (0...12).contains(finalTime), scene != "fjord-aftermath" || loadout.fragmentationGrenades >= 3 else {
            throw Failure(message: "The aftermath check needs a selected kit with at least three fragmentation grenades.")
        }

        func owner(_ id: Int) throws -> Obstacle {
            guard let value = map.obstacles.first(where: { $0.id == id }) else {
                throw Failure(message: "Missing authored Nebelwacht landmark \(id).")
            }
            return value
        }
        var feet = map.grounded(map.playerStart.position)
        var target = map.scenery.menuTarget
        switch scene {
        case "fjord-rocks":
            feet = map.grounded(NebelwachtDefinition.westRoute[2])
            let rock = try owner(2702)
            target = map.grounded(rock.position) + SIMD3(0, rock.size.y * 0.65, 0)
        case "fjord-modules":
            let step = try owner(2713), module = try owner(2711)
            feet = map.grounded(step.position + SIMD3(-3.5, 0, 6))
            target = map.grounded(module.position) + SIMD3(0, module.size.y * 0.72, 0)
        case "fjord-radome":
            feet = map.grounded(map.radioSite)
            let support = try owner(2721)
            target = map.grounded(support.position) + SIMD3(0, support.size.y + 1, 0)
        case "fjord-coast":
            feet = map.grounded(SIMD3(33, 0, -8))
            target = SIMD3(60, -1, -15)
        case "fjord-warning", "fjord-spray":
            feet = map.grounded(source.position + SIMD3(6, 0, 9))
            target = map.grounded(source.position) + SIMD3(-6, 1.3, -9)
        case "fjord-aftermath":
            target = map.grounded(map.playerStart.position + SIMD3(0, 0, -19)) + SIMD3(0, 0.5, 0)
        default: break
        }
        var player = PlayerState(position: feet)
        let look = target - (feet + SIMD3(0, player.height - 0.1, 0))
        player.yaw = atan2(-look.x, -look.z)
        player.pitch = atan2(look.y, simd_length(SIMD2(look.x, look.z)))
        if scene == "fjord-aftermath" { player.yaw = 0; player.pitch = -0.26 }
        let soldiers = map.spawns.enumerated().map { index, anchor -> EnemyState in
            var soldier = EnemyState(id: 9870 + index, position: map.grounded(anchor))
            // An explicit initial patrol orientation, never disabled AI or HP.
            soldier.yaw = atan2(soldier.position.x - feet.x, soldier.position.z - feet.z)
            return soldier
        }
        let game = CombatSimulation(difficulty: .easy, seed: seed, world: map.obstacles,
            startingPlayer: player, startingEnemies: soldiers, startingWave: 3, map: map, loadout: loadout)
        try renderer?.setMap(map)
        renderer?.reset()
        var records: [GameEvent] = [], acceptedThrows = 0
        var input = GameInput(); input.yaw = player.yaw; input.pitch = player.pitch
        let throwTimes = [0.0, 0.75, 1.5]
        func tick() {
            game.step(deltaTime: 1.0 / 120, input: input)
            let batch = game.drainEvents()
            records.append(contentsOf: batch)
            // Preserve each actual event's age. The returned history is never
            // replayed as three simultaneous explosions at the final camera.
            renderer?.handle(events: batch, simulation: game)
            renderer?.advanceEffects(deltaTime: 1.0 / 120, simulation: game)
        }
        while game.elapsed + 0.0000001 < finalTime {
            guard game.state == .active else {
                throw Failure(message: "Nebelwacht diagnostic ended during normal combat at \(game.elapsed) seconds.")
            }
            if scene == "fjord-aftermath", acceptedThrows < throwTimes.count,
               game.elapsed + 0.0000001 >= throwTimes[acceptedThrows] {
                guard game.throwGrenade() else { throw Failure(message: "An ordinary aftermath grenade throw was rejected.") }
                acceptedThrows += 1
            }
            if scene == "fjord-aftermath", acceptedThrows == 3 {
                let delta = target - game.eyePosition
                input.yaw = atan2(-delta.x, -delta.z)
                input.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
            }
            tick()
        }
        let live = game.enemies.filter { $0.health > 0 }
        let authoredIDs = Set(soldiers.map(\.id))
        let liveAuthored = live.filter { authoredIDs.contains($0.id) }
        let alarmArrivals = records.filter { $0.kind == .reinforcementsArrived && $0.alarmReportID != nil }
        let alarmArrivalIDs = Set(alarmArrivals.map(\.id))
        let liveReinforcements = live.filter { !authoredIDs.contains($0.id) }
        // An ordinary radio report may deploy the authored two-person group.
        // Preserve that real combat outcome and report its additional cost;
        // never suppress awareness or discard actors merely to keep nine.
        guard game.state == .active, liveAuthored.count == 9,
              alarmArrivals.count == alarmArrivalIDs.count, alarmArrivalIDs.count <= 2,
              liveReinforcements.allSatisfy({ alarmArrivalIDs.contains($0.id) }),
              live.count <= 11, game.loadout == loadout,
              game.grenadeCount == loadout.fragmentationGrenades - acceptedThrows,
              game.smokeVolumes.count <= SmokeVolumeState.maximumCount else {
            let alarms = records.filter { $0.kind == .alarmEscalated }.count
            let arrivals = records.filter { $0.kind == .reinforcementsArrived }.count
            throw Failure(message: "Nebelwacht \(scene) at \(game.elapsed)s: state=\(game.state.rawValue), live=\(live.count) IDs=\(live.map(\.id)), alarm=\(game.alarmStatus.escalated), committed=\(game.alarmStatus.reinforcementsCommitted), escalationEvents=\(alarms), arrivalEvents=\(arrivals), loadoutMatches=\(game.loadout == loadout), grenades=\(game.grenadeCount)/\(loadout.fragmentationGrenades - acceptedThrows), volumes=\(game.smokeVolumes.count)/\(SmokeVolumeState.maximumCount).")
        }
        if scene == "fjord-warning", seconds == nil, !noSpray {
            guard game.smokeWarnings.contains(where: { $0.emitterID == source.id }), game.smokeVolumes.isEmpty else {
                throw Failure(message: "The warning view missed the actual pre-emission window.")
            }
        }
        if scene == "fjord-spray", seconds == nil, !noSpray {
            guard game.smokeVolumes.contains(where: { $0.sourceEmitterID == source.id && $0.density > 0 }) else {
                throw Failure(message: "The spray view contains no real active source volume.")
            }
        }
        let explosions = records.filter { $0.kind == .explosion }
        if scene == "fjord-aftermath", seconds == nil {
            guard acceptedThrows == 3, explosions.count == 3, game.grenades.isEmpty else {
                throw Failure(message: "The aftermath view did not complete all three ordinary grenade fuses.")
            }
        }
        func vector(_ point: SIMD3<Float>) -> [Float] { [point.x, point.y, point.z] }
        let optical = game.smokeVisibility(from: game.eyePosition, to: target)
        let warnings: [[String: Any]] = game.smokeWarnings.map { warning in
            ["emitterID": warning.emitterID, "kind": warning.kind.rawValue, "cycle": warning.cycle,
             "beginsAt": warning.beginsAt, "startsAt": warning.startsAt, "position": vector(warning.position)]
        }
        let volumes: [[String: Any]] = game.smokeVolumes.map { volume in
            ["id": volume.id, "sourceEmitterID": volume.sourceEmitterID.map { $0 as Any } ?? NSNull(),
             "age": volume.age, "density": volume.density, "position": vector(volume.position),
             "radii": vector(volume.radii), "clipMinimum": vector(volume.clipMinimum), "clipMaximum": vector(volume.clipMaximum)]
        }
        let metadata: [String: Any] = [
            "scene": scene, "fixtureMap": map.id, "fixtureMapVersion": map.version, "fixtureSeed": seed,
            "fixtureScope": "authored camera start with nine normal guards plus any real bounded alarm arrivals; visual/budget diagnosis, not a mission playthrough",
            "requestedFixtureSeconds": finalTime, "fixtureElapsed": game.elapsed, "sprayDisabled": noSpray,
            "sourceFirstEmission": emissionTime, "warningLeadSeconds": source.warningLeadTime,
            "playerFeet": vector(game.player.position), "playerEye": vector(game.eyePosition),
            "cameraYaw": game.player.yaw, "cameraPitch": game.player.pitch, "probeTarget": vector(target),
            "playerHealth": game.player.health, "fixtureState": game.state.rawValue,
            "initialLiveSoldiers": soldiers.count, "liveAuthoredSoldiers": liveAuthored.count, "liveSoldiers": live.count,
            "liveAlarmReinforcements": liveReinforcements.count,
            "alarmEscalated": game.alarmStatus.escalated,
            "alarmReinforcementsCommitted": game.alarmStatus.reinforcementsCommitted,
            "alarmArrivalEvents": alarmArrivals.count, "alarmArrivalIDs": alarmArrivalIDs.sorted(),
            "soldiers": live.map { ["id": $0.id, "position": vector($0.position), "health": $0.health,
                "seesPlayer": $0.seesPlayer, "recognition": $0.detectionProgress] as [String: Any] },
            "warnings": warnings, "warningCount": warnings.count,
            "smokeVolumes": volumes, "smokeVolumeCount": volumes.count,
            "opticalDepthToProbe": optical.opticalDepth, "transmissionToProbe": optical.transmission,
            "opaqueToProbe": optical.opaque,
            "warningEvents": records.filter { $0.kind == .smokeWarning }.count,
            "activationEvents": records.filter { $0.kind == .smokeActivated }.count,
            "acceptedGrenadeThrows": acceptedThrows, "grenadeInventory": game.grenadeCount,
            "explosionEvents": explosions.count,
            "explosions": explosions.map { ["position": vector($0.position), "time": $0.hearing?.time ?? 0,
                "ageAtCapture": game.elapsed - ($0.hearing?.time ?? game.elapsed)] as [String: Any] },
            "destroyedCoverCount": game.obstacles.filter(\.destroyed).count,
            "coverDebrisCount": game.coverDebris.count,
            "operatorClass": loadout.operatorClass.rawValue, "camouflage": loadout.camouflage.rawValue
        ]
        return Result(simulation: game, metadata: metadata, events: records)
    }

    static func definition(disablingSpray: Bool) throws -> MapDefinition {
        let map = MapDefinition.nebelwacht
        guard disablingSpray else { return map }
        var environment = map.environment
        environment.smokeEmitters = []
        return try MapDefinition(id: map.id, version: map.version, displayName: map.displayName,
            minimum: map.minimum, maximum: map.maximum, terrain: map.terrain, obstacles: map.obstacles,
            playerStart: map.playerStart, spawns: map.spawns, reinforcementEntries: map.reinforcementEntries,
            waveStaging: map.waveStaging, extraction: map.extraction, extractionRadius: map.extractionRadius,
            dataSite: map.dataSite, radioSite: map.radioSite, serviceApproach: map.serviceApproach,
            roads: map.roads, supportSurfaces: map.supportSurfaces, levelProps: map.levelProps,
            scenery: map.scenery, environment: environment, resources: map.resources,
            operation: map.operation, breaches: map.breaches)
    }
}
