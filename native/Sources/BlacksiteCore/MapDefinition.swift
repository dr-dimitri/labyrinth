import Foundation
import simd

public struct MapLineSegment: Sendable {
    public let start: SIMD3<Float>, end: SIMD3<Float>
    public init(start: SIMD3<Float>, end: SIMD3<Float>) { self.start = start; self.end = end }
}

public enum MapVisualMesh: Sendable { case box, rock, grass }
public struct MapTree: Sendable {
    public let position: SIMD3<Float>
    public let height: Float
    public let seed: UInt64
    public init(position: SIMD3<Float>, height: Float, seed: UInt64) {
        self.position = position; self.height = height; self.seed = seed
    }
}
public struct MapVisualBox: Sendable {
    public let position: SIMD3<Float>, size: SIMD3<Float>, color: SIMD3<Float>
    public let material: SIMD4<Float>
    public let yaw: Float
    public let castsShadow: Bool, levelDetail: Bool, grounded: Bool
    public let mesh: MapVisualMesh
    /// A relative offset from this obstacle's grounded base, or world space.
    public let ownerID: Int?
    public init(position: SIMD3<Float>, size: SIMD3<Float>, color: SIMD3<Float>, material: SIMD4<Float>,
                yaw: Float = 0, castsShadow: Bool = true, ownerID: Int? = nil, levelDetail: Bool = false,
                mesh: MapVisualMesh = .box, grounded: Bool = false) {
        self.position = position; self.size = size; self.color = color; self.material = material
        self.yaw = yaw; self.castsShadow = castsShadow; self.ownerID = ownerID; self.levelDetail = levelDetail
        self.mesh = mesh; self.grounded = grounded
    }
}

public struct MapSign: Sendable {
    public let position: SIMD3<Float>
    public let width: Float, materialID: Float, yaw: Float
    public let ownerID: Int?
    public init(position: SIMD3<Float>, width: Float, materialID: Float, yaw: Float = 0, ownerID: Int? = nil) {
        self.position = position; self.width = width; self.materialID = materialID; self.yaw = yaw; self.ownerID = ownerID
    }
}

public struct MapSceneryDefinition: Sendable {
    public var renderMinimum = SIMD2<Float>(-260, -260), renderMaximum = SIMD2<Float>(260, 260)
    public var denseMinimum = SIMD2<Float>(-48, -48), denseMaximum = SIMD2<Float>(48, 48)
    public var menuEye = SIMD3<Float>(12, 6.5, 33), menuTarget = SIMD3<Float>(-3, 2, -8)
    public var center = SIMD2<Float>(0, 0)
    public var watchtowers: [SIMD3<Float>] = [], lightPoles: [SIMD3<Float>] = []
    public var fences: [MapLineSegment] = []
    public var extractionGate: SIMD3<Float>?
    public var boxes: [MapVisualBox] = []
    public var signs: [MapSign] = []
    public var trees: [MapTree] = []
    public var terrainAppearance = MapTerrainAppearance()
    public init() {}
}

/// Material and camouflage are deliberately independent. These are metadata
/// only; subsequent gameplay features may consume them without reading pixels.
public enum CamouflageGround: String, Sendable { case none, vegetation, earth, rubble }
public struct MapSurfaceRegion: Sendable {
    public let minimum: SIMD2<Float>, maximum: SIMD2<Float>
    public let material: SurfaceMaterial
    public let camouflage: CamouflageGround
    public let soundSurface: SurfaceSound?
    public init(minimum: SIMD2<Float>, maximum: SIMD2<Float>, material: SurfaceMaterial,
                camouflage: CamouflageGround = .none, soundSurface: SurfaceSound? = nil) {
        self.minimum = minimum; self.maximum = maximum; self.material = material; self.camouflage = camouflage
        self.soundSurface = soundSurface
    }
    public func contains(x: Float, z: Float) -> Bool {
        x >= minimum.x && x <= maximum.x && z >= minimum.y && z <= maximum.y
    }
}
public struct MapEnvironmentDefinition: Sendable {
    public var sunDirection = simd_normalize(SIMD3<Float>(-0.68, 0.24, -0.69))
    public var fogColor = SIMD3<Float>(0.40, 0.49, 0.54)
    public var shadowTarget = SIMD3<Float>(0, 0, 0)
    public var shadowExtent: Float = 65, shadowDistance: Float = 100, shadowDepth: Float = 220, viewDistance: Float = 450
    public var groundRegions: [MapSurfaceRegion] = []
    public var vegetationZones: [EnvironmentZone] = []
    public var noiseEmitters: [NoiseEmitterDefinition] = []
    public var alarm: MapAlarmDefinition?
    public var devices: [WorldInteractableDefinition] = []
    public var spotlights: [WorldSpotlightDefinition] = []
    /// Legacy name retained as a view of the same authoritative data.
    public var visibilityVolumes: [MapVisibilityVolume] {
        get { vegetationZones }
        set { vegetationZones = newValue }
    }
    public init() {}
}
public struct MapResourceReferences: Sendable, Equatable {
    /// Relative to the application's asset root. Missing texture slots use the
    /// renderer's tiny neutral fallback instead of loading another map's asset.
    public let assetDirectory: String
    public let texturePaths: [Int: String]
    /// Normalized source-image rectangles: x, y, width, height. This belongs to
    /// the resource reference, not a special texture-slot rule in the renderer.
    public let textureCrops: [Int: SIMD4<Float>]
    public let soldierAsset: String?
    public init(assetDirectory: String = "", texturePaths: [Int: String] = [:], textureCrops: [Int: SIMD4<Float>] = [:], soldierAsset: String? = nil) {
        self.assetDirectory = assetDirectory; self.texturePaths = texturePaths; self.textureCrops = textureCrops; self.soldierAsset = soldierAsset
    }
}

