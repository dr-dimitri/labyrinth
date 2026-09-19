import Foundation
import BlacksiteCore

/// Known objectives and local preparation state, with no enemy information.
struct NativeOperationPresentation {
    let preparationLines: [String]
    let extractionLines: [String]
    let routeDetails: [String]
    let objectiveHeading: String
    let objectiveLines: [String]
    private let hasRequiredStages: Bool

    init(_ status: OperationStatus) {
        hasRequiredStages = !status.stages.isEmpty
        let stage = status.stages.first { $0.id == status.activeStageID && $0.active }
        objectiveHeading = stage?.title.uppercased() ?? "AUFTRAGSZIELE"
        objectiveLines = stage?.targets.map { target in
            if target.completed { return target.title + ": erledigt" }
            if target.interruption == .prerequisites { return target.title + ": vorherige Ziele offen" }
            if target.progress > 0 {
                return target.title + String(format: " · %.1f / %.1f s", target.progress, target.requiredProgress)
            }
            let ready = target.available && (target.interruption == nil || target.interruption == .interactionReleased)
            return target.title + (ready ? ": bereit zum Aktivieren" : ": noch offen")
        } ?? []
        routeDetails = status.extractions.map { "\($0.title): \($0.detail)" }
        preparationLines = status.preparations.map { preparation in
            let name = preparation.kind == .disableRadio ? "Funkversorgung" : "Servicetor"
            if preparation.completed { return name + (preparation.kind == .disableRadio ? ": aus" : ": offen") }
            if preparation.unavailable { return name + ": nicht bedienbar · Hauptweg nutzen" }
            return name + ": optional vorbereiten"
        }
        extractionLines = status.extractions.map { exit in
            if exit.blocked { return "\(exit.title) · blockiert · anderen Ausgang nutzen" }
            let route = exit.routeKind == .exposed ? "exponiert" : "teils gedeckt"
            let condition: String
            if !exit.unlocked { condition = status.stages.isEmpty ? "nach Datenaufnahme" : "nach allen Auftragszielen" }
            else if exit.active { condition = String(format: "%.1f / %.1f s", exit.progress, exit.requiredProgress) }
            else if exit.interruption == .notGrounded { condition = "Bodenkontakt nötig" }
            else { condition = "\(Int(ceil(max(0, exit.distance)))) m" }
            return "\(exit.title) · \(route) · \(condition)"
        }
    }
    var accessibilityText: String {
        (objectiveLines.isEmpty ? "" : objectiveHeading + ". ") +
            (hasRequiredStages ? "Auftragsziele erforderlich; zusätzliche Vorbereitung optional. " : "Vorbereitung optional. ") +
            (objectiveLines + preparationLines + extractionLines + routeDetails).joined(separator: ". ")
    }
}
