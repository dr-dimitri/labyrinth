import Foundation
import simd
import BlacksiteCore

/// A small combat-isolated diagnostic frontage. Damage and traversal use the
/// ordinary input path; no opening or position is assigned after construction.
@MainActor
enum NativeBreachCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["breach-intact", "breach-damaged", "breach-open"]
    static let ownerID = 9801, targetID = 9810

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("breach-") else { return nil }
        var kind = BreachKind.glass
        if let option = arguments.firstIndex(of: "--breach-kind") {
            guard option + 1 < arguments.count else {
                throw Failure(message: "Breach --breach-kind requires glass or panel.")
            }
            switch arguments[option + 1] {
            case "glass": kind = .glass
            case "panel": kind = .lightPanel
            default: throw Failure(message: "Breach --breach-kind requires glass or panel.")
            }
        }
        let result = try makeScenario(scene: arguments[index + 1], kind: kind,
                                      walkThrough: arguments.contains("--walk-through"), loadout: loadout)
        try renderer.setMap(result.simulation.map)
        // Cover stages, frame geometry and remains come from this final state.
        // Historical shots are evidence, not fresh muzzle flashes at capture.
        return result
    }

    static func makeScenario(scene: String, kind: BreachKind = .glass,
                             walkThrough: Bool = false,
                             loadout: LoadoutDefinition = .init()) throws -> Result {
        guard scenes.contains(scene), !walkThrough || scene == "breach-open" else {
            throw Failure(message: "Breach scenes: \(scenes.joined(separator: ", ")); --walk-through only with breach-open.")
        }
        let map = try makeMap(kind: kind)
        let game = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
            startingPlayer: map.playerStart, startingEnemies: [], startingWave: 3,
            map: map, loadout: loadout)
        var records: [GameEvent] = []
        var walked: Float = 0
        var controls = GameInput()
        controls.aim = true
        let originalTargetHealth = game.obstacles.first { $0.id == targetID }!.health
        let originalHealth = game.player.health
        var ownerShotIDs: [Int] = []
        var followupShotID: Int?
        func state() throws -> BreachState {
            guard let value = game.breaches.first(where: { $0.id == ownerID }) else {
                throw Failure(message: "Breach fixture lost its authored owner snapshot.")
            }
            return value
        }
        func tick(_ input: GameInput) -> [GameEvent] {
            let before = game.player.position
            game.step(deltaTime: 1.0 / 120, input: input)
            walked += simd_length(SIMD2(game.player.position.x - before.x, game.player.position.z - before.z))
            let events = game.drainEvents()
            records.append(contentsOf: events)
            return events
        }
        func shoot() throws -> GameEvent {
            var input = controls
            input.fire = true
            let shots = tick(input).filter { $0.kind == .shot }
            guard shots.count == 1, let shot = shots.first else {
                throw Failure(message: "Breach fixture's single held-input tick did not produce one accepted shot.")
            }
            // Let the actual weapon cooldown expire before the next request.
            for _ in 0..<(Int(ceil(WeaponKind.rifle.fireInterval * 120)) + 1) { _ = tick(controls) }
            return shot
        }
        _ = tick(controls)
        if scene != "breach-intact" {
            for _ in 0..<12 {
                let before = try state()
                if before.isOpen || (scene == "breach-damaged" && before.damageStage == .damaged) { break }
                let shot = try shoot()
                guard shot.surfaceImpact?.obstacleID == ownerID,
                      game.obstacles.first(where: { $0.id == targetID })?.health == originalTargetHealth else {
                    throw Failure(message: "An opening shot passed through the still-solid owner or damaged the object behind it.")
                }
                ownerShotIDs.append(ownerID)
            }
        }
        let snapshot = try state()
        let expected: CoverDamageStage = scene == "breach-intact" ? .intact : scene == "breach-damaged" ? .damaged : .destroyed
        guard snapshot.damageStage == expected else {
            throw Failure(message: "Ordinary rifle fire did not establish the requested breach stage.")
        }
        if snapshot.isOpen {
            let shot = try shoot()
            followupShotID = shot.surfaceImpact?.obstacleID
            guard followupShotID == targetID,
                  game.obstacles.first(where: { $0.id == targetID })!.health < originalTargetHealth else {
                throw Failure(message: "The follow-up shot could not pass through the actual open access.")
            }
        }
        if walkThrough {
            controls.aim = false
            controls.moveForward = 1
            for _ in 0..<600 {
                if game.player.position.z <= -3 { break }
                _ = tick(controls)
            }
            controls.moveForward = 0
            guard game.player.position.z <= -3, abs(game.player.position.x) < 0.05,
                  game.player.health == originalHealth else {
                throw Failure(message: "The player could not physically cross the opening without a hidden damage floor.")
            }
            // Look back through the crossed opening using ordinary camera input.
            controls.yaw = .pi
        }
        controls.aim = false
        controls.pitch = -0.12
        _ = tick(controls)
        let opened = records.filter { $0.kind == .breachOpened }
        let shots = records.filter { $0.kind == .shot }
        guard game.state == .active, opened.count == (snapshot.isOpen ? 1 : 0),
              game.weapons[.rifle]?.ammo == WeaponKind.rifle.capacity - shots.count,
              opened.allSatisfy({ $0.id == ownerID && $0.breach?.isOpen == true && $0.hearing?.kind == .breakage }),
              !game.coverDebris.contains(where: { $0.sourceObstacleID == ownerID && $0.solidObstacleID != nil }) else {
            throw Failure(message: "Breach events, inventory or passable-remains accounting is inconsistent.")
        }
        func vector(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }
        let captions = NativeNoisePresentation()
        captions.consume(events: records, simulation: game)
        return Result(simulation: game, metadata: [
            "scene": scene, "fixtureMap": map.id,
            "fixtureScope": "combat-isolated frontage; actual rifle inputs and optional straight walk, not a mission playthrough",
            "breachKind": kind.rawValue, "breachVisibility": snapshot.visibility.rawValue,
            "breachOwnerID": ownerID, "breachStage": snapshot.damageStage.rawValue,
            "breachPosition": vector(snapshot.position), "breachSize": vector(snapshot.size),
            "breachOpenedAt": snapshot.openedAt.map { $0 as Any } ?? NSNull(),
            "acceptedShots": shots.count, "openingShotOwnerIDs": ownerShotIDs,
            "followupShotOwnerID": followupShotID.map { $0 as Any } ?? NSNull(),
            "targetHealthBefore": originalTargetHealth,
            "targetHealthAfter": game.obstacles.first(where: { $0.id == targetID })!.health,
            "breachOpenedEvents": opened.count,
            "breakageHearingCount": opened.compactMap(\.hearing).count,
            "breakageSource": opened.first?.hearing.map { vector($0.position) } as Any? ?? NSNull(),
            "audibleCaptions": captions.lines,
            "walkThrough": walkThrough, "walkedDistance": walked,
            "playerFeet": vector(game.player.position), "playerHealth": game.player.health,
            "glassFootsteps": records.filter { $0.kind == .footstep && $0.hearing?.surface == .glass }.count,
            "frameObstacleIDs": map.breaches[0].frameObstacleIDs,
            "retainedFrames": game.obstacles.filter { map.breaches[0].frameObstacleIDs.contains($0.id) && !$0.destroyed }.count,
            "fixtureElapsed": game.elapsed, "rifleAmmo": game.weapons[.rifle]!.ammo
        ], events: records)
    }

    private static func makeMap(kind: BreachKind) throws -> MapDefinition {
        let world = [
            Obstacle(id: ownerID, kind: kind == .glass ? .glass : .accessPanel,
                position: .zero, size: SIMD3(3.2, 2.8, 0.15)),
            Obstacle(id: 9802, kind: .bunker, position: SIMD3(-5.6, 0, 0), size: SIMD3(8, 3, 0.5)),
            Obstacle(id: 9803, kind: .bunker, position: SIMD3(5.6, 0, 0), size: SIMD3(8, 3, 0.5)),
            Obstacle(id: 9804, kind: .bunker, position: SIMD3(0, 2.8, 0), size: SIMD3(3.2, 0.2, 0.5)),
            Obstacle(id: targetID, kind: .crate, position: SIMD3(0, 0, -6), size: SIMD3(2, 2, 2))
        ]
        return try MapDefinition(id: "diagnostic-breach-\(kind.rawValue)", displayName: "Zugangsprüfung",
            minimum: SIMD3(-18, -1, -18), maximum: SIMD3(18, 8, 18), terrain: .flat,
            obstacles: world, playerStart: PlayerState(position: SIMD3(0, 0, 6.4)),
            reinforcementEntries: [SIMD3(16, 0, 16)], waveStaging: [SIMD3(16, 0, -15)],
            extraction: SIMD3(0, 0, -15), dataSite: SIMD3(0, 0, -10), radioSite: SIMD3(14, 0, -10),
            resources: .testRange, breaches: [MapBreachDefinition(ownerObstacleID: ownerID, kind: kind,
                visibility: kind == .glass ? .clear : .opaque, frameObstacleIDs: [9802, 9803, 9804])])
    }
}