public struct MapValidationError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// A selected map owns every world-space rule and authored anchor. Actor and
/// obstacle y values are offsets above its terrain; simulation snapshots are
/// world-space. No registry or previous-map cache is retained by this value.
public struct MapDefinition: Sendable {
    public let id: String, displayName: String
    public let version: Int
    public let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    public let terrain: TerrainProfile
    public let obstacles: [Obstacle]
    public let playerStart: PlayerState
    public let spawns: [SIMD3<Float>], reinforcementEntries: [SIMD3<Float>], waveStaging: [SIMD3<Float>]
    let spawnCandidates: [SIMD3<Float>]
    public let extraction: SIMD3<Float>, dataSite: SIMD3<Float>, radioSite: SIMD3<Float>, serviceApproach: SIMD3<Float>
    public let extractionRadius: Float
    public let roads: [MapSurfaceRegion]
    /// Shallow visible asphalt/curb overlays used by casings and contact decals.
    /// Their y values are terrain-relative, like ordinary authored obstacles.
    public let supportSurfaces: [Obstacle]
    public let levelProps: [Int: LevelProp]
    public let scenery: MapSceneryDefinition
    public let environment: MapEnvironmentDefinition
    public let resources: MapResourceReferences
    public let operation: MapOperationDefinition?

    public init(id: String, version: Int = 1, displayName: String,
                minimum: SIMD3<Float>, maximum: SIMD3<Float>, terrain: TerrainProfile,
                obstacles: [Obstacle] = [], playerStart: PlayerState,
                spawns: [SIMD3<Float>] = [], reinforcementEntries: [SIMD3<Float>], waveStaging: [SIMD3<Float>],
                extraction: SIMD3<Float>, extractionRadius: Float = 3.5, dataSite: SIMD3<Float>, radioSite: SIMD3<Float>,
                serviceApproach: SIMD3<Float>? = nil, roads: [MapSurfaceRegion] = [], supportSurfaces: [Obstacle] = [],
                levelProps: [Int: LevelProp] = [:], scenery: MapSceneryDefinition? = nil,
                environment: MapEnvironmentDefinition? = nil, resources: MapResourceReferences = MapResourceReferences(),
                operation: MapOperationDefinition? = nil) throws {
        self.id = id; self.version = version; self.displayName = displayName
        self.minimum = minimum; self.maximum = maximum; self.terrain = terrain; self.obstacles = obstacles
        self.playerStart = playerStart; self.spawns = spawns; self.reinforcementEntries = reinforcementEntries
        var seenEntries = Set<SIMD3<Float>>()
        spawnCandidates = (spawns + reinforcementEntries).filter { seenEntries.insert($0).inserted }
        self.waveStaging = waveStaging; self.extraction = extraction; self.extractionRadius = extractionRadius
        self.dataSite = dataSite; self.radioSite = radioSite; self.serviceApproach = serviceApproach ?? playerStart.position
        self.roads = roads; self.supportSurfaces = supportSurfaces; self.levelProps = levelProps
        let center = (minimum + maximum) * 0.5
        let floor = terrain.height(x: center.x, z: center.z)
        var plainScenery = MapSceneryDefinition()
        plainScenery.center = SIMD2(center.x, center.z)
        plainScenery.renderMinimum = SIMD2(minimum.x - 8, minimum.z - 8)
        plainScenery.renderMaximum = SIMD2(maximum.x + 8, maximum.z + 8)
        plainScenery.denseMinimum = SIMD2(floorf(minimum.x), floorf(minimum.z))
        plainScenery.denseMaximum = SIMD2(ceilf(maximum.x), ceilf(maximum.z))
        plainScenery.menuEye = SIMD3(center.x, floor + 6, maximum.z - 2)
        plainScenery.menuTarget = SIMD3(center.x, floor + 1, center.z)
        self.scenery = scenery ?? plainScenery
        var plainEnvironment = MapEnvironmentDefinition()
        plainEnvironment.shadowTarget = SIMD3(center.x, floor, center.z)
        plainEnvironment.shadowExtent = max(maximum.x - minimum.x, maximum.z - minimum.z) * 0.8
        self.environment = environment ?? plainEnvironment; self.resources = resources; self.operation = operation
        try validateStructure()
    }

