import Foundation
import simd

/// A finite authored deployment. Its map is the common source for simulation,
/// rendering and briefing; no gameplay choice is made by the graphics profile.
public struct ResolvedRunVariant: Sendable {
    public let id: String
    public let title: String
    public let conditions: [String]
    public let map: MapDefinition
}

public enum RunVariantCatalog {
    /// Uses the full seed without advancing the combat or weather random stream.
    /// The catalog belongs to the map definition version, not saved menu state.
    public static func resolve(map: MapDefinition, seed: UInt64) throws -> ResolvedRunVariant {
        guard let plans = plans(for: map.id) else {
            return ResolvedRunVariant(id: "standard", title: "Standard", conditions: [], map: map)
        }
        let index = Int((seed % 3 + UInt64(max(0, map.version - 1)) % 3) % 3)
        return try apply(plans[index], index: index, to: map, seed: seed)
    }

    /// Explicit order for acceptance tests; callers never need to guess a seed
    /// that selects a particular authoring variant.
    public static func variants(for map: MapDefinition) throws -> [ResolvedRunVariant] {
        guard let plans = plans(for: map.id) else { return [try resolve(map: map, seed: 0)] }
        let versionOffset = max(0, map.version - 1) % 3
        return try plans.enumerated().map {
            let seed = UInt64(($0.offset + 3 - versionOffset) % 3)
            return try apply($0.element, index: $0.offset, to: map, seed: seed)
        }
    }

    private struct Plan {
        let title: String, location: String, patrolDescription: String
        let data: SIMD3<Float>, patrols: [SIMD3<Float>]
    }

    // These are existing, individually walked route landmarks. Neither the
    // terrain nor the camouflage ground changes between variants.
    private static func plans(for id: String) -> [Plan]? {
        switch id {
        case "blacksite": return [
            Plan(title: "Westposten", location: "Westposten", patrolDescription: "Westen / Straße",
                 data: SIMD3(-31,0,31), patrols: [SIMD3(-31,0,31),SIMD3(0,0,8),SIMD3(32,0,5)]),
            Plan(title: "Containerzufahrt", location: "Containerzufahrt", patrolDescription: "Container / Nordzufahrt",
                 data: SIMD3(-32,0,22), patrols: [SIMD3(-32,0,22),SIMD3(-8,0,8),SIMD3(24,0,-13)]),
            Plan(title: "Westquerung", location: "Westquerung", patrolDescription: "Querung / Ostweg",
                 data: SIMD3(-25,0,8), patrols: [SIMD3(-25,0,8),SIMD3(29,0,21),SIMD3(0,0,-12)])
        ]
        case "nebelwacht": return [
            Plan(title: "Felsstation", location: "Felsstation", patrolDescription: "Felsweg / Trasse",
                 data: SIMD3(-27,0,-24), patrols: [SIMD3(-27,0,-24),SIMD3(-9,0,32),SIMD3(0,0,-4)]),
            Plan(title: "Felszugang", location: "Felszugang", patrolDescription: "Nordzugang / Radom",
                 data: SIMD3(-27,0,-17), patrols: [SIMD3(-27,0,-17),SIMD3(5,0,3),SIMD3(23,0,-20.9)]),
            Plan(title: "Küstenquerung", location: "Küstenquerung", patrolDescription: "Küste / Ostmodule",
                 data: SIMD3(-27,0,-6), patrols: [SIMD3(-27,0,-6),SIMD3(-29,0,9),SIMD3(31,0,-14)])
        ]
        case "sundkai": return [
            Plan(title: "Versandlager", location: "Versandlager", patrolDescription: "Lagerweg / Ostdamm",
                 data: SIMD3(-24,0,-28), patrols: [SIMD3(-24,0,-28),SIMD3(-26,0,2),SIMD3(24,0,3)]),
            Plan(title: "Nördlicher Lagerweg", location: "Lagerweg Nord", patrolDescription: "Lagerzugang / Norddamm",
                 data: SIMD3(-26,0,-18), patrols: [SIMD3(-26,0,-18),SIMD3(-26,0,32),SIMD3(24,0,-22)]),
            Plan(title: "Lagerquerung", location: "Lagerquerung", patrolDescription: "Querung / Süddamm",
                 data: SIMD3(-26,0,2), patrols: [SIMD3(-26,0,2),SIMD3(-26,0,-18),SIMD3(24,0,16)])
        ]
        case "kessel9": return [
            Plan(title: "Leitstand", location: "Leitstand", patrolDescription: "Westweg / Ostkanal",
                 data: SIMD3(-12,0,-25), patrols: [SIMD3(-12,0,-25),SIMD3(-28,0,10),SIMD3(8,0,10)]),
            Plan(title: "Leitstandzufahrt", location: "Leitstandzufahrt", patrolDescription: "Westzugang / Kabelweg",
                 data: SIMD3(-12,0,-20), patrols: [SIMD3(-12,0,-20),SIMD3(-28,0,20),SIMD3(28,0,-20)]),
            Plan(title: "Westwartung", location: "Westwartung", patrolDescription: "Westkanal / Kabelweg",
                 data: SIMD3(-28,0,-18), patrols: [SIMD3(-28,0,-18),SIMD3(-6,0,20),SIMD3(28,0,9)])
        ]
        case "sirocco": return [
            Plan(title: "Gewächshaus Nord", location: "Gewächshaus Nord", patrolDescription: "Glasgang / Westweg",
                 data: SIMD3(0,0,-23), patrols: [SIMD3(0,0,-23),SIMD3(-24,0,-18),SIMD3(0,0,18)]),
            Plan(title: "Westliche Salzstation", location: "Salzstation West", patrolDescription: "Westweg / Nordkante",
                 data: SIMD3(-26,0,-23), patrols: [SIMD3(-26,0,-23),SIMD3(-29,0,0),SIMD3(0,0,-17)]),
            Plan(title: "Östliche Salzstation", location: "Salzstation Ost", patrolDescription: "Salzrampe / Glasgang",
                 data: SIMD3(18,0,-17), patrols: [SIMD3(18,0,-17),SIMD3(33,0,-16),SIMD3(0,0,16)])
        ]
        default: return nil
        }
    }

