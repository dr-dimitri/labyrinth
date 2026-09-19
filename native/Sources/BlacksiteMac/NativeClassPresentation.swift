import Foundation
import BlacksiteCore

@MainActor
enum NativeClassPresentation {
    static func name(_ role: OperatorClass) -> String {
        switch role { case .recon: return "Aufklärer"; case .engineer: return "Pionier"; case .assault: return "Sturm" }
    }
    static func description(_ role: OperatorClass, gadgetKey: String) -> String {
        switch role {
        case .recon:
            return "\(gadgetKey) beim Zielen: sichtbaren Kontaktpunkt merken. Höchstens 3 Punkte, 12 s; sie folgen keinem Gegner. Ein Köder unterstützt die Umgehung. Weniger Splittergranaten; kein Rauch, keine Ladung."
        case .engineer:
            return "\(gadgetKey): eine Ladung an einem erreichbaren Zugang anbringen (bis 2 m). 3 s Zünder — zurückziehen, die Explosion verletzt auch dich. Generatoren und Tore: 35 % kürzere Bedienzeit. Weniger AR-Reserve; kein Rauch oder Köder."
        case .assault:
            return "\(gadgetKey): Rauch werfen, alternativ die Rauch-Taste. Zwei Rauchgranaten und zusätzliche AR-Reserve erleichtern Querung und Rückzug. Kein Beobachtungswerkzeug, keine Durchbruchladung, kein Köder."
        }
    }
    static func inventory(_ loadout: LoadoutDefinition) -> String {
        "STARTVORRAT · \(loadout.fragmentationGrenades) Splittergranaten · \(loadout.noiseDecoys) Köder\n\(loadout.smokeGrenades) Rauchgranaten · \(loadout.breachCharges) Durchbruchladung\nAR-4: \(WeaponKind.rifle.capacity) + \(loadout.rifleReserve) · M82: \(WeaponKind.sniper.capacity) + \(loadout.sniperReserve) Schuss"
    }
    static func stockText(_ simulation: CombatSimulation, bindings: NativeBindings) -> String {
        let key = NativeControlLabels.label(for: .classGadget, bindings: bindings)
        switch simulation.loadout.operatorClass {
        case .recon: return "\(key) KONTAKTPUNKT · \(simulation.reconMarks.count)/3"
        case .engineer:
            if let charge = simulation.breachCharges.first { return "LADUNG · \(String(format: "%.1f", charge.fuse)) s" }
            return "\(key) LADUNG · \(simulation.breachChargeCount)"
        case .assault: return "\(key) RAUCH · \(simulation.smokeGrenadeCount)"
        }
    }
    static func accessibilityText(_ simulation: CombatSimulation, bindings: NativeBindings) -> String {
        "Klasse \(name(simulation.loadout.operatorClass)). " + stockText(simulation, bindings: bindings)
    }
}
