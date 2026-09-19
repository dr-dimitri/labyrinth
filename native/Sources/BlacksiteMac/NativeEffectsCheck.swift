import Foundation
import simd
import BlacksiteCore

/// Fixed inputs for graphics QA; combat rules are exercised by the real shot path.
/// Explosion fixtures replay the same event format emitted by the simulation so
/// old/new renderers can be measured with identical simultaneous blast inputs.
@MainActor
enum NativeEffectsCheck {
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer, simulation: CombatSimulation) throws -> [String: Any] {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let impact = (value("--scene") ?? "").hasPrefix("impact-")
        guard impact || arguments.contains("--explosions") else { return [:] }
        guard let age = Float(value("--effect-age") ?? "0.20"), age.isFinite, (0...30).contains(age) else {
            throw CheckFailure(message: "--effect-age requires a finite value between 0 and 30 seconds.")
        }
        guard let blasts = Int(value("--explosions") ?? "0"), (0...256).contains(blasts) else {
            throw CheckFailure(message: "--explosions accepts an integer from 0 to 256 (bounded-pool QA).")
        }
        let blastSurface = value("--blast-surface") ?? "road"
        guard ["road", "roof", "hill"].contains(blastSurface) else {
            throw CheckFailure(message: "--blast-surface accepts road, roof or hill.")
        }
        var acceptedShots = 0
        if impact {
            guard let shots = Int(value("--impact-shots") ?? "1"), (1...30).contains(shots) else {
                throw CheckFailure(message: "--impact-shots accepts an integer from 1 to 30.")
            }
            var input = GameInput(); input.yaw = simulation.player.yaw; input.pitch = simulation.player.pitch
            for shot in 0..<shots {
                input.fire = true
                simulation.step(deltaTime: 1.0 / 120, input: input)
                let events = simulation.drainEvents()
                acceptedShots += events.filter { $0.kind == .shot }.count
                renderer.handle(events: events, simulation: simulation)
                if shot + 1 < shots {
                    input.fire = false
                    for _ in 0..<14 {
                        simulation.step(deltaTime: 1.0 / 120, input: input)
                        renderer.handle(events: simulation.drainEvents(), simulation: simulation)
                        renderer.advanceEffects(deltaTime: 1.0 / 120, simulation: simulation)
                    }
                }
            }
            guard acceptedShots == shots else { throw CheckFailure(message: "Impact fixture did not fire all requested real shots.") }
        }
        if blasts > 0 {
            var events: [GameEvent] = []
            for index in 0..<blasts {
                let spread = Float(index % 3 - 1)
                let x = blastSurface == "roof" ? 15 + spread * 2 : blastSurface == "hill" ? 16 + spread * 3 : spread * 3.2
                let z: Float = blastSurface == "roof" ? -4.5 : blastSurface == "hill" ? 27 : 9.5
                var floor = simulation.terrain.height(x: x, z: z)
                if blastSurface == "roof" {
                    guard let container = simulation.obstacles.first(where: { $0.id == 3 && !$0.destroyed }) else {
                        throw CheckFailure(message: "Roof blast fixture requires the map's intact container 3.")
                    }
                    floor = container.position.y + container.size.y
                }
                let position = SIMD3<Float>(x, floor + 0.18, z)
                events.append(GameEvent(kind: .explosion, position: position))
            }
            renderer.handle(events: events, simulation: simulation)
        }
        var remaining = age
        while remaining > 0 {
            let step = min(remaining, 1.0 / 120)
            renderer.advanceEffects(deltaTime: step, simulation: simulation)
            remaining = max(0, remaining - step)
        }
        let reset = arguments.contains("--effects-reset")
        if reset { renderer.reset() }
        return ["effectAgeSeconds": age, "fixtureExplosions": blasts,
                "fixtureBlastSurface": blastSurface,
                "fixtureAcceptedShots": acceptedShots,
                "fixtureDestroyedCover": simulation.obstacles.filter(\.destroyed).count,
                "fixtureEffectsReset": reset,
                "effectFixture": impact ? "real simulation shot" : "simultaneous explosion event replay"]
    }
}
