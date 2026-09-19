import Foundation
import BlacksiteCore

/// Wording only. Eligibility, interruption rules and progress come from Core.
struct NativeMissionPresentation {
    let title: String
    let detail: String
    let progressText: String
    let reason: String
    let fraction: Float
    let showsProgress: Bool
    let interactionTitle: String?

    init(_ status: MissionStatus) {
        let distance = status.distance.map { "\(Int(ceil(max(0, $0)))) m" }
        showsProgress = status.phase != .waves && status.phase != .completed
        fraction = status.requiredProgress > 0 ? min(1, max(0, status.progress / status.requiredProgress)) : 0
        progressText = showsProgress ? String(format: "%.1f / %.1f s", status.progress, status.requiredProgress) : ""
        switch status.phase {
        case .waves:
            title = "Überstehe die Angriffswellen"; detail = "Danach: Evakuierung am Nordtor"
            interactionTitle = nil
        case .collectData:
            title = status.interactionAvailable ? "Daten sichern" : "Datenstation erreichen"
            detail = ["CONTAINERHOF", distance, "danach evakuieren"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = status.interactionAvailable ? "E HALTEN  ·  DATEN SICHERN" : nil
        case .extract:
            title = "Evakuierung am Nordtor erreichen"
            detail = ["NORDTOR", distance, "im Ring bleiben"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = nil
        case .activateRadio:
            title = status.interactionAvailable ? "Funkstation aktivieren" : "Funkstation erreichen"
            detail = ["WARTUNGSZONE", distance, "danach Bereich halten"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = status.interactionAvailable ? "E HALTEN  ·  FUNK AKTIVIEREN" : nil
        case .holdRadio:
            title = "Funkbereich sichern"
            detail = ["WARTUNGSZONE", distance, "Fortschritt bleibt erhalten"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = nil
        case .completed:
            title = status.kind == .secureRadio ? "Funkstation gesichert" : "Evakuierung abgeschlossen"
            detail = "Auftrag abgeschlossen"; interactionTitle = nil
        }
        switch status.interruption {
        case .outOfRange:
            reason = status.phase == .holdRadio ? "PAUSIERT · In den Funkbereich zurückkehren" :
                status.phase == .extract ? "Zum Ring · Verlassen setzt die Evakuierung zurück" : "Station erreichen · Verlassen setzt Laden zurück"
        case .notGrounded:
            reason = status.phase == .holdRadio ? "PAUSIERT · Bodenkontakt im Funkbereich nötig" :
                status.phase == .extract ? "Bodenkontakt im Ring nötig · Fortschritt zurückgesetzt" : "Am Boden stehen · Laden zurückgesetzt"
        case .interactionReleased:
            reason = "E halten · Loslassen setzt Laden zurück"
        case .contested:
            reason = "PAUSIERT · Feinde aus dem Funkbereich verdrängen"
        case nil:
            switch status.phase {
            case .collectData, .activateRadio: reason = "E weiter halten · Laden läuft"
            case .extract: reason = "Im Ring bleiben · Evakuierung läuft"
            case .holdRadio: reason = "Bereich frei · Kontrolle läuft"
            default: reason = ""
            }
        }
    }

    var accessibilityText: String {
        [title, detail, showsProgress ? progressText : "", reason].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func name(_ mission: MissionKind) -> String {
        switch mission {
        case .waves: return "WELLEN"
        case .recoverData: return "DATEN BERGEN"
        case .secureRadio: return "FUNK SICHERN"
        }
    }

    static func rules(_ mission: MissionKind) -> String {
        switch mission {
        case .waves: return "Drei Angriffswellen abwehren, dann am Nordtor 3 s evakuieren.\nIm Evakuierungsring bleiben; Verlassen setzt den Timer zurück."
        case .recoverData: return "E halten: Daten sichern, danach am Nordtor 3 s evakuieren.\nLoslassen oder Verlassen setzt die Bergung zurück."
        case .secureRadio: return "E halten: Funk aktivieren, danach Bereich 45 s sichern.\nAußerhalb oder umkämpft: Pause; Fortschritt bleibt erhalten."
        }
    }

    static func banner(for phase: MissionPhase) -> (label: String, title: String, detail: String)? {
        switch phase {
        case .collectData: return ("AUFTRAG · DATENBERGUNG", "DATEN SICHERN", "Containerhof erreichen · An der Station E halten")
        case .extract: return ("DATEN GESICHERT", "ZUR EVAKUIERUNG", "Nordtor erreichen · Im grünen Ring bleiben")
        case .activateRadio: return ("AUFTRAG · FUNKSICHERUNG", "FUNK AKTIVIEREN", "Wartungszone erreichen · An der Station E halten")
        case .holdRadio: return ("FUNK AKTIV", "BEREICH SICHERN", "Feinde verdrängen · Bei Unterbrechung bleibt Fortschritt erhalten")
        case .waves, .completed: return nil
        }
    }
}
