import AppKit
import BlacksiteCore

@MainActor
enum NativeRunReportCheck {
    static func makePNG(output: URL, map: MapDefinition, seed: UInt64, loadout: LoadoutDefinition = .init()) throws -> [String: Any] {
        let config = ActiveRunConfiguration(map: map, seed: seed, mission: .operation,
                                            difficulty: .normal, loadout: loadout)
        let game = try config.makeSimulation()
        game.throwGrenade(); game.throwSmokeGrenade()
        var input = GameInput(); input.fire = true
        game.step(deltaTime: 1.0 / 120, input: input)
        let report = NativeRunReport(configuration: config, simulation: game, outcome: .aborted)
        let view = NativeRunReportView(frame: NSRect(x: 0, y: 0, width: 720, height: 352))
        view.update(report)
        var result = try NativeBriefingCheck.snapshot(view: view, output: output)
        result["scope"] = "Actual ordinary inputs followed by an aborted report; static layout, no complete combat mission."
        result["report"] = report.accessibilityText
        return result
    }
}
