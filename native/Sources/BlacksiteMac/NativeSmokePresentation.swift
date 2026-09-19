import Foundation
import BlacksiteCore

@MainActor
struct NativeSmokePresentation {
    let stockText: String
    let accessibilityText: String
    init(simulation: CombatSimulation, bindings: NativeBindings) {
        let key = NativeControlLabels.label(for: .smoke, bindings: bindings)
        stockText = "\(key) RAUCH · \(simulation.smokeGrenadeCount)"
        let fuse = simulation.smokeGrenades.map { String(format: "%.1f", $0.fuse) }.joined(separator: ", ")
        accessibilityText = "Rauchgranaten: \(simulation.smokeGrenadeCount). Taste \(key). 1,5 Sekunden Zündzeit. Kein Explosionsschaden." +
            (fuse.isEmpty ? "" : " Geworfen: \(fuse) Sekunden bis Rauchfreisetzung.")
    }
}
