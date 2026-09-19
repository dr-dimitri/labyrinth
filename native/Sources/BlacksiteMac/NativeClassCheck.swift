import Foundation
import simd
import BlacksiteCore

/// Narrow, deterministic gadget checks. The selected kit is never replaced and
/// every post-start change comes from normal movement, aiming or gadget input.
@MainActor
enum NativeClassCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["class-recon", "class-charge", "class-smoke"]
    static let paneID = 9840, soldierID = 9850

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("class-") else { return nil }
        let scene = arguments[index + 1]
        var seconds: Double = scene == "class-charge" ? 1 : 3
        if let option = arguments.firstIndex(of: "--seconds") {
            guard option + 1 < arguments.count, let value = Double(arguments[option + 1]) else {
                throw Failure(message: "Class --seconds requires a finite number from 0 to 14.")
            }
            seconds = value
        }
        let result = try makeScenario(scene: scene, seconds: seconds,
            hideMark: arguments.contains("--hide-mark"), retreat: arguments.contains("--retreat"), loadout: loadout)
        try renderer.setMap(result.simulation.map)
        // Current marks, attached charges and smoke are state-driven geometry.
        // The recorded old explosions are not replayed as new visual effects.
        return result
    }

    static func makeScenario(scene: String, seconds: Double? = nil, hideMark: Bool = false,
                             retreat: Bool = false, loadout: LoadoutDefinition) throws -> Result {
        let duration = seconds ?? (scene == "class-charge" ? 1 : 3)
        let expectedClass: OperatorClass
        switch scene {
        case "class-recon": expectedClass = .recon
        case "class-charge": expectedClass = .engineer
        case "class-smoke": expectedClass = .assault
        default: throw Failure(message: "Class scenes: \(scenes.joined(separator: ", ")).")
        }
        guard loadout.operatorClass == expectedClass else {
            throw Failure(message: "\(scene) requires --class \(expectedClass.rawValue); the selected kit is preserved.")
        }
        guard duration.isFinite, (0...14).contains(duration), !hideMark || scene == "class-recon",
              !retreat || scene == "class-charge" else {
            throw Failure(message: "Class --seconds accepts 0…14; --hide-mark only recon, --retreat only charge.")
        }
        let map = try makeMap(charge: scene == "class-charge")
        var player = map.playerStart
        if scene == "class-charge" { player.position.z = 1.4 }
        if scene == "class-smoke" { player.pitch = -0.7 }
        var soldier = EnemyState(id: soldierID, position: SIMD3(0, 0, -6))
        soldier.yaw = .pi
        let game = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
            startingPlayer: player, startingEnemies: scene == "class-recon" ? [soldier] : [],
            startingWave: 3, map: map, loadout: loadout)
        var records: [GameEvent] = []
        var walked: Float = 0
        var input = GameInput(); input.yaw = player.yaw; input.pitch = player.pitch
        let initialHealth = game.player.health
        func drain() { records.append(contentsOf: game.drainEvents()) }
        func tick(_ controls: GameInput) {
            let before = game.player.position
            game.step(deltaTime: 1.0 / 120, input: controls)
            walked += simd_length(SIMD2(game.player.position.x - before.x, game.player.position.z - before.z))
            drain()
        }
        func look(at point: SIMD3<Float>) {
            let delta = point - game.eyePosition
            input.yaw = atan2(-delta.x, -delta.z)
            input.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
        }
        var initialMark: ReconMark?
        var invalidAttemptRejected = false
        if scene == "class-recon" {
            invalidAttemptRejected = !game.useClassGadget() // ADS is genuinely required.
            look(at: EnemyPose(soldier).headCenter)
            input.aim = true; tick(input)
        } else if scene == "class-charge" {
            input.pitch = 1.1; tick(input) // Sky is not an eligible access surface.
            invalidAttemptRejected = !game.useClassGadget() && game.breachChargeCount == loadout.breachCharges
            input.pitch = 0; tick(input)
        } else { tick(input) }
        guard game.useClassGadget() else { throw Failure(message: "The selected class's real gadget action was rejected.") }
        drain()
        if scene == "class-recon" { initialMark = game.reconMarks.first }
        let repeatedAttemptRejected = !game.useClassGadget()
        drain()
        guard repeatedAttemptRejected else { throw Failure(message: "An immediate duplicate gadget press created an extra object.") }
        let activatedAt = game.elapsed

        // Movement is part of the same post-activation simulation clock. A
        // short requested capture time may show the actor still on this route.
        let ticks = Int(ceil(duration * 120))
        for _ in 0..<ticks {
            if game.state != .active { break }
            if hideMark, game.player.position.x > -6 {
                input.aim = false; input.yaw = 0; input.pitch = 0
                input.moveRight = -1
            } else if retreat, game.player.position.z < 6 {
                input.aim = false; input.yaw = 0; input.pitch = 0
                input.moveForward = -1
            } else {
                input.moveRight = 0; input.moveForward = 0
                if let initialMark { look(at: initialMark.position); input.aim = !hideMark }
                else if scene == "class-smoke" { input.pitch = -0.25 }
            }
            tick(input)
        }
        if let initialMark, let remaining = game.reconMarks.first {
            guard initialMark == remaining else { throw Failure(message: "An observed contact was silently updated instead of retaining its historical point.") }
        }
        let markEvents = records.filter { $0.kind == .reconMarked }
        let placedEvents = records.filter { $0.kind == .breachChargePlaced }
        let detonations = records.filter { $0.kind == .breachChargeDetonated }
        let smokeThrows = records.filter { $0.kind == .throwSmoke }
        guard game.loadout == loadout, game.grenadeCount == loadout.fragmentationGrenades,
              game.noiseDecoyCount == loadout.noiseDecoys,
              game.weapons[.rifle]?.ammo == WeaponKind.rifle.capacity,
              game.weapons[.rifle]?.reserve == loadout.rifleReserve,
              markEvents.count == (scene == "class-recon" ? 1 : 0),
              placedEvents.count == (scene == "class-charge" ? 1 : 0),
              smokeThrows.count == (scene == "class-smoke" ? 1 : 0),
              game.smokeGrenadeCount == loadout.smokeGrenades - smokeThrows.count,
              game.breachChargeCount == loadout.breachCharges - placedEvents.count else {
            throw Failure(message: "Class fixture lost its selected equipment, ordinary action or inventory accounting.")
        }
        func vector(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }
        let charge = game.breachCharges.first
        let target = game.enemies.first { $0.id == soldierID }
        return Result(simulation: game, metadata: [
            "scene": scene, "fixtureMap": map.id,
            "fixtureScope": "small gadget diagnostic; actual input and optional walking, not a complete operation",
            "operatorClass": loadout.operatorClass.rawValue, "camouflage": loadout.camouflage.rawValue,
            "requestedEffectSeconds": duration, "actualEffectSeconds": game.elapsed - activatedAt,
            "fixtureElapsed": game.elapsed, "invalidPlacementOrAimRejected": invalidAttemptRejected,
            "duplicateAttemptRejected": repeatedAttemptRejected,
            "playerFeet": vector(game.player.position), "playerHealth": game.player.health,
            "selfDamage": initialHealth - game.player.health, "matchState": game.state.rawValue,
            "walkedDistance": walked, "hideMark": hideMark, "retreat": retreat,
            "reconMarkedEvents": markEvents.count, "reconMarkCount": game.reconMarks.count,
            "visibleReconMarkCount": game.visibleReconMarks.count,
            "observedPoint": initialMark.map { vector($0.position) } as Any? ?? NSNull(),
            "observedAt": initialMark.map { $0.createdAt } as Any? ?? NSNull(),
            "markExpiresAt": initialMark.map { $0.expiresAt } as Any? ?? NSNull(),
            "actualSoldierFeet": target.map { vector($0.position) } as Any? ?? NSNull(),
            "chargePlacedEvents": placedEvents.count, "chargeDetonatedEvents": detonations.count,
            "activeCharges": game.breachCharges.count, "chargeRemaining": game.breachChargeCount,
            "chargePosition": charge.map { vector($0.position) } as Any? ?? NSNull(),
            "chargeNormal": charge.map { vector($0.normal) } as Any? ?? NSNull(),
            "chargeAttached": charge.map { $0.attached } as Any? ?? NSNull(),
            "chargeFuse": charge.map { $0.fuse } as Any? ?? NSNull(),
            "breachOpen": game.breaches.first?.isOpen ?? false,
            "explosionEvents": records.filter { $0.kind == .explosion }.count,
            "smokeThrows": smokeThrows.count, "smokeRemaining": game.smokeGrenadeCount,
            "smokeVolumes": game.smokeVolumes.count, "flyingSmokeGrenades": game.smokeGrenades.count,
            "fragmentationRemaining": game.grenadeCount, "decoyRemaining": game.noiseDecoyCount,
            "rifleReserve": game.weapons[.rifle]!.reserve
        ], events: records)
    }

    private static func makeMap(charge: Bool) throws -> MapDefinition {
        var world = [Obstacle(id: 9844, kind: .bunker, position: SIMD3(-3.5, 0, 3), size: SIMD3(2.5, 3.2, 0.6)),
                     Obstacle(id: 9845, kind: .crate, position: SIMD3(4, 0, -7), size: SIMD3(1.8, 1.8, 1.8))]
        if charge {
            world.append(contentsOf: [
                Obstacle(id: paneID, kind: .accessPanel, position: .zero, size: SIMD3(3.2, 2.8, 0.15)),
                Obstacle(id: 9841, kind: .bunker, position: SIMD3(-4.6, 0, 0), size: SIMD3(6, 3, 0.5)),
                Obstacle(id: 9842, kind: .bunker, position: SIMD3(4.6, 0, 0), size: SIMD3(6, 3, 0.5)),
                Obstacle(id: 9843, kind: .bunker, position: SIMD3(0, 2.8, 0), size: SIMD3(3.2, 0.2, 0.5))
            ])
        }
        return try MapDefinition(id: "diagnostic-class-\(charge ? "charge" : "field")", displayName: "Klassenprüfung",
            minimum: SIMD3(-20, -1, -20), maximum: SIMD3(20, 8, 20), terrain: .flat,
            obstacles: world, playerStart: PlayerState(position: SIMD3(0, 0, 9)),
            reinforcementEntries: [SIMD3(18, 0, 18)], waveStaging: [SIMD3(16, 0, -16)],
            extraction: SIMD3(0, 0, -17), dataSite: SIMD3(-16, 0, -10), radioSite: SIMD3(16, 0, -10),
            resources: .testRange, breaches: charge ? [MapBreachDefinition(ownerObstacleID: paneID,
                kind: .lightPanel, visibility: .opaque, frameObstacleIDs: [9841, 9842, 9843])] : [])
    }
}