    private static func apply(_ plan: Plan, index: Int, to base: MapDefinition, seed: UInt64) throws -> ResolvedRunVariant {
        var environment = base.environment
        environment.devices = environment.devices.map { source in
            let generatorOn = source.kind == .generator ? index != 1 : source.initiallyEnabled
            var open = source.initiallyOpen
            if base.id == "blacksite", source.kind == .serviceGate { open = index == 1 }
            if base.id == "kessel9", source.controllerID != nil, index == 2 { open.toggle() }
            return WorldInteractableDefinition(id: source.id, kind: source.kind, ownerObstacleID: source.ownerObstacleID,
                interactionPoints: source.interactionPoints, generatorID: source.generatorID,
                noiseEmitterIDs: source.noiseEmitterIDs, lightIDs: source.lightIDs, openOffset: source.openOffset,
                linkedGateIDs: source.linkedGateIDs, controllerID: source.controllerID, initiallyOpen: open,
                initiallyEnabled: generatorOn)
        }
        if base.id == "nebelwacht" {
            environment.smokeEmitters = environment.smokeEmitters.map { source in
                SmokeEmitterDefinition(id: source.id, kind: source.kind, position: source.position, radii: source.radii,
                    density: source.density, lifetime: source.lifetime, interval: source.interval,
                    startDelay: source.startDelay + Float(index * 3), powerDeviceID: source.powerDeviceID,
                    warningLeadTime: source.warningLeadTime, seededDelayRange: source.seededDelayRange,
                    warningIndicatorPosition: source.warningIndicatorPosition)
            }
        }
        var obstacles = base.obstacles
        if base.id == "sirocco" {
            let openedIDs = index == 0 ? [] : index == 1 ? [3002] : [3002,3008]
            for i in obstacles.indices where openedIDs.contains(obstacles[i].id) {
                obstacles[i].destroyed = true; obstacles[i].health = 0
            }
        }
        let operation = base.operation.map { operation in
            MapOperationDefinition(preparations: operation.preparations, extractions: operation.extractions,
                requiredStages: operation.requiredStages.map { stage in
                    OperationStageDefinition(id: stage.id, title: stage.title, kind: stage.kind,
                        targets: stage.targets.map { target in
                            OperationTargetDefinition(id: target.id, title: target.title,
                                position: stage.kind == .collectData ? plan.data : target.position,
                                ownerObstacleID: stage.kind == .collectData ? nil : target.ownerObstacleID)
                        }, interactionDuration: stage.interactionDuration, holdDuration: stage.holdDuration)
                })
        }
        let offset = base.spawns.isEmpty ? 0 : index * 3 % base.spawns.count
        let spawns = Array(base.spawns.dropFirst(offset)) + Array(base.spawns.prefix(offset))
        let map = try MapDefinition(id: base.id, version: base.version, displayName: base.displayName,
            minimum: base.minimum, maximum: base.maximum, terrain: base.terrain, obstacles: obstacles,
            playerStart: base.playerStart, spawns: spawns, reinforcementEntries: base.reinforcementEntries,
            waveStaging: plan.patrols, patrolAnchors: plan.patrols, extraction: base.extraction, extractionRadius: base.extractionRadius,
            dataSite: plan.data, radioSite: base.radioSite, serviceApproach: base.serviceApproach,
            roads: base.roads, supportSurfaces: base.supportSurfaces, levelProps: base.levelProps,
            scenery: base.scenery, environment: environment, resources: base.resources, operation: operation, breaches: base.breaches)
        var conditions = ["Daten: \(plan.location). Wachwege: \(plan.patrolDescription)."]
        switch base.id {
        case "blacksite":
            conditions.append(index == 1 ? "Strom/Funk aus; Servicetor offen; Maschinen und Dampf aus." : "Strom/Funk an; Servicetor zu; Maschinen und Dampf aktiv.")
            conditions.append("Boden und Vegetation unverändert; Tarnung bleibt ortsabhängig.")
        case "nebelwacht":
            conditions.append(index == 1 ? "Funk und Maschine aus; Felsboden unverändert." : "Funk und Maschine an; Felsboden unverändert.")
            let times = map.environment.smokeEmitters.map { String(format: "%.1f", $0.firstEmissionTime(seed: seed)) }.joined(separator: " / ")
            conditions.append("Erste Gischt nach \(times) s; danach alle 24 s, mit Vorwarnung.")
        case "sundkai":
            conditions.append(index == 1 ? "Funk und Maschine aus; Operation braucht beide Hafenrelais." : "Funk und Maschine an; Operation braucht beide Hafenrelais.")
            conditions.append("Watbecken unverändert; trockene Wege und Ausgänge bleiben frei.")
        case "kessel9":
            conditions.append(index == 2 ? "Westschott offen, Ostschott zu; Kabelrampe immer frei." : "Westschott zu, Ostschott offen; Kabelrampe immer frei.")
            conditions.append(index == 1 ? "Funk und Maschine aus; trockener Boden unverändert." : "Funk und Maschine an; trockener Boden unverändert.")
        case "sirocco":
            conditions.append(index == 0 ? "Alle Glasfelder intakt; Querungen um die offenen Enden." : index == 1 ?
                "Ein westliches Querfeld offen; übrige Glasfelder intakt." : "Zwei gegenüberliegende Querfelder offen; übriges Glas intakt.")
            conditions.append("Trockener Salzboden unverändert; Funkstation bleibt erreichbar.")
        default: break
        }
        return ResolvedRunVariant(id: "\(base.id)-\(index + 1)", title: plan.title, conditions: conditions, map: map)
    }
}
