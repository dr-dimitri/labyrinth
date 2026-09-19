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
        case .prepareOperation, .activateRelays:
            let stage = operation?.stages.first { $0.active && $0.kind == .relayGroup }
            if status.phase == .activateRelays || stage != nil {
                let count = stage.map { "\($0.targets.filter(\.completed).count)/\($0.targets.count) aktiv" } ?? "Relais offen"
                title = status.objectiveTitle ?? "Relais aktivieren"
                detail = [count, distance, "Reihenfolge frei"].compactMap { $0 }.joined(separator: " · ")
                interactionTitle = status.interactionAvailable ? binding.map { "\($0) HALTEN  ·  RELAIS AKTIVIEREN" } ?? "INTERAGIEREN NICHT BELEGT" : nil
            } else {
                title = "Vorbereiten oder direkt Daten bergen"
                detail = ["PFLICHT: DATENSTATION", distance, "Vorbereitung optional"].compactMap { $0 }.joined(separator: " · ")
                interactionTitle = status.interactionAvailable ? binding.map { "\($0) HALTEN  ·  DATEN SICHERN" } ?? "INTERAGIEREN NICHT BELEGT" : nil
            }
        case .collectData:
            title = status.interactionAvailable ? "Daten sichern" : "Datenstation erreichen"
            detail = [status.objectiveTitle?.uppercased() ?? "DATENSTATION", distance,
                      status.kind == .operation ? Self.afterData(map) : "danach evakuieren"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = status.interactionAvailable ? binding.map { "\($0) HALTEN  ·  DATEN SICHERN" } ?? "INTERAGIEREN NICHT BELEGT" : nil
        case .extract:
            if status.kind == .operation {
                let exit = operation?.extractions.first { $0.id == status.extractionID }
                title = exit.map { "Evakuierung: " + $0.title } ?? "Einen Ausgang erreichen"
                let route = exit.map { $0.routeKind == .exposed ? "Offener Weg" : "Abschnittsweise Deckung" }
                detail = [route ?? "Zwei Ausgänge zur Wahl", distance, "im Ring bleiben"].compactMap { $0 }.joined(separator: " · ")
            } else {
                title = "Evakuierung: " + Self.extractionTitle(map)
                detail = [Self.extractionTitle(map).uppercased(), distance, "im Ring bleiben"].compactMap { $0 }.joined(separator: " · ")
            }
            interactionTitle = nil
        case .activateRadio:
            title = status.interactionAvailable ? "Funkstation aktivieren" : "Funkstation erreichen"
            let hold = status.kind != .operation || (map.operation?.requiredStages.first { $0.kind == .radioTransfer }?.holdDuration ?? 0) > 0
            detail = [status.objectiveTitle?.uppercased() ?? "FUNKSTATION", distance,
                      hold ? "danach Bereich halten" : "danach Ausgang wählen"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = status.interactionAvailable ? binding.map { "\($0) HALTEN  ·  FUNK AKTIVIEREN" } ?? "INTERAGIEREN NICHT BELEGT" : nil
        case .holdRadio:
            title = "Funkbereich sichern"
            detail = ["FUNKSTATION", distance, "Fortschritt bleibt erhalten"].compactMap { $0 }.joined(separator: " · ")
            interactionTitle = nil
        case .completed:
            title = status.kind == .secureRadio ? "Funkstation gesichert" : "Evakuierung abgeschlossen"
            detail = "Auftrag abgeschlossen"; interactionTitle = nil
        }
        if binding == nil && [.prepareOperation, .activateRelays, .collectData, .activateRadio].contains(status.phase) {
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
            reason = status.phase == .extract ? "ZUGANG BLOCKIERT · Anderen Ausgang nutzen" : "SICHTWEG BLOCKIERT · Station von vorn erreichen"
        case .prerequisites:
            reason = "VORHERIGE ZIELE OFFEN · Angezeigte Auftragsziele abschließen"
        case .releaseRequired:
            reason = "\(binding ?? interactionLabel) loslassen · Dann erneut halten"
        case nil:
            switch status.phase {
            case .prepareOperation, .activateRelays, .collectData, .activateRadio: reason = "\(binding ?? interactionLabel) weiter halten · Laden läuft"
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
        case .operation:
            if let stages = map.operation?.requiredStages, !stages.isEmpty {
                let sequence = stages.map { stage in
                    switch stage.kind {
                    case .relayGroup: return "\(stage.targets.count) Relais in beliebiger Reihenfolge"
                    case .collectData: return "Daten sichern"
                    case .radioTransfer: return stage.holdDuration > 0 ? "Funk aktivieren und \(Int(stage.holdDuration)) s halten" : "Funk aktivieren"
                    }
                }.joined(separator: " → ")
                return "\(action): \(sequence).\nDanach einen der zwei Ausgänge erreichen."
            }
            return "\(preparationText(map.operation?.preparations.map(\.kind) ?? [])) \(action): Daten bergen.\nDanach Ausgang wählen: kurz und offen oder länger und teilweise gedeckt."
        }
    }

    static func banner(for phase: MissionPhase, interactionLabel: String = "E", operation: OperationStatus? = nil, map: MapDefinition = .blacksite) -> (label: String, title: String, detail: String)? {
        let action = boundInteractionLabel(interactionLabel).map { "An der Station \($0) halten" } ?? "Interagieren in Einstellungen belegen"
        switch phase {
        case .prepareOperation:
            if map.operation?.requiredStages.first?.kind == .relayGroup {
                return banner(for: .activateRelays, interactionLabel: interactionLabel, operation: operation, map: map)
            }
            return ("FELDOPERATION", "BEOBACHTEN. VORBEREITEN.", "Daten sind Pflicht · \(preparationText(operation?.preparations.map(\.kind) ?? map.operation?.preparations.map(\.kind) ?? [])) · \(action)")
        case .activateRelays: return ("FELDOPERATION", "RELAIS VERBINDEN", "Beide Relais aktivieren · Reihenfolge frei · \(action)")
        case .collectData: return ("AUFTRAG · DATENBERGUNG", "DATEN SICHERN", "Datenstation erreichen" + " · \(action)")
        case .extract:
            if let operation {
                return (operation.stages.isEmpty ? "DATEN GESICHERT" : "AUFTRAGSZIELE ERFÜLLT", "WÄHLE DEINEN RÜCKWEG", operation.extractions.map(\.title).joined(separator: " oder ") + " · Im Ring bleiben")
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

    private static func afterData(_ map: MapDefinition) -> String {
        map.operation?.requiredStages.contains { $0.kind == .radioTransfer } == true
            ? "danach Funk aktivieren" : "danach Ausgang wählen"
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
