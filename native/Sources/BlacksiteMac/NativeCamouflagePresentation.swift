import Foundation
import BlacksiteCore

enum NativeCamouflagePresentation {
    static func name(_ pattern: CamouflagePattern) -> String {
        switch pattern {
        case .none: return "Normale Einsatzkleidung"
        case .vegetation: return "Vegetation · Grün / Oliv"
        case .mineral: return "Mineral · Erde / Schutt"
        }
    }
    static func description(_ pattern: CamouflagePattern) -> String {
        switch pattern {
        case .none: return "Eine zusätzliche Splittergranate. Pflanzen und feste Deckung bleiben auch ohne Tarnanzug nützlich."
        case .vegetation: return "Passend zu bewachsenen Flächen. Ruhiges Liegen erschwert die Erkennung auf Distanz; Bewegung und Schüsse unterbrechen den Vorteil."
        case .mineral: return "Passend zu Erde und Schutt. Ruhiges Liegen erschwert die Erkennung auf Distanz; Dächer und Straßen bieten keine passende Bodenauflage."
        }
    }
    static func localStatus(_ status: ConcealmentStatus) -> String {
        switch status.reason {
        case .noSuit: return "NORMALE EINSATZKLEIDUNG"
        case .unsuitableGround: return "TARNMUSTER · UNPASSENDER UNTERGRUND"
        case .moving: return "TARNMUSTER · BEWEGUNG"
        case .turning: return "TARNMUSTER · STARKE DREHUNG"
        case .airborne: return "TARNMUSTER · KEIN BODENKONTAKT"
        case .recentShot: return "TARNMUSTER · NACH SCHUSS GESPERRT"
        case .settling: return "PASSENDES GELÄNDE · RUHIG WERDEN"
        case .ready: return "PASSENDES GELÄNDE · RUHIG"
        }
    }
}
