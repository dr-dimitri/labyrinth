import Foundation
import simd
import BlacksiteCore

/// Real mission transitions for deterministic renderer checks; no state setters.
@MainActor
enum NativeMissionCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
    }
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer) throws -> Result? {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i+1 < arguments.count else { return nil }
            return arguments[i+1]
        }
        guard let name = value("--scene"), name.hasPrefix("mission-") else { return nil }
        guard ["mission-data", "mission-data-carried", "mission-radio", "mission-radio-active", "mission-radio-contested"].contains(name) else {
            throw CheckFailure(message: "Mission scenes: mission-data, mission-data-carried, mission-radio, mission-radio-active or mission-radio-contested.")
        }
        let data = name.hasPrefix("mission-data")
        let kind: MissionKind = data ? .recoverData : .secureRadio
        let map = MapDefinition.blacksite
        let point = data ? map.dataSite : map.radioSite
        let terrain = map.terrain
        let distance: Float = name == "mission-radio" ? 6.6 : 1.3
        var player = PlayerState(position: point+SIMD3(0,0,distance))
        let target = point+SIMD3(0,terrain.height(x:point.x,z:point.z)+0.20,0)
        let eye = player.position+SIMD3(0,terrain.height(x:player.position.x,z:player.position.z)+player.height-0.1,0)
        player.pitch = atan2(target.y-eye.y,distance)
        var enemies: [EnemyState] = []
        if name == "mission-radio-contested" {
            var guardState = EnemyState(id: 901, position: point+SIMD3(2,0,0))
            guardState.yaw = .pi/2
            enemies.append(guardState)
        }
        let simulation = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
                                          startingPlayer: player, startingEnemies: enemies, terrain: terrain, mission: kind, map: map)
        try renderer.setMap(simulation.map)
        var input = GameInput(); input.yaw = player.yaw; input.pitch = player.pitch
        var phases: [String] = [], arrivals = 0
        func advance(_ seconds: Double) {
            for _ in 0..<max(1,Int((seconds*120).rounded())) {
                simulation.step(deltaTime:1.0/120,input:input)
                let events = simulation.drainEvents()
                phases += events.compactMap { $0.missionPhase?.rawValue }
                arrivals += events.filter { $0.kind == .reinforcementsArrived }.count
                renderer.handle(events:events,simulation:simulation)
                renderer.advanceEffects(deltaTime:1.0/120,simulation:simulation)
            }
        }
        let interaction = name == "mission-data-carried" || name == "mission-radio-active" || name == "mission-radio-contested"
        input.interact = interaction
        advance(interaction ? 1.1 : 1.0/120)
        input.interact = false
        if let extra = value("--mission-seconds") {
            guard let seconds = Double(extra), seconds.isFinite, (0...20).contains(seconds) else {
                throw CheckFailure(message:"--mission-seconds requires 0 to 20 seconds.")
            }
            if seconds > 0 { advance(seconds) }
        }
        let status = simulation.missionStatus
        let expected: MissionPhase = data ? (interaction ? .extract : .collectData) : (interaction ? .holdRadio : .activateRadio)
        guard status.phase == expected else { throw CheckFailure(message:"Mission fixture did not reach its expected phase: \(expected.rawValue).") }
        if name == "mission-radio-contested", status.interruption != .contested {
            throw CheckFailure(message:"The nearby enemy did not contest the radio fixture.")
        }
        return Result(simulation:simulation,metadata:[
            "scene":name, "missionKind":kind.rawValue, "missionPhase":status.phase.rawValue,
            "missionProgressSeconds":status.progress, "missionRequiredSeconds":status.requiredProgress,
            "missionInterruption":status.interruption?.rawValue ?? "none", "missionPhaseEvents":phases,
            "missionArrivals":arrivals, "missionPendingReinforcements":simulation.pendingReinforcements,
            "missionAliveEnemies":simulation.aliveCount, "matchState":simulation.state.rawValue,
        ])
    }
}
