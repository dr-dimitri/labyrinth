import Foundation
import simd

public enum LevelMission: String, Codable, CaseIterable, Sendable {
    case waves, recoverData, secureRadio
    public var title: String { switch self { case .waves: return "Wellen abwehren"; case .recoverData: return "Daten bergen"; case .secureRadio: return "Funk sichern" } }
    public var kind: MissionKind { MissionKind(rawValue: rawValue)! }
}
public extension LevelMarkerKind {
    var title: String {
        switch self {
        case .playerStart: return "Spielerstart"; case .enemySpawn: return "Gegnerstart"
        case .reinforcement: return "Verstärkung"; case .waveStaging: return "Sammelpunkt"
        case .extraction: return "Evakuierung"; case .dataSite: return "Datenstation"
        case .radioSite: return "Funkstation"; case .serviceApproach: return "Servicezugang"; case .patrol: return "Patrouille"
        }
    }
    var isSingleton: Bool { [.playerStart,.extraction,.dataSite,.radioSite,.serviceApproach].contains(self) }
}
public struct LevelPlayIssue: Sendable {
    public let message: String
    public let itemID: String?
    public let position: LevelVector?
    public init(message: String,itemID: String?,position: LevelVector?) { self.message = message; self.itemID = itemID; self.position = position }
}
public extension LevelDocument {
    var missionKind: MissionKind { (mission ?? .waves).kind }
    mutating func setMarker(_ kind: LevelMarkerKind,at position: LevelVector) {
        if kind.isSingleton,let index = markers.firstIndex(where: { $0.kind == kind }) { markers[index].position = position }
        else { markers.append(LevelMarker(kind: kind,position: position)) }
    }
    mutating func installGameplayTemplate(_ mission: LevelMission) {
        self.mission = mission
        let x = Float(bounds.x)+Float(bounds.width)/2,z = Float(bounds.z)+Float(bounds.depth)/2
        let w = Float(bounds.width)*0.32,d = Float(bounds.depth)*0.32
        markers = [LevelMarker(kind: .playerStart,position: .init(x,0,z+d)),
            LevelMarker(kind: .extraction,position: .init(x,0,z-d)),LevelMarker(kind: .dataSite,position: .init(x-w,0,z-d)),
            LevelMarker(kind: .radioSite,position: .init(x+w,0,z-d)),LevelMarker(kind: .serviceApproach,position: .init(x+w,0,z+d)),
            LevelMarker(kind: .reinforcement,position: .init(x+w,0,z)),LevelMarker(kind: .waveStaging,position: .init(x-w,0,z))]
    }
    /// Diagnostics supplement the same final validator used by the real game.
    /// Positions/IDs let the UI focus errors without parsing translated strings.
    func playIssues() -> [LevelPlayIssue] {
        var issues: [LevelPlayIssue] = []
        do { try validateDraft() } catch { return [LevelPlayIssue(message: error.localizedDescription,itemID: nil,position: nil)] }
        for kind in LevelMarkerKind.allCases {
            let matching = markers.filter { $0.kind == kind }
            if kind.isSingleton && matching.count != 1 || [.reinforcement,.waveStaging].contains(kind) && matching.isEmpty {
                issues.append(LevelPlayIssue(message: "\(kind.title): \(kind.isSingleton ? "genau einen Marker" : "mindestens einen Marker") setzen.",itemID: matching.first?.id,position: matching.first?.position))
            }
        }
        do {
            let map = try makeMap(purpose: .preview), simulation = CombatSimulation(map: map)
            let start = map.grounded(map.playerStart.position)
            for marker in markers {
                if Task.isCancelled { return [] }
                let p = marker.position
                if p.x <= Float(bounds.x) || p.z <= Float(bounds.z) || p.x >= Float(bounds.x+bounds.width) || p.z >= Float(bounds.z+bounds.depth) || abs(p.y)>0.05 {
                    issues.append(LevelPlayIssue(message: "\(marker.kind.title) muss am Boden innerhalb der Kartengrenzen liegen.",itemID: marker.id,position: p))
                } else if !simulation.hasReachableRoute(from: start,to: map.grounded(p.value)) {
                    issues.append(LevelPlayIssue(message: "\(marker.kind.title) ist blockiert oder vom Spielerstart nicht erreichbar.",itemID: marker.id,position: p))
                }
            }
            for object in objects where LevelObjectCatalog.item(id: object.catalogID)?.category == .buildings {
                let point = map.grounded(object.position.value)
                if !simulation.hasReachableRoute(from: start,to: point) {
                    issues.append(LevelPlayIssue(message: "Zugang zu \(LevelObjectCatalog.item(id: object.catalogID)?.name ?? "Gebäude") ist blockiert oder nicht erreichbar.",itemID: object.id,position: object.position))
                }
            }
        } catch { issues.append(LevelPlayIssue(message: error.localizedDescription,itemID: nil,position: nil)) }
        do { _ = try makeMap() } catch {
            if !issues.contains(where: { $0.message == error.localizedDescription }) { issues.append(LevelPlayIssue(message: error.localizedDescription,itemID: nil,position: nil)) }
        }
        return issues
    }
    static func deviceID(_ id: String) -> Int { obstacleID("device:"+id) }
}
