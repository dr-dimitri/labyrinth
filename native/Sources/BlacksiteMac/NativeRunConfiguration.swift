import Foundation
import BlacksiteCore

enum NativeRunSeed {
    static func from(arguments: [String]) throws -> UInt64 {
        guard let index = arguments.firstIndex(of: "--seed") else { return 1745 }
        guard index + 1 < arguments.count, let seed = UInt64(arguments[index + 1]) else {
            throw NSError(domain: "Blacksite.RunSeed", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "--seed benötigt eine vorzeichenlose 64-Bit-Ganzzahl."])
        }
        return seed
    }
    /// A new operation gets a different authored variant as well as a new seed.
    static func next(after previous: UInt64?, candidate: UInt64 = UInt64.random(in: 1...UInt64.max)) -> UInt64 {
        var next = candidate
        if let previous {
            while next % 3 == previous % 3 { next &+= 1 }
        }
        return next
    }
}

/// Only released, playable maps appear in native menus. Diagnostic maps remain
/// available to their explicit CLI/test callers, never through saved settings.
enum PublishedMapRegistry {
    static let maps: [MapDefinition] = [.blacksite, .nebelwacht, .sundkai, .kessel9, .sirocco]
    static let defaultMapID = MapDefinition.blacksite.id

    static func map(id: String) -> MapDefinition? { maps.first { $0.id == id } }

    static func normalizedID(_ id: String?) -> String {
        guard let id, map(id: id) != nil else { return defaultMapID }
        return id
    }
}

enum NativeRunConfigurationError: LocalizedError, Equatable {
    case unavailableMap(String)
    case unavailableVersion(mapID: String, requested: Int, available: Int)
    case unsupportedMission(mapID: String, mission: MissionKind)

    var errorDescription: String? {
        switch self {
        case .unavailableMap(let id):
            return "Die Karte „\(id)“ ist nicht verfügbar. Bitte einen neuen Einsatz vorbereiten."
        case .unavailableVersion(let id, let requested, let available):
            return "Karte „\(id)“ benötigt Version \(requested); verfügbar ist Version \(available). Bitte einen neuen Einsatz vorbereiten."
        case .unsupportedMission(let id, _):
            return "Der gewählte Auftrag ist auf Karte „\(id)“ nicht verfügbar. Bitte einen neuen Einsatz vorbereiten."
        }
    }
}

/// Captured once when starting a run. Menu changes cannot change a retry's map,
/// rules, equipment or random stream, and retries never silently migrate maps.
struct ActiveRunConfiguration: Equatable, Sendable {
    let mapID: String
    let mapVersion: Int
    let seed: UInt64
    let mission: MissionKind
    let difficulty: Difficulty
    let loadout: LoadoutDefinition
    let levelDocument: LevelDocument?

    init(map: MapDefinition, seed: UInt64, mission: MissionKind,
         difficulty: Difficulty, loadout: LoadoutDefinition, levelDocument: LevelDocument? = nil) {
        mapID = map.id; mapVersion = map.version; self.seed = seed
        self.mission = mission; self.difficulty = difficulty; self.loadout = loadout
        self.levelDocument = levelDocument
    }

    func restoreMap() throws -> MapDefinition {
        try restoreMap(availableMaps: PublishedMapRegistry.maps)
    }

    /// Supplying a registry keeps version and compatibility checks independently
    /// testable without publishing a diagnostic map in the actual application.
    func restoreMap(availableMaps: [MapDefinition]) throws -> MapDefinition {
        let maps = try levelDocument.map { [try $0.makeMap()] } ?? availableMaps
        guard let map = maps.first(where: { $0.id == mapID }) else {
            throw NativeRunConfigurationError.unavailableMap(mapID)
        }
        guard map.version == mapVersion else {
            throw NativeRunConfigurationError.unavailableVersion(mapID: mapID, requested: mapVersion, available: map.version)
        }
        guard map.supportsMission(mission) else {
            throw NativeRunConfigurationError.unsupportedMission(mapID: mapID, mission: mission)
        }
        return try RunVariantCatalog.resolve(map: map, seed: seed).map
    }

    func makeSimulation() throws -> CombatSimulation {
        CombatSimulation(map: try restoreMap(), difficulty: difficulty, seed: seed,
                         mission: mission, loadout: loadout)
    }
}
