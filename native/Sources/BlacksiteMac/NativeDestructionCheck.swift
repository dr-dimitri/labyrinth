import Foundation
import BlacksiteCore

/// Exercises the authoritative shot/destruction/lifetime path for graphics QA.
@MainActor
enum NativeDestructionCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
    }
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer, simulation original: CombatSimulation) throws -> Result? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard (value("--scene") ?? "").hasPrefix("destruction-") else { return nil }
        let phase = value("--destruction-phase") ?? "damaged"
        guard ["intact", "damaged", "destroyed", "expired"].contains(phase),
              let source = original.obstacles.first(where: { $0.id == 801 }) else {
            throw CheckFailure(message: "--destruction-phase accepts intact, damaged, destroyed or expired in a destruction scene.")
        }
        guard let age = Double(value("--debris-age") ?? (phase == "expired" ? "30" : "3")), age.isFinite, (0...35).contains(age) else {
            throw CheckFailure(message: "--debris-age requires a finite value from 0 to 35 seconds.")
        }
        let shots = phase == "intact" ? 0 : Int(ceil(source.maximumHealth * (phase == "damaged" ? 0.5 : 1) / WeaponKind.rifle.damage))
        var simulation = original
        var input = GameInput(); input.yaw = simulation.player.yaw; input.pitch = simulation.player.pitch
        var acceptedShots = 0, destructionEvents = 0, explosions = 0
        func drain() {
            let events = simulation.drainEvents()
            acceptedShots += events.filter { $0.kind == .shot }.count
            destructionEvents += events.filter { $0.kind == .coverDestroyed }.count
            explosions += events.filter { $0.kind == .explosion }.count
            renderer.handle(events: events, simulation: simulation)
        }
        func step(_ seconds: Double) {
            var remaining = seconds
            while remaining > 0 {
                let dt = min(remaining, 1.0 / 120)
                simulation.step(deltaTime: dt, input: input)
                drain()
                renderer.advanceEffects(deltaTime: Float(dt), simulation: simulation)
                remaining = max(0, remaining - dt)
            }
        }
        for shot in 0..<shots {
            input.fire = true; step(1.0 / 120)
            input.fire = false
            if shot + 1 < shots { step(14.0 / 120) }
        }
        guard acceptedShots == shots else { throw CheckFailure(message: "Destruction fixture did not fire every requested shot.") }
        let expectedStage: CoverDamageStage = phase == "intact" ? .intact : phase == "damaged" ? .damaged : .destroyed
        guard simulation.obstacles.first(where: { $0.id == 801 })?.damageStage == expectedStage else {
            throw CheckFailure(message: "Real fixture shots did not produce the requested damage stage.")
        }
        step(age)
        let reset = arguments.contains("--destruction-reset")
        if reset {
            renderer.reset()
            guard let fresh = try NativeBattlefieldCheck.prepare(arguments: arguments, renderer: renderer) else {
                throw CheckFailure(message: "Destruction reset requires a valid battlefield fixture.")
            }
            simulation = fresh.simulation
            renderer.handle(events: simulation.drainEvents(), simulation: simulation)
        }
        return Result(simulation: simulation, metadata: [
            "destructionPhase": phase, "debrisAgeSeconds": age, "destructionFixtureShots": acceptedShots,
            "destructionFixtureSurface": arguments.contains("--destruction-hill") ? "hill" : "road",
            "destructionFixtureEvents": destructionEvents, "destructionFixtureExplosions": explosions,
            "destructionFixtureReset": reset, "destroyedSourceCount": simulation.obstacles.filter(\.destroyed).count,
            "sourceHealth": simulation.obstacles.first(where: { $0.id == 801 })?.health ?? 0,
            "sourceDamageStage": simulation.obstacles.first(where: { $0.id == 801 })?.damageStage.rawValue ?? "missing",
            "activeCoverDebris": simulation.coverDebris.count,
            "activeSolidDebris": simulation.coverDebris.filter { $0.solidObstacleID != nil }.count,
            "totalObstacleCount": simulation.obstacles.count,
            "fixtureState": simulation.state.rawValue,
        ])
    }
}
