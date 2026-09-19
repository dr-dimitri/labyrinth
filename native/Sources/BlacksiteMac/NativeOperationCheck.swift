import Foundation
import simd
import BlacksiteCore

/// Blacksite objective snapshots plus a compact, explicitly separate timer map.
/// Complete combat-isolated Blacksite route coverage belongs to the Core tests.
@MainActor
enum NativeOperationCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["operation-preparation", "operation-exits", "operation-route"]

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("operation-") else { return nil }
        let result = try makeScenario(scene: arguments[index + 1],
            blockedService: arguments.contains("--blocked-service"), loadout: loadout)
        try renderer.setMap(result.simulation.map)
        // The image shows the final objective/world snapshot. Historical combat
        // events remain in metadata/tests instead of restarting old muzzle FX.
        return result
    }

    static func makeScenario(scene: String, blockedService: Bool = false,
                             loadout: LoadoutDefinition = .init()) throws -> Result {
        guard scenes.contains(scene), !blockedService || scene == "operation-route" else {
            throw Failure(message: "Operation scenes: operation-preparation, operation-exits, operation-route; --blocked-service applies to operation-route.")
        }
        let route = scene == "operation-route"
        let map = route ? try timerMap() : MapDefinition.blacksite
        var player = map.playerStart
        if scene == "operation-exits" {
            player.position = map.grounded(map.dataSite + SIMD3(0, 0, 1.3))
            let delta = map.grounded(map.dataSite + SIMD3(0, 0.25, 0)) -
                (player.position + SIMD3(0, player.height - 0.1, 0))
            player.yaw = atan2(-delta.x, -delta.z)
            player.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
        } else { player.position = map.grounded(player.position) }
        var world = map.obstacles
        if blockedService {
            // A real physical obstruction exists from scenario initialization;
            // no objective phase or actor is teleported to produce the fallback.
            world.append(Obstacle(id: 9891, kind: .container, position: SIMD3(4, 0, -4), size: SIMD3(3, 3, 3)))
        }
        let game = CombatSimulation(difficulty: .easy, seed: 1745, world: world,
            startingPlayer: player, mission: .operation, map: map, loadout: loadout)
        var events: [GameEvent] = []
        var walkedDistance: Float = 0
        var firstProgress: Float = 0, resetProgress: Float = 0
        func tick(_ input: GameInput) {
            let before = game.player.position
            game.step(deltaTime: 1.0 / 120, input: input)
            walkedDistance += simd_length(SIMD2(game.player.position.x - before.x, game.player.position.z - before.z))
            events.append(contentsOf: game.drainEvents())
        }
        func hold(_ ticks: Int, interact: Bool = false) {
            var input = GameInput(); input.yaw = game.player.yaw; input.pitch = game.player.pitch
            input.interact = interact
            for _ in 0..<ticks { tick(input) }
        }
        func walk(to point: SIMD3<Float>) throws {
            for _ in 0..<1500 {
                let delta = SIMD2(point.x - game.player.position.x, point.z - game.player.position.z)
                if simd_length(delta) < 0.07 { return }
                guard game.state == .active else { break }
                var input = GameInput(); input.moveForward = 1
                input.yaw = atan2(-delta.x, -delta.y)
                tick(input)
            }
            throw Failure(message: "The operation fixture could not walk to \(point.x), \(point.z); reached \(game.player.position).")
        }
        func exit(_ id: String) throws -> ExtractionSnapshot {
            guard let value = game.operationStatus?.extractions.first(where: { $0.id == id }) else {
                throw Failure(message: "The operation fixture lost extraction \(id).")
            }
            return value
        }
        func look(at target: SIMD3<Float>) {
            let delta = target - game.eyePosition
            var input = GameInput()
            input.yaw = atan2(-delta.x, -delta.z)
            input.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
            tick(input)
        }

        if scene == "operation-preparation" {
            hold(1)
            guard game.missionStatus.phase == .prepareOperation,
                  game.operationStatus?.extractions.allSatisfy({ !$0.unlocked }) == true else {
                throw Failure(message: "The optional preparation scene unlocked extraction before its required objective.")
            }
        } else {
            guard game.missionInteractionAvailable else {
                throw Failure(message: "The operation fixture's initial data point is not usable.")
            }
            hold(96, interact: true)
            guard game.missionStatus.phase == .extract,
                  game.operationStatus?.extractions.allSatisfy({ $0.unlocked }) == true else {
                throw Failure(message: "Holding E for the real data objective did not unlock both extraction choices.")
            }
            if route {
                try walk(to: exit("north").position)
                hold(48)
                firstProgress = try exit("north").progress
                guard firstProgress > 0, firstProgress < 3, game.operationStatus?.activeExtractionID == "north" else {
                    throw Failure(message: "Entering the first exit did not start its own timer.")
                }
                try walk(to: map.playerStart.position)
                resetProgress = try exit("north").progress
                guard resetProgress == 0, game.operationStatus?.activeExtractionID == nil else {
                    throw Failure(message: "Walking out of the exit did not reset its timer.")
                }
                let next = blockedService ? "north" : "service"
                guard try exit("service").blocked == blockedService else {
                    throw Failure(message: "The alternative exit's physical obstruction was not reflected in its status.")
                }
                try walk(to: exit(next).position)
                hold(24)
                guard game.operationStatus?.activeExtractionID == next,
                      game.operationStatus?.selectedExtractionID == next,
                      try exit(next).progress > 0, try exit(next).progress < 1.5 else {
                    throw Failure(message: "Re-entering the usable exit carried a previous timer or failed to select the exit.")
                }
            }
        }

        if route, let active = game.operationStatus?.extractions.first(where: { $0.active }) {
            // The player really stands inside this ring. Look toward its near
            // northern lamps using ordinary input, preserving feet and phase.
            look(at: active.position + SIMD3(0, 0.04, -active.radius * 0.65))
        } else if scene == "operation-exits", let target = game.missionStatus.objectivePosition {
            // The distant exit may be occluded by Blacksite's actual scenery;
            // only the view direction changes after the data interaction.
            look(at: target + SIMD3(0, 1.2, 0))
        }

        guard let status = game.operationStatus, status.extractions.count == 2,
              game.state == .active, game.loadout == loadout else {
            throw Failure(message: "The operation fixture lost its active objective, choices or loadout.")
        }
        let phaseEvents = events.compactMap { $0.missionPhase?.rawValue }
        for phase in [MissionPhase.prepareOperation, .collectData, .extract] {
            let expected = scene == "operation-preparation" && phase != .prepareOperation ? 0 : 1
            guard phaseEvents.filter({ $0 == phase.rawValue }).count == expected else {
                throw Failure(message: "The operation emitted an unexpected number of \(phase.rawValue) phase events.")
            }
        }
        let exits: [[String: Any]] = status.extractions.map {
            ["id": $0.id, "title": $0.title, "position": [$0.position.x, $0.position.y, $0.position.z],
             "radius": $0.radius, "requiredSeconds": $0.requiredProgress, "progressSeconds": $0.progress,
             "unlocked": $0.unlocked, "blocked": $0.blocked, "active": $0.active,
             "interruption": $0.interruption?.rawValue ?? "none", "routeKind": $0.routeKind.rawValue]
        }
        let metadata: [String: Any] = [
            "scene": scene, "fixtureMap": map.id, "fixtureElapsed": game.elapsed,
            "fixtureScope": route ? "small diagnostic map: real walking, exit reset/switch/fallback" : "Blacksite objective snapshot; not a complete combat playthrough",
            "missionKind": game.missionKind.rawValue, "missionPhase": game.missionStatus.phase.rawValue,
            "missionPhaseEvents": phaseEvents, "operationExtractions": exits,
            "selectedExtractionID": status.selectedExtractionID ?? "none",
            "activeExtractionID": status.activeExtractionID ?? "none",
            "blockedService": blockedService, "walkedDistance": walkedDistance,
            "firstExitProgress": firstProgress, "progressAfterLeaving": resetProgress,
            "playerFeet": [game.player.position.x, game.player.position.y, game.player.position.z],
            "playerYaw": game.player.yaw, "playerPitch": game.player.pitch,
            "playerHealth": game.player.health, "pendingReinforcements": game.pendingReinforcements,
            "aliveEnemies": game.aliveCount, "winEvents": events.filter { $0.kind == .win }.count,
            "deviceActivations": events.filter { $0.kind == .deviceActivated }.count
        ]
        return Result(simulation: game, metadata: metadata, events: events)
    }

    private static func timerMap() throws -> MapDefinition {
        let exits = [
            ExtractionDefinition(id: "north", title: "Prüfausgang Nord", detail: "Diagnosefläche ohne Schutzversprechen",
                position: SIMD3(-4, 0, -4), radius: 1.25, routeKind: .exposed),
            ExtractionDefinition(id: "service", title: "Zweiter Prüfausgang", detail: "Diagnosefläche ohne Schutzversprechen",
                position: SIMD3(4, 0, -4), radius: 1.25, routeKind: .exposed)
        ]
        let wall = Obstacle(id: 9890, kind: .bunker, position: SIMD3(10, 0, 12), size: SIMD3(10, 4, 6))
        return try MapDefinition(id: "diagnostic-operation-timers", displayName: "Operations-Timerprüfung",
            minimum: SIMD3(-24, 0, -24), maximum: SIMD3(24, 0, 24), terrain: .flat,
            obstacles: [wall], playerStart: PlayerState(position: SIMD3(0, 0, 1)),
            reinforcementEntries: [SIMD3(20, 0, 20)], waveStaging: [SIMD3(18, 0, -18)],
            extraction: exits[0].position, dataSite: .zero, radioSite: SIMD3(-12, 0, 10),
            resources: MapDefinition.testRange.resources, operation: MapOperationDefinition(extractions: exits))
    }
}