    /// Preserve all authored metadata while explicitly overriding a test profile.
    public func withTerrain(_ value: TerrainProfile) -> MapDefinition {
        copying(terrain: value, environment: environment, operation: operation)
    }
    /// Isolated legacy worlds have no authored vegetation unless a map was selected.
    func withoutVegetation() -> MapDefinition {
        var environment = environment; environment.vegetationZones = []; environment.noiseEmitters = []; environment.devices = []; environment.spotlights = []; environment.alarm = nil
        return copying(terrain: terrain, environment: environment, operation: nil)
    }
    private func copying(terrain value: TerrainProfile, environment: MapEnvironmentDefinition, operation: MapOperationDefinition?) -> MapDefinition {
        // These operations preserve validated dimensions, identifiers and geometry.
        try! MapDefinition(id: id, version: version, displayName: displayName, minimum: minimum, maximum: maximum,
                           terrain: value, obstacles: obstacles, playerStart: playerStart, spawns: spawns,
                           reinforcementEntries: reinforcementEntries, waveStaging: waveStaging,
                           extraction: extraction, extractionRadius: extractionRadius, dataSite: dataSite, radioSite: radioSite,
                           serviceApproach: serviceApproach, roads: roads, supportSurfaces: supportSurfaces,
                           levelProps: levelProps, scenery: scenery, environment: environment, resources: resources, operation: operation)
    }
    public func supportsMission(_ kind: MissionKind) -> Bool { kind != .operation || operation != nil }

    public func grounded(_ point: SIMD3<Float>) -> SIMD3<Float> {
        point + SIMD3(0, terrain.height(x: point.x, z: point.z), 0)
    }
    public var groundedSupportSurfaces: [Obstacle] {
        supportSurfaces.map { value in
            var result = Obstacle(id: value.id, kind: value.kind, position: grounded(value.position), size: value.size)
            result.health = value.health; result.destroyed = value.destroyed; return result
        }
    }
    public func groundMaterial(at point: SIMD3<Float>) -> SurfaceMaterial {
        if let road = roads.last(where: { $0.contains(x: point.x, z: point.z) }) { return road.material }
        return environment.groundRegions.last(where: { $0.contains(x: point.x, z: point.z) })?.material ?? .soil
    }
    public func levelProp(for obstacle: Obstacle) -> LevelProp? {
        guard let prop = levelProps[obstacle.id], let authored = obstacles.first(where: { $0.id == obstacle.id }),
              obstacle.kind == authored.kind, obstacle.size == authored.size,
              obstacle.position.x == authored.position.x, obstacle.position.z == authored.position.z else { return nil }
        return prop
    }

    /// Run on load, not per frame. Candidate entries may be blocked by mutable
    /// cover initially, but must be usable after that cover is removed.
    public func validateGameplay() throws {
        let simulation = CombatSimulation(map: self)
        let start = simulation.player.position
        guard abs(playerStart.position.y) <= 0.05, simulation.hasReachableRoute(from: start, to: start) else {
            throw MapValidationError("Karte \(id): Spielerstart ist blockiert oder nicht am Boden.")
        }
        for (name, point) in [("Evakuierung", extraction), ("Datenstation", dataSite), ("Funkstation", radioSite), ("Servicezugang", serviceApproach)] {
            let target = grounded(point)
            guard abs(target.y - terrain.height(x: target.x, z: target.z)) <= 0.05,
                  simulation.hasReachableRoute(from: start, to: target) else {
                throw MapValidationError("Karte \(id): \(name) ist vom Spielerstart nicht am Boden erreichbar.")
            }
        }
        for exit in operation?.extractions ?? [] {
            guard simulation.hasReachableRoute(from: grounded(dataSite), to: grounded(exit.position)) else {
                throw MapValidationError("Karte \(id): Operationsausgang \(exit.title) ist vom Pflichtziel nicht am Boden erreichbar.")
            }
        }
        let permanent = obstacles.filter { !$0.health.isFinite }
        let opened = CombatSimulation(world: permanent, startingPlayer: playerStart, terrain: terrain, map: self)
        for (index, point) in reinforcementEntries.enumerated() {
            let target = grounded(point)
            guard abs(point.y) <= 0.05, terrain.normal(x: point.x, z: point.z).y >= 0.72,
                  opened.hasReachableRoute(from: opened.player.position, to: target) else {
                throw MapValidationError("Karte \(id): Verstärkungseingang \(index + 1) ist dauerhaft blockiert oder nicht am Boden erreichbar.")
            }
        }
        for point in spawns + waveStaging {
            guard abs(point.y) <= 0.05, simulation.hasReachableRoute(from: start, to: grounded(point)) else {
                throw MapValidationError("Karte \(id): Ein Start- oder Sammelpunkt ist nicht am Boden erreichbar.")
            }
        }
    }

