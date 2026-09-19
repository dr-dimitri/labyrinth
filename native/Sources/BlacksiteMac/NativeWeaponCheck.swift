import Foundation
import BlacksiteCore

/// Exercises real gameplay events and the same visual simulation used by the app.
/// These switches only run in the existing command-line smoke/benchmark path.
@MainActor
enum NativeWeaponCheck {
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer, simulation: CombatSimulation) throws -> [String: Any] {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("--weapon") || arguments.contains("--shots") else { return [:] }
        let weaponName = value("--weapon") ?? "rifle"
        guard let weapon = WeaponKind(rawValue: weaponName) else {
            throw CheckFailure(message: "--weapon accepts rifle or sniper.")
        }
        simulation.selectWeapon(weapon)
        if arguments.contains("--prone") { simulation.toggleProne() }
        var input = GameInput()
        input.aim = arguments.contains("--aim")
        let requestedShots = min(weapon.capacity + 2, max(0, Int(value("--shots") ?? "0") ?? 0))
        var acceptedShots = 0
        func advance(_ ticks: Int) {
            for _ in 0..<max(0, ticks) {
                simulation.step(deltaTime: 1.0 / 120, input: input)
                let events = simulation.drainEvents()
                acceptedShots += events.filter { $0.kind == .shot }.count
                renderer.handle(events: events, simulation: simulation)
                renderer.advanceEffects(deltaTime: 1.0 / 120, simulation: simulation)
            }
        }
        advance(24)
        for index in 0..<requestedShots {
            input.fire = true; advance(1); input.fire = false
            if index < requestedShots - 1 { advance(Int(ceil(weapon.fireInterval * 120)) + 1) }
        }
        let expected = min(requestedShots, weapon.capacity)
        guard acceptedShots == expected, renderer.shellCount == expected else {
            throw CheckFailure(message: "Shell event check failed: \(acceptedShots) shots, \(renderer.shellCount) casings, expected \(expected).")
        }
        if arguments.contains("--reload-preview") {
            simulation.reload()
            advance(Int(weapon.reloadDuration * 0.45 * 120))
            guard renderer.shellCount == expected, acceptedShots == expected else {
                throw CheckFailure(message: "Reload unexpectedly ejected a casing.")
            }
        }
        let settle = Double(value("--effect-seconds") ?? "0.025") ?? 0.025
        if settle.isFinite { advance(Int(min(16, max(0, settle)) * 120)) }
        // Casings land to the shooter's right; turn toward that patch of floor.
        if arguments.contains("--look-down") { input.yaw = -1.55; input.pitch = -0.7; advance(1) }
        return ["weapon": weapon.rawValue, "acceptedShots": acceptedShots,
                "shellCount": renderer.shellCount, "shellEventCheck": "pass",
                "shellImpacts": renderer.drainShellImpacts().count,
                "ammo": simulation.weapons[weapon]?.ammo ?? -1,
                "prone": simulation.player.prone, "aiming": simulation.isAiming]
    }
}
