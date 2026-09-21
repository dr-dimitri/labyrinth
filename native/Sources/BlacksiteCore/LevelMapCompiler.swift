import Foundation
import simd

public enum LevelMapPurpose: Sendable { case preview, play }

extension LevelDocument {
    /// The only document-to-world adapter. Preview may use temporary markers;
    /// neither preview nor combat writes those defaults back to the document.
    public func makeMap(purpose: LevelMapPurpose = .play) throws -> MapDefinition {
        try validateDraft()
        let terrain = TerrainProfile.heightField(try TerrainHeightField(
            origin: SIMD2(Float(bounds.x), Float(bounds.z)), width: bounds.width + 1,
            depth: bounds.depth + 1, samples: self.terrain.heights))
        let minimum = SIMD3(Float(bounds.x), terrain.minimumHeight - 2, Float(bounds.z))
        let maximum = SIMD3(Float(bounds.x + bounds.width), terrain.maximumHeight + 64, Float(bounds.z + bounds.depth))
        let center = (minimum + maximum) * 0.5
        let fallback = SIMD3(center.x, 0, center.z)
        func inside(_ p: SIMD3<Float>) -> Bool {
            p.x > minimum.x && p.x < maximum.x && p.z > minimum.z && p.z < maximum.z
        }
        let singletonKinds: [LevelMarkerKind] = [.playerStart, .extraction, .dataSite, .radioSite, .serviceApproach]
        if purpose == .play {
            for kind in singletonKinds where markers.filter({ $0.kind == kind }).count != 1 {
                throw LevelDocumentError("Zum Spielen wird genau ein Marker „\(kind.rawValue)“ benötigt.")
            }
            for kind in [LevelMarkerKind.reinforcement, .waveStaging] where !markers.contains(where: { $0.kind == kind }) {
                throw LevelDocumentError("Zum Spielen fehlt ein Marker „\(kind.rawValue)“.")
            }
            for marker in markers {
                guard inside(marker.position.value), abs(marker.position.y) <= 0.05 else {
                    throw LevelDocumentError("Marker „\(marker.id)“ muss am Boden innerhalb der Kartengrenzen liegen.")
                }
            }
            guard markers.filter({ $0.kind == .patrol }).count <= 6 else {
                throw LevelDocumentError("Zum Spielen sind höchstens sechs Patrouillenanker zulässig.")
            }
        }
        func matching(_ kind: LevelMarkerKind) -> [LevelMarker] {
            markers.filter { $0.kind == kind && inside($0.position.value) }
        }
        func point(_ kind: LevelMarkerKind) -> SIMD3<Float> { matching(kind).first?.position.value ?? fallback }
        func points(_ kind: LevelMarkerKind, required: Bool = false) -> [SIMD3<Float>] {
            let values = matching(kind).map { $0.position.value }
            return required && values.isEmpty ? [fallback] : values
        }
        var obstacles: [Obstacle] = [], obstacleIDs = Set<Int>()
        for object in objects {
            // validateDraft has already checked all catalog references and transforms.
            guard let item = LevelObjectCatalog.item(id: object.catalogID) else {
                throw LevelDocumentError("Unbekannte Vorlage „\(object.catalogID)“.")
            }
            var size = item.size * object.scale.value
            if !object.quarterTurns.isMultiple(of: 2) { let width = size.x; size.x = size.z; size.z = width }
            var position = object.position.value
            if object.heightMode == .absolute { position.y -= terrain.height(x: position.x, z: position.z) }
            if purpose == .play {
                guard position.x - size.x * 0.5 >= minimum.x, position.x + size.x * 0.5 <= maximum.x,
                      position.z - size.z * 0.5 >= minimum.z, position.z + size.z * 0.5 <= maximum.z else {
                    throw LevelDocumentError("Objekt „\(object.id)“ ragt über den Kartenrand.")
                }
            }
            let runtimeID = Self.obstacleID(object.id)
            guard obstacleIDs.insert(runtimeID).inserted else {
                throw LevelDocumentError("Objekt „\(object.id)“ erzeugt eine kollidierende Laufzeit-ID; bitte eine neue Instanz-ID vergeben.")
            }
            obstacles.append(Obstacle(id: runtimeID, kind: item.kind, position: position, size: size))
        }
        var player = PlayerState(position: point(.playerStart))
        player.yaw = matching(.playerStart).first?.yaw ?? 0
        var scenery = MapSceneryDefinition()
        scenery.center = SIMD2(center.x, center.z)
        scenery.renderMinimum = SIMD2(minimum.x - 8, minimum.z - 8)
        scenery.renderMaximum = SIMD2(maximum.x + 8, maximum.z + 8)
        scenery.denseMinimum = SIMD2(minimum.x, minimum.z)
        scenery.denseMaximum = SIMD2(maximum.x, maximum.z)
        scenery.menuTarget = SIMD3(center.x, terrain.height(x: center.x, z: center.z), center.z)
        scenery.menuEye = scenery.menuTarget + SIMD3(0, 14, Float(bounds.depth) * 0.45)
        var environment = MapEnvironmentDefinition()
        environment.sunDirection = simd_normalize(self.environment.sunDirection.value)
        environment.sunIntensity = self.environment.sunIntensity
        environment.fogColor = self.environment.fogColor.value
        environment.shadowTarget = scenery.menuTarget
        environment.shadowExtent = Float(max(bounds.width, bounds.depth)) * 0.8
        environment.shadowDistance = max(100, terrain.maximumHeight - terrain.minimumHeight + 80)
        environment.shadowDepth = environment.shadowDistance * 2
        for surface in self.environment.surfaces {
            let material: SurfaceMaterial = surface.material == .asphalt ? .asphalt : .soil
            let camouflage: CamouflageGround
            switch surface.material {
            case .earth: camouflage = .earth
            case .grass: camouflage = .vegetation
            case .rock: camouflage = .rubble
            case .asphalt: camouflage = .none
            }
            environment.groundRegions.append(MapSurfaceRegion(minimum: SIMD2(surface.x, surface.z),
                maximum: SIMD2(surface.x + surface.width, surface.z + surface.depth), material: material, camouflage: camouflage))
            let tint: SIMD3<Float>
            switch surface.material {
            case .earth: tint = SIMD3(0.50, 0.39, 0.27)
            case .grass: tint = SIMD3(0.35, 0.48, 0.28)
            case .rock: tint = SIMD3(0.52, 0.54, 0.55)
            case .asphalt: tint = SIMD3(0.24, 0.26, 0.27)
            }
            let half = SIMD2(surface.width, surface.depth) * 0.5
            scenery.terrainAppearance.regions.append(MapGroundAppearanceRegion(shape: .rectangle,
                center: SIMD2(surface.x, surface.z) + half, inner: half, outer: half + SIMD2(repeating: 0.1),
                leafReduction: surface.material == .grass ? 0 : 1, minimumLeaf: surface.material == .grass ? 1 : 0,
                tint: tint, tintStrength: 0.8))
        }
        let radius = matching(.extraction).first?.radius ?? 2
        let safeRadius = purpose == .preview ? min(radius, Float(min(bounds.width, bounds.depth)) * 0.4) : radius
        let map = try MapDefinition(id: "custom." + id, version: revision, displayName: name,
            minimum: minimum, maximum: maximum, terrain: terrain, obstacles: obstacles, playerStart: player,
            spawns: points(.enemySpawn), reinforcementEntries: points(.reinforcement, required: true),
            waveStaging: points(.waveStaging, required: true), patrolAnchors: Array(points(.patrol).prefix(6)),
            extraction: point(.extraction), extractionRadius: safeRadius, dataSite: point(.dataSite),
            radioSite: point(.radioSite), serviceApproach: point(.serviceApproach), scenery: scenery,
            environment: environment, resources: MapDefinition.blacksite.resources)
        if purpose == .play { try map.validateGameplay() }
        return map
    }

    /// Stable across launches and array reordering; unlike Swift's randomized Hasher.
    static func obstacleID(_ id: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash & 0x0fff_ffff) + 1
    }
}
