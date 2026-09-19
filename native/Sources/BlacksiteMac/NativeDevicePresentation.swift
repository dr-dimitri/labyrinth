import Foundation
import BlacksiteCore

/// Describe the authoritative device snapshot without deriving new eligibility.
struct NativeDevicePresentation {
    let title: String
    let detail: String
    let fraction: Float
    let showsProgress: Bool

    init(_ status: DeviceInteractionStatus, interactionLabel: String = "E", suppliesRadio: Bool = false) {
        let binding = interactionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBound = !binding.isEmpty && binding != NativeControlLabels.unboundLabel
        let operating = status.isMoving || status.blockedByActor
        fraction = min(1, max(0, operating ? status.gateProgress :
            status.requiredProgress > 0 ? status.progress / status.requiredProgress : 0))
        showsProgress = !status.destroyed && (operating || status.interactionAvailable)
        if status.destroyed {
            title = status.kind == .generator ? "GENERATOR ZERSTÖRT" : "SERVICETOR OFFEN"
            detail = status.kind == .generator ? (suppliesRadio ? "Licht, Funk und Maschinenlärm aus · Tor von Hand bedienen" : "Licht und Maschinenlärm aus · Tor von Hand bedienen") : "Durchgang frei · Reguläre Wege bleiben nutzbar"
            return
        }
        if status.blockedByActor {
            title = "SERVICETOR WARTET"
            detail = "Bewegungsbereich freigeben · Tor fährt danach weiter"
            return
        }
        if status.isMoving {
            title = "SERVICETOR IN BEWEGUNG"
            detail = "Öffnung \(Int(status.gateProgress * 100)) % · Bewegungsbereich freihalten"
            return
        }
        let action: String
        let consequence: String
        switch status.action {
        case .enableGenerator:
            action = "GENERATOR EINSCHALTEN"
            consequence = suppliesRadio ? "STROM AUS · Licht, Funk und Maschinenlärm kehren zurück" : "STROM AUS · Licht und Maschinenlärm kehren zurück"
        case .disableGenerator:
            action = "GENERATOR ABSCHALTEN"
            consequence = suppliesRadio ? "STROM AN · Licht, Funk und Geräuschdeckung entfallen" : "STROM AN · Licht und Geräuschdeckung entfallen"
        case .openGate:
            action = "SERVICETOR ÖFFNEN"
            consequence = "TOR ZU · Öffnet Durchgang und Sichtlinie"
        case .closeGate:
            action = "SERVICETOR SCHLIESSEN"
            consequence = "TOR OFFEN · Schließt Durchgang und Sichtlinie"
        }
        if !isBound {
            title = "INTERAGIEREN NICHT BELEGT"
            detail = "In Einstellungen zuweisen · \(consequence)"
        } else if !status.interactionAvailable {
            title = action
            switch status.interruption {
            case .releaseRequired: detail = "Taste loslassen, dann erneut halten · \(consequence)"
            case .notGrounded: detail = "Am Boden stehen · \(consequence)"
            case .occluded: detail = "Bedienfeld freilegen · \(consequence)"
            default: detail = "Bedienfeld erreichen · \(Int(ceil(max(0, status.distance)))) m"
            }
        } else {
            title = "\(binding) HALTEN · \(action)"
            let method = status.manual ? "HANDBETRIEB · " : ""
            detail = method + String(format: "%.1f / %.1f s", status.progress, status.requiredProgress) + " · " + consequence
        }
    }

    var accessibilityText: String { title + ". " + detail }
}
