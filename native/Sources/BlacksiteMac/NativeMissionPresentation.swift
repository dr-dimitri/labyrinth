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
    let interactionDetail: String

    init(_ status: MissionStatus, interactionLabel: String = "E", operation: OperationStatus? = nil, map: MapDefinition = .blacksite) {
        let binding = Self.boundInteractionLabel(interactionLabel)
        interactionDetail = binding == nil ? "Interagieren in den Einstellungen belegen" :
            "Loslassen oder Verlassen setzt den Fortschritt zurück"
        let distance = status.distance.map { "\(Int(ceil(max(0, $0)))) m" }
        showsProgress = status.phase != .waves && status.phase != .completed
        fraction = status.requiredProgress > 0 ? min(1, max(0, status.progress / status.requiredProgress)) : 0
        progressText = showsProgress ? String(format: "%.1f / %.1f s", status.progress, status.requiredProgress) : ""
        switch status.phase {
        case .waves:
            title = "Überstehe die Angriffswellen"; detail = "Danach: Evakuierung bei \(Self.extractionTitle(map))"
            interactionTitle = nil
        case .prepareOperation:
            title = "Vorbereiten oder direkt Daten bergen"
            detail = ["PFLICHT: DATENSTATION", distance, "Vorbereitung optional"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = status.interactionAvailable ? binding.map { "\($0) HALTEN  ·  DATEN SICHERN" } ?? "INTERAGIEREN NICHT BELEGT" : nil
        case .collectData:
            title = status.interactionAvailable ? "Daten sichern" : "Datenstation erreichen"
            detail = ["DATENSTATION", distance,
                      status.kind == .operation ? "danach Ausgang wählen" : "danach evakuieren"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = status.interactionAvailable ? binding.map { "\($0) HALTEN  ·  DATEN SICHERN" } ?? "INTERAGIEREN NICHT BELEGT" : nil
        case .extract:
            if status.kind == .operation {
                let exit = operation?.extractions.first { $0.id == status.extractionID }
                title = exit.map { "Evakuierung: " + $0.title } ?? "Einen Ausgang erreichen"
                let route = exit.map { $0.routeKind == .exposed ? "Kurzer offener Weg" : "Längerer Weg mit Deckung" }
                detail = [route ?? "Zwei Ausgänge zur Wahl", distance, "im Ring bleiben"].compactMap { $0 }.joined(separator: " · ")
            } else {
                title = "Evakuierung: " + Self.extractionTitle(map)
                detail = [Self.extractionTitle(map).uppercased(), distance, "im Ring bleiben"].compactMap { $0 }.joined(separator: " · ")
            }
            interactionTitle = nil
        case .activateRadio:
            title = status.interactionAvailable ? "Funkstation aktivieren" : "Funkstation erreichen"
            detail = ["FUNKSTATION", distance, "danach Bereich halten"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = status.interactionAvailable ? binding.map { "\($0) HALTEN  ·  FUNK AKTIVIEREN" } ?? "INTERAGIEREN NICHT BELEGT" : nil
        case .holdRadio:
            title = "Funkbereich sichern"
            detail = ["FUNKSTATION", distance, "Fortschritt bleibt erhalten"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = nil
        case .completed:
            title = status.kind == .secureRadio ? "Funkstation gesichert" : "Evakuierung abgeschlossen"
            detail = "Auftrag abgeschlossen"; interactionTitle = nil
        }
        if binding == nil && (status.phase == .prepareOperation || status.phase == .collectData || status.phase == .activateRadio) {
            reason = "INTERAGIEREN NICHT BELEGT · In Einstellungen zuweisen"
        } else { switch status.interruption {
        case .outOfRange:
            reason = status.phase == .holdRadio ? "PAUSIERT · In den Funkbereich zurückkehren" :
                status.phase == .extract ? "Zum Ring · Verlassen setzt die Evakuierung zurück" : "Station erreichen · Verlassen setzt Laden zurück"
        case .notGrounded:
            reason = status.phase == .holdRadio ? "PAUSIERT · Bodenkontakt im Funkbereich nötig" :
                status.phase == .extract ? "Bodenkontakt im Ring nötig · Fortschritt zurückgesetzt" : "Am Boden stehen · Laden zurückgesetzt"
        case .interactionReleased:
            reason = "\(binding ?? interactionLabel) halten · Loslassen setzt Laden zurück"
        case .contested:
            reason = "PAUSIERT · Feinde aus dem Funkbereich verdrängen"
        case .blocked:
            reason = "ZUGANG BLOCKIERT · Anderen Ausgang nutzen"
        case nil:
            switch status.phase {
            case .prepareOperation, .collectData, .activateRadio: reason = "\(binding ?? interactionLabel) weiter halten · Laden läuft"
            case .extract: reason = "Im Ring bleiben · Evakuierung läuft"
            case .holdRadio: reason = "Bereich frei · Kontrolle läuft"
            default: reason = ""
            }
        } }
    }

    var accessibilityText: String {
        [title, detail, showsProgress ? progressText : "", reason].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func name(_ mission: MissionKind) -> String {
        switch mission {
        case .waves: return "WELLEN"
        case .recoverData: return "DATEN BERGEN"
        case .secureRadio: return "FUNK SICHERN"
        case .operation: return "FELDOPERATION"
        }
    }

    static func rules(_ mission: MissionKind, interactionLabel: String = "E", map: MapDefinition = .blacksite) -> String {
        let action = boundInteractionLabel(interactionLabel).map { "\($0) halten" } ?? "Interagieren in Einstellungen belegen"
        switch mission {
        case .waves: return "Drei Angriffswellen abwehren, dann bei \(extractionTitle(map)) 3 s evakuieren.\nIm Evakuierungsring bleiben; Verlassen setzt den Timer zurück."
        case .recoverData: return "\(action): Daten sichern, danach bei \(extractionTitle(map)) 3 s evakuieren.\nLoslassen oder Verlassen setzt die Bergung zurück."
        case .secureRadio: return "\(action): Funk aktivieren, danach Bereich 45 s sichern.\nAußerhalb oder umkämpft: Pause; Fortschritt bleibt erhalten."
        case .operation: return "\(preparationText(map.operation?.preparations.map(\.kind) ?? [])) \(action): Daten bergen.\nDanach Ausgang wählen: kurz und offen oder länger und teilweise gedeckt."
        }
    }

    static func banner(for phase: MissionPhase, interactionLabel: String = "E", operation: OperationStatus? = nil, map: MapDefinition = .blacksite) -> (label: String, title: String, detail: String)? {
        let action = boundInteractionLabel(interactionLabel).map { "An der Station \($0) halten" } ?? "Interagieren in Einstellungen belegen"
        switch phase {
        case .prepareOperation: return ("FELDOPERATION", "BEOBACHTEN. VORBEREITEN.", "Daten sind Pflicht · \(preparationText(operation?.preparations.map(\.kind) ?? map.operation?.preparations.map(\.kind) ?? [])) · \(action)")
        case .collectData: return ("AUFTRAG · DATENBERGUNG", "DATEN SICHERN", "Datenstation erreichen" + " · \(action)")
        case .extract:
            if let operation {
                return ("DATEN GESICHERT", "WÄHLE DEINEN RÜCKWEG", operation.extractions.map(\.title).joined(separator: " oder ") + " · Im Ring bleiben")
            }
            return ("DATEN GESICHERT", "ZUR EVAKUIERUNG", "\(extractionTitle(map)) erreichen · Im grünen Ring bleiben")
        case .activateRadio: return ("AUFTRAG · FUNKSICHERUNG", "FUNK AKTIVIEREN", "Funkstation erreichen · \(action)")
        case .holdRadio: return ("FUNK AKTIV", "BEREICH SICHERN", "Feinde verdrängen · Bei Unterbrechung bleibt Fortschritt erhalten")
        case .waves, .completed: return nil
        }
    }

    static func extractionTitle(_ map: MapDefinition) -> String {
        map.operation?.extractions.first {
            abs($0.position.x - map.extraction.x) < 0.01 && abs($0.position.z - map.extraction.z) < 0.01
        }?.title ?? "Evakuierungspunkt"
    }

    private static func preparationText(_ kinds: [OperationPreparationKind]) -> String {
        guard !kinds.isEmpty else { return "Route beobachten und vorbereiten." }
        return "Optional: " + kinds.map { $0 == .disableRadio ? "Funk abschalten" : "Tor öffnen" }.joined(separator: " / ") + "."
    }

    private static func boundInteractionLabel(_ label: String) -> String? {
        let value=label.trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty || value == NativeControlLabels.unboundLabel ? nil : value
    }
}
