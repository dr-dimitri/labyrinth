import Foundation
import BlacksiteCore

/// Known objectives and local preparation state, with no enemy information.
struct NativeOperationPresentation {
    let preparationLines: [String]
    let extractionLines: [String]
    let routeDetails: [String]

    init(_ status: OperationStatus) {
        routeDetails = status.extractions.map { "\($0.title): \($0.detail)" }
        preparationLines = status.preparations.map { preparation in
            let name = preparation.kind == .disableRadio ? "Funkversorgung" : "Servicetor"
            if preparation.completed { return name + (preparation.kind == .disableRadio ? ": aus" : ": offen") }
            if preparation.unavailable { return name + ": nicht bedienbar · Hauptweg nutzen" }
            return name + ": optional vorbereiten"
        }
        extractionLines = status.extractions.map { exit in
            if exit.blocked { return "\(exit.title) · blockiert · anderen Ausgang nutzen" }
            let route = exit.routeKind == .exposed ? "kurz / exponiert" : "länger / teils gedeckt"
            let condition: String
            if !exit.unlocked { condition = "nach Datenaufnahme" }
            else if exit.active { condition = String(format: "%.1f / %.1f s", exit.progress, exit.requiredProgress) }
            else if exit.interruption == .notGrounded { condition = "Bodenkontakt nötig" }
            else { condition = "\(Int(ceil(max(0, exit.distance)))) m" }
            return "\(exit.title) · \(route) · \(condition)"
        }
    }
    var accessibilityText: String {
        "Vorbereitung optional. " + (preparationLines + extractionLines + routeDetails).joined(separator: ". ")
    }
}