    private func validateStructure() throws {
        func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
        func finite2(_ p: SIMD2<Float>) -> Bool { p.x.isFinite && p.y.isFinite }
        func finite4(_ p: SIMD4<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite }
        func inside(_ p: SIMD3<Float>) -> Bool {
            finite(p) && p.x > minimum.x && p.x < maximum.x && p.z > minimum.z && p.z < maximum.z
        }
        guard !id.isEmpty, !displayName.isEmpty, version > 0 else { throw MapValidationError("Karte benötigt ID, Namen und eine positive Version.") }
        let size = maximum - minimum
        guard finite(minimum), finite(maximum), abs(minimum.x) < 100_000, abs(minimum.z) < 100_000,
              size.x >= 12, size.z >= 12, size.x <= 128, size.z <= 128 else {
            throw MapValidationError("Karte \(id): Grenzen müssen endlich und zwischen 12 und 128 Metern breit/tief sein.")
        }
        guard inside(playerStart.position), playerStart.yaw.isFinite, playerStart.pitch.isFinite,
              playerStart.health.isFinite, playerStart.health > 0, playerStart.height.isFinite, playerStart.height > 0,
              playerStart.stamina.isFinite, (0...100).contains(playerStart.stamina),
              [extraction, dataSite, radioSite, serviceApproach].allSatisfy(inside),
              extractionRadius.isFinite, extractionRadius > 0, extractionRadius < min(size.x, size.z) * 0.5 else {
            throw MapValidationError("Karte \(id): Spielerstart oder Missionsanker liegen außerhalb der Kartengrenzen.")
        }
        guard !reinforcementEntries.isEmpty, !waveStaging.isEmpty,
              (spawns + reinforcementEntries + waveStaging).allSatisfy(inside) else {
            throw MapValidationError("Karte \(id): Eintritts- und Sammelpunkte müssen vorhanden und innerhalb der Grenzen sein.")
        }
        var ids = Set<Int>()
        for obstacle in obstacles + supportSurfaces {
            guard ids.insert(obstacle.id).inserted else { throw MapValidationError("Karte \(id): Objekt-ID \(obstacle.id) ist doppelt vergeben.") }
            guard finite(obstacle.position), finite(obstacle.size), obstacle.size.x > 0, obstacle.size.y > 0, obstacle.size.z > 0,
                  !obstacle.health.isNaN, obstacle.health > 0 else { throw MapValidationError("Karte \(id): Objekt \(obstacle.id) besitzt ungültige Maße oder Trefferpunkte.") }
        }
        guard levelProps.keys.allSatisfy({ key in obstacles.contains { $0.id == key } }) else {
            throw MapValidationError("Karte \(id): Eine Objektgestaltung verweist auf eine fehlende Collider-ID.")
        }
        for region in roads + environment.groundRegions {
            guard region.minimum.x.isFinite, region.minimum.y.isFinite, region.maximum.x.isFinite, region.maximum.y.isFinite,
                  region.minimum.x < region.maximum.x, region.minimum.y < region.maximum.y else {
                throw MapValidationError("Karte \(id): Eine Bodenregion besitzt ungültige Grenzen.")
            }
        }
        guard environment.noiseEmitters.count <= NoiseEmitterState.maximumCount else {
            throw MapValidationError("Karte \(id): Höchstens vier Maschinen-Geräuschquellen sind zulässig.")
        }
        for emitter in environment.noiseEmitters {
            guard ids.insert(emitter.id).inserted, inside(emitter.position),
                  emitter.strength.isFinite, (0...1).contains(emitter.strength),
                  emitter.range.isFinite, emitter.range > 0, emitter.range <= 40,
                  emitter.ownerObstacleID.map({ owner in obstacles.contains { $0.id == owner } }) ?? true else {
                throw MapValidationError("Karte \(id): Geräuschquelle \(emitter.id) besitzt ungültige Daten oder eine fehlende Objekt-ID.")
            }
        }
        guard environment.devices.count <= 4, environment.spotlights.count <= 2 else {
            throw MapValidationError("Karte \(id): Höchstens vier Geräte und zwei Strahler sind zulässig.")
        }
        for light in environment.spotlights {
            guard ids.insert(light.id).inserted, inside(light.position), finite(light.direction),
                  simd_length_squared(light.direction).isFinite, simd_length_squared(light.direction) > 0.01, finite(light.color),
                  light.color.x >= 0, light.color.y >= 0, light.color.z >= 0,
                  light.range.isFinite, (0.5...32).contains(light.range),
                  light.innerCos.isFinite, light.outerCos.isFinite, light.outerCos >= 0.05,
                  light.innerCos > light.outerCos, light.innerCos <= 1,
                  light.power.isFinite, (0...1).contains(light.power),
                  light.ownerObstacleID.map({ owner in obstacles.contains { $0.id == owner } }) ?? true else {
                throw MapValidationError("Karte \(id): Strahler \(light.id) benötigt 0,5–32 m Reichweite, outerCos ≥ 0,05, endliche Richtung und nichtnegative Lichtfarbe.")
            }
        }
        var deviceOwners = Set<Int>()
        for device in environment.devices {
            guard ids.insert(device.id).inserted, deviceOwners.insert(device.ownerObstacleID).inserted,
                  let owner = obstacles.first(where: { $0.id == device.ownerObstacleID }),
                  !device.interactionPoints.isEmpty, device.interactionPoints.count <= 2, device.interactionPoints.allSatisfy(inside),
                  device.noiseEmitterIDs.allSatisfy({ id in environment.noiseEmitters.contains { $0.id == id } }),
                  device.lightIDs.allSatisfy({ id in environment.spotlights.contains { $0.id == id } }),
                  device.generatorID.map({ id in environment.devices.contains { $0.id == id && $0.kind == .generator } }) ?? true,
                  finite(device.openOffset) else {
                throw MapValidationError("Karte \(id): Gerät \(device.id) besitzt ungültige Verbindungen oder Bedienpunkte.")
            }
            if device.kind == .serviceGate {
                // Current gate is a vertical lift: thin footprint cannot be mantled,
                // and its unambiguous height threshold keeps navigation bounded.
                guard device.openOffset.x == 0, device.openOffset.z == 0, device.openOffset.y >= 2.1, device.openOffset.y <= 6,
                      owner.kind == .container, owner.size.z < 0.6 else {
                    throw MapValidationError("Karte \(id): Hubtor benötigt ein dünnes Metallgehäuse und mindestens 2,1 m vertikalen Hub.")
                }
            }
        }
        if let alarm = environment.alarm {
            guard environment.devices.contains(where: { $0.id == alarm.radioDeviceID && $0.kind == .generator }), inside(alarm.radioPosition),
                  alarm.radioRange.isFinite, (10...80).contains(alarm.radioRange),
                  alarm.returnGuardPosts.count <= 2, alarm.returnGuardPosts.allSatisfy(inside),
                  (0...2).contains(alarm.reinforcementCount) else {
                throw MapValidationError("Karte \(id): Alarm benötigt einen vorhandenen Generator als Funkversorgung, 10–80 m Reichweite und höchstens zwei Wachposten/Verstärkungen.")
            }
        }
        if let operation {
            var exitIDs = Set<String>(), preparationIDs = Set<Int>()
            guard operation.extractions.count == 2, operation.preparations.count <= 2 else {
                throw MapValidationError("Karte \(id): Eine Feldoperation benötigt zwei Ausgänge und höchstens zwei optionale Vorbereitungen.")
            }
            for exit in operation.extractions {
                guard !exit.id.isEmpty, exitIDs.insert(exit.id).inserted, !exit.title.isEmpty, !exit.detail.isEmpty,
                      inside(exit.position), abs(exit.position.y) <= 0.05,
                      exit.radius.isFinite, (1...5).contains(exit.radius),
                      exit.holdDuration.isFinite, (1...10).contains(exit.holdDuration),
                      exit.position.x - exit.radius >= minimum.x, exit.position.x + exit.radius <= maximum.x,
                      exit.position.z - exit.radius >= minimum.z, exit.position.z + exit.radius <= maximum.z else {
                    throw MapValidationError("Karte \(id): Operationsausgang besitzt ungültige Kennung, Maße oder Aufenthaltsdauer.")
                }
            }
            let exits = operation.extractions
            guard horizontalDistance(exits[0].position, exits[1].position) > exits[0].radius + exits[1].radius + 0.5 else {
                throw MapValidationError("Karte \(id): Operationsausgänge dürfen sich nicht überschneiden.")
            }
            for preparation in operation.preparations {
                guard preparationIDs.insert(preparation.deviceID).inserted,
                      let device = environment.devices.first(where: { $0.id == preparation.deviceID }),
                      device.kind == (preparation.kind == .disableRadio ? .generator : .serviceGate),
                      preparation.kind != .disableRadio || environment.alarm?.radioDeviceID == preparation.deviceID else {
                    throw MapValidationError("Karte \(id): Optionale Vorbereitung benötigt ein passendes vorhandenes Gerät; Funkabschaltung muss die tatsächliche Funkversorgung betreffen.")
                }
            }
        }
        var volumeIDs = Set<String>()
        var totalPlants = 0
        guard environment.vegetationZones.count <= 16 else {
            throw MapValidationError("Karte \(id): Höchstens 16 Vegetationszonen sind zulässig.")
        }
        for volume in environment.vegetationZones {
            let size = volume.maximum - volume.minimum
            guard !volume.id.isEmpty, volumeIDs.insert(volume.id).inserted,
                  finite(volume.minimum), finite(volume.maximum),
                  size.x >= EnvironmentZone.minimumFootprintSpan, size.z >= EnvironmentZone.minimumFootprintSpan,
                  size.y >= EnvironmentZone.minimumHeight, size.x <= 32, size.z <= 32, size.y <= 6,
                  volume.minimum.x >= minimum.x, volume.maximum.x <= maximum.x,
                  volume.minimum.z >= minimum.z, volume.maximum.z <= maximum.z,
                  (!volume.terrainRelative || volume.minimum.y >= 0),
                  volume.density.isFinite, (0...1).contains(volume.density) else {
                throw MapValidationError("Karte \(id): Ein Sichtschutzvolumen besitzt ungültige Daten; Breite/Tiefe müssen mindestens 0,6 m und die Höhe mindestens 0,25 m betragen.")
            }
            let plants = volume.requiredPlantCount
            guard plants <= EnvironmentZone.maximumPlantCount else {
                throw MapValidationError("Karte \(id): Vegetationszone \(volume.id) benötigt \(plants) Pflanzen; zulässig sind höchstens \(EnvironmentZone.maximumPlantCount) je Zone.")
            }
            totalPlants += plants
            guard totalPlants <= EnvironmentZone.maximumTotalPlantCount else {
                throw MapValidationError("Karte \(id): Vegetationszonen benötigen insgesamt \(totalPlants) Pflanzen; zulässig sind höchstens \(EnvironmentZone.maximumTotalPlantCount).")
            }
        }
        for box in scenery.boxes {
            guard finite(box.position), finite(box.size), finite(box.color), finite4(box.material), box.yaw.isFinite,
                  box.size.x > 0, box.size.y > 0, box.size.z > 0,
                  box.ownerID.map({ owner in obstacles.contains { $0.id == owner } }) ?? true else {
                throw MapValidationError("Karte \(id): Eine Kulisse besitzt ungültige Maße oder eine fehlende Objekt-ID.")
            }
        }
        let renderSize = scenery.renderMaximum - scenery.renderMinimum
        let denseSize = scenery.denseMaximum - scenery.denseMinimum
        guard finite2(scenery.renderMinimum), finite2(scenery.renderMaximum), finite2(scenery.denseMinimum), finite2(scenery.denseMaximum),
              renderSize.x > 0, renderSize.y > 0, renderSize.x <= 1024, renderSize.y <= 1024,
              denseSize.x > 0, denseSize.y > 0, denseSize.x <= 160, denseSize.y <= 160,
              scenery.renderMinimum.x <= scenery.denseMinimum.x, scenery.renderMinimum.y <= scenery.denseMinimum.y,
              scenery.renderMaximum.x >= scenery.denseMaximum.x, scenery.renderMaximum.y >= scenery.denseMaximum.y,
              scenery.denseMinimum.x <= minimum.x, scenery.denseMinimum.y <= minimum.z,
              scenery.denseMaximum.x >= maximum.x, scenery.denseMaximum.y >= maximum.z,
              finite(scenery.menuEye), finite(scenery.menuTarget), simd_distance_squared(scenery.menuEye, scenery.menuTarget) > 0.01 else {
            throw MapValidationError("Karte \(id): Render- und Geländerastergrenzen müssen endlich, begrenzt und ineinander enthalten sein.")
        }
        for tree in scenery.trees {
            guard finite(tree.position), tree.height.isFinite, tree.height > 0, tree.height <= 100 else {
                throw MapValidationError("Karte \(id): Ein Baum besitzt ungültige Position oder Höhe.")
            }
        }
        for sign in scenery.signs {
            guard finite(sign.position), sign.width.isFinite, sign.width > 0, sign.materialID.isFinite, sign.yaw.isFinite,
                  sign.ownerID.map({ owner in obstacles.contains { $0.id == owner } }) ?? true else {
                throw MapValidationError("Karte \(id): Ein Schild besitzt ungültige Maße oder eine fehlende Objekt-ID.")
            }
        }
        for fence in scenery.fences {
            guard finite(fence.start), finite(fence.end), simd_distance_squared(fence.start, fence.end) > 0.001 else {
                throw MapValidationError("Karte \(id): Ein Zaunsegment besitzt ungültige Endpunkte.")
            }
        }
        guard (scenery.watchtowers + scenery.lightPoles + (scenery.extractionGate.map { [$0] } ?? [])).allSatisfy(finite) else {
            throw MapValidationError("Karte \(id): Eine Kulissenposition ist ungültig.")
        }
        let appearance = scenery.terrainAppearance, gradient = appearance.leafGradient
        guard finite4(gradient), gradient.z > gradient.y, appearance.regions.count <= 8 else {
            throw MapValidationError("Karte \(id): Terrainmaterialprofil ist ungültig oder enthält mehr als acht Zonen.")
        }
        for region in appearance.regions {
            guard finite2(region.center), finite2(region.radii), finite2(region.inner), finite2(region.outer), finite(region.tint),
                  region.radii.x > 0, region.radii.y > 0, region.inner.x >= 0, region.inner.y >= 0,
                  region.outer.x > region.inner.x, region.outer.y > region.inner.y,
                  [region.leafReduction, region.minimumLeaf, region.tintStrength, region.roughnessReduction].allSatisfy({ $0.isFinite }) else {
                throw MapValidationError("Karte \(id): Eine Terrainmaterialzone besitzt ungültige Radien oder Materialwerte.")
            }
        }
        guard finite(environment.sunDirection), simd_length_squared(environment.sunDirection) > 0.01,
              finite(environment.fogColor), finite(environment.shadowTarget),
              [environment.shadowExtent, environment.shadowDistance, environment.shadowDepth, environment.viewDistance].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw MapValidationError("Karte \(id): Licht- oder Sichtweitenangaben sind ungültig.")
        }
        let references = Array(resources.texturePaths.values) + [resources.assetDirectory] + (resources.soldierAsset.map { [$0] } ?? [])
        guard resources.texturePaths.keys.allSatisfy({ (0..<31).contains($0) && $0 != 10 && $0 != 24 }),
              references.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw MapValidationError("Karte \(id): Ressourcen müssen relative Pfade innerhalb des Assetpakets verwenden.")
        }
        for (slot, crop) in resources.textureCrops {
            guard resources.texturePaths[slot] != nil, finite4(crop), crop.x >= 0, crop.y >= 0,
                  crop.z > 0, crop.w > 0, crop.x + crop.z <= 1, crop.y + crop.w <= 1 else {
                throw MapValidationError("Karte \(id): Texturausschnitt \(slot) muss innerhalb des zugehörigen Quellbilds liegen.")
            }
        }
    }

    public static let blacksite: MapDefinition = try! MapDefinition(
        id: "blacksite", displayName: "Blacksite", minimum: BlacksiteMapData.minimum, maximum: BlacksiteMapData.maximum,
        terrain: .battlefield, obstacles: BlacksiteMapData.obstacles, playerStart: PlayerState(), spawns: BlacksiteMapData.spawns,
        reinforcementEntries: BlacksiteMapData.reinforcementEntries, waveStaging: [SIMD3(-6, 0, 10), SIMD3(6, 0, 10)],
        extraction: BlacksiteMapData.extraction, dataSite: BlacksiteMapData.dataSite, radioSite: BlacksiteMapData.radioSite,
        serviceApproach: BlacksiteMapData.serviceApproach,
        roads: [MapSurfaceRegion(minimum: SIMD2(-6, -45.5), maximum: SIMD2(6, 45.5), material: .asphalt)],
        supportSurfaces: [Obstacle(id: -10001, kind: .bunker, position: .zero, size: SIMD3(12, 0.015, 91)),
                          Obstacle(id: -10002, kind: .bunker, position: SIMD3(-6.2, 0, 0), size: SIMD3(0.3, 0.08, 85)),
                          Obstacle(id: -10003, kind: .bunker, position: SIMD3(6.2, 0, 0), size: SIMD3(0.3, 0.08, 85))],
        levelProps: Dictionary(uniqueKeysWithValues: LevelProp.allCases.map { ($0.rawValue, $0) }),
        scenery: MapSceneryDefinition.blacksite, environment: {
            var environment = MapEnvironmentDefinition()
            environment.vegetationZones = BlacksiteVegetation.zones
            environment.noiseEmitters = BlacksiteMachinery.emitters
            environment.devices = BlacksiteDevices.definitions
            environment.spotlights = BlacksiteDevices.lights
            environment.alarm = BlacksiteAlarm.definition
            return environment
        }(), resources: .blacksite, operation: BlacksiteOperation.definition)

    /// A small elevated, translated fixture catches accidental Blacksite bounds,
    /// zero-height starts, roads and the former 12m terrain-ray ceiling.
    public static let testRange: MapDefinition = {
        let field = try! TerrainHeightField(origin: SIMD2(90, 190), width: 41, depth: 53,
            samples: (0..<(41 * 53)).map { index in
                let x = index % 41 + 90
                let sampleX = (104...107).contains(x) ? 106 : (108...112).contains(x) ? 110 : (113...115).contains(x) ? 114 : x
                return 18 + Float(sampleX - 90) * 0.04
            })
        var scenery = MapSceneryDefinition()
        scenery.center = SIMD2(110, 216); scenery.renderMinimum = SIMD2(90, 190); scenery.renderMaximum = SIMD2(130, 242)
        scenery.denseMinimum = SIMD2(96, 196); scenery.denseMaximum = SIMD2(124, 236)
        scenery.menuEye = SIMD3(119, 25, 235); scenery.menuTarget = SIMD3(110, 19, 214)
        scenery.boxes = [MapVisualBox(position: SIMD3(110, 0.005, 216), size: SIMD3(4, 0.02, 36),
                                     color: SIMD3(0.61, 0.63, 0.59), material: SIMD4(0.9, 0, 0, 2), castsShadow: false, grounded: true)]
        var environment = MapEnvironmentDefinition()
        environment.shadowTarget = SIMD3(110, 19, 216)
        environment.shadowExtent = 32; environment.shadowDistance = 70; environment.shadowDepth = 140; environment.viewDistance = 160
        return try! MapDefinition(id: "test-range", displayName: "Prüfgelände", minimum: SIMD3(98, 0, 198), maximum: SIMD3(122, 0, 234),
            terrain: .heightField(field), obstacles: [Obstacle(id: 301, kind: .container, position: SIMD3(106, 0, 217), size: SIMD3(3, 3.1, 7)),
                                                     Obstacle(id: 302, kind: .crate, position: SIMD3(114, 0, 216), size: SIMD3(2, 1.4, 2))],
            playerStart: PlayerState(position: SIMD3(110, 0, 230)),
            spawns: [SIMD3(102, 0, 202), SIMD3(118, 0, 202)],
            reinforcementEntries: [SIMD3(102, 0, 202), SIMD3(110, 0, 202), SIMD3(118, 0, 202), SIMD3(102, 0, 210), SIMD3(118, 0, 210)],
            waveStaging: [SIMD3(102, 0, 216), SIMD3(118, 0, 216)],
            extraction: SIMD3(110, 0, 202), extractionRadius: 2.5, dataSite: SIMD3(102, 0, 228), radioSite: SIMD3(118, 0, 218),
            roads: [MapSurfaceRegion(minimum: SIMD2(108, 198), maximum: SIMD2(112, 234), material: .concrete)],
            supportSurfaces: [Obstacle(id: -10301, kind: .bunker, position: SIMD3(110, 0, 216), size: SIMD3(4, 0.015, 36))],
            scenery: scenery, environment: environment, resources: .testRange)
    }()
}

/// Source compatibility for external fixtures. Live rules use simulation.map.
public enum GameMap {
    public static var minimum: SIMD3<Float> { MapDefinition.blacksite.minimum }
    public static var maximum: SIMD3<Float> { MapDefinition.blacksite.maximum }
    public static var extraction: SIMD3<Float> { MapDefinition.blacksite.extraction }
    public static var extractionRadius: Float { MapDefinition.blacksite.extractionRadius }
    public static var dataSite: SIMD3<Float> { MapDefinition.blacksite.dataSite }
    public static var radioSite: SIMD3<Float> { MapDefinition.blacksite.radioSite }
    public static var serviceApproach: SIMD3<Float> { MapDefinition.blacksite.serviceApproach }
    public static var obstacles: [Obstacle] { MapDefinition.blacksite.obstacles }
    static var spawns: [SIMD3<Float>] { MapDefinition.blacksite.spawns }
    static var reinforcementEntries: [SIMD3<Float>] { MapDefinition.blacksite.reinforcementEntries }
    public static func levelProp(for obstacle: Obstacle) -> LevelProp? { MapDefinition.blacksite.levelProp(for: obstacle) }
}
