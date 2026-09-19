import Foundation
import simd
import BlacksiteCore

/// Real authored machine state and a simulated decoy on the west bunker roof.
/// Rendering these scenes does not claim to verify the host's audio output.
@MainActor
enum NativeSoundCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
    }
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("sound-") else { return nil }
        let scene = arguments[index + 1]
        guard ["sound-machine", "sound-decoy"].contains(scene) else {
            throw CheckFailure(message: "Sound scenes: sound-machine or sound-decoy, optionally --machine-off.")
        }
        guard scene != "sound-decoy" || loadout.operatorClass == .recon else {
            throw CheckFailure(message: "sound-decoy requires --class recon; the selected kit is preserved.")
        }
        let map = MapDefinition.blacksite
        guard let authored = map.environment.noiseEmitters.first(where: { $0.id == 7001 }),
              let ownerID = authored.ownerObstacleID,
              let owner = map.obstacles.first(where: { $0.id == ownerID }),
              let roof = map.obstacles.first(where: { $0.id == 0 }) else {
            throw CheckFailure(message: "The sound fixture requires authored machine 7001, its real housing and the west bunker roof.")
        }
        let roofHeight = map.grounded(roof.position).y + roof.size.y
        let decoyScene = scene == "sound-decoy"
        let machineView = map.grounded(SIMD3(owner.position.x + 3.5, 0, owner.position.z + 3.5))
        var player = PlayerState(position: decoyScene ? SIMD3(-24.8, roofHeight, -7.8) : machineView)
        let source = map.grounded(authored.position)
        let aim = source - (player.position + SIMD3(0, player.height - 0.1, 0))
        player.yaw = atan2(-aim.x, -aim.z)
        player.pitch = atan2(aim.y, simd_length(SIMD2(aim.x, aim.z)))
        if decoyScene {
            // Throw onto a clear part of the real roof, away from the housing.
            player.yaw = -0.55; player.pitch = -0.85
        }
        let simulation = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
            startingPlayer: player, startingEnemies: [], startingWave: 3, map: map, loadout: loadout)
        try renderer.setMap(simulation.map)
        let enabled = !arguments.contains("--machine-off")
        _ = simulation.setNoiseEmitterEnabled(id: 7001, enabled: enabled)
        let initialStock = simulation.noiseDecoyCount
        if decoyScene, !simulation.throwNoiseDecoy() {
            throw CheckFailure(message: "The sound fixture could not throw its real noise decoy.")
        }
        var input = GameInput(); input.yaw = player.yaw; input.pitch = player.pitch
        var thrown = 0, pulses = 0, emitterChanges = 0
        var lastPulse: HearingStimulus?
        func drain() {
            let events = simulation.drainEvents()
            for event in events {
                if event.kind == .decoyThrown { thrown += 1 }
                if event.kind == .noiseEmitterChanged { emitterChanges += 1 }
                if event.kind == .decoyPulse {
                    pulses += 1; lastPulse = event.hearing
                }
            }
            renderer.handle(events: events, simulation: simulation)
        }
        drain()
        for _ in 0..<(decoyScene ? 264 : 12) {
            simulation.step(deltaTime: 1.0 / 120, input: input)
            drain()
            renderer.advanceEffects(deltaTime: 1.0 / 120, simulation: simulation)
        }
        guard let machine = simulation.noiseEmitters.first(where: { $0.id == 7001 }),
              machine.enabled == enabled, machine.ownerObstacleID == ownerID,
              simd_distance(machine.position, source) < 0.001,
              simulation.loadout == loadout else {
            throw CheckFailure(message: "The sound fixture lost its machine state, authored height, owner or loadout.")
        }
        let machineGain = simulation.noiseEmitterGain(machine, listener: simulation.eyePosition)
        guard !enabled ? machineGain == 0 : (decoyScene || machineGain > 0) else {
            throw CheckFailure(message: "The machine's acoustic gain does not match its simulation state.")
        }
        var metadata: [String: Any] = [
            "scene": scene, "operatorClass": loadout.operatorClass.rawValue,
            "machineID": machine.id, "machineOwnerID": machine.ownerObstacleID!,
            "machineEnabled": machine.enabled, "machineGainAtPlayer": machineGain,
            "machinePosition": [machine.position.x, machine.position.y, machine.position.z],
            "machineStateEvents": emitterChanges, "decoyThrows": thrown, "decoyPulses": pulses,
            "decoyRemaining": simulation.noiseDecoyCount, "activeDecoys": simulation.decoys.count,
            "fixtureSupport": decoyScene ? "west-bunker-roof" : "ground-near-authored-machine",
            "fixtureElapsed": simulation.elapsed,
            "playerFeet": [simulation.player.position.x, simulation.player.position.y, simulation.player.position.z]
        ]
        if decoyScene {
            guard thrown == 1, pulses > 0, simulation.noiseDecoyCount == initialStock - 1,
                  simulation.decoys.count == 1, let decoy = simulation.decoys.first,
                  simulation.environmentSample(at: simulation.player.position).supportingObstacleID == roof.id,
                  let lastPulse, lastPulse.sourceID == decoy.id, lastPulse.kind == .decoy,
                  decoy.position.x.isFinite, decoy.position.y.isFinite, decoy.position.z.isFinite,
                  decoy.position.y >= roofHeight + 0.08,
                  abs(decoy.position.x - roof.position.x) < roof.size.x * 0.5,
                  abs(decoy.position.z - roof.position.z) < roof.size.z * 0.5 else {
                throw CheckFailure(message: "The decoy fixture did not preserve its real throw, roof collision, pulse or inventory.")
            }
            let heard = simulation.acousticSample(for: lastPulse, listener: simulation.eyePosition)
            metadata["fixtureRoofHeight"] = roofHeight
            metadata["decoyPosition"] = [decoy.position.x, decoy.position.y, decoy.position.z]
            metadata["decoyAge"] = decoy.age
            metadata["decoyPulsePosition"] = [lastPulse.position.x, lastPulse.position.y, lastPulse.position.z]
            metadata["decoyPulseTime"] = lastPulse.time
            metadata["decoyPulseAudibleAtPlayer"] = heard.audible
            metadata["decoyPulseMaskingAtPlayer"] = heard.masking
        }
        return Result(simulation: simulation, metadata: metadata)
    }
}
