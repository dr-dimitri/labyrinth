import Foundation
import simd

/// Authored fjord station: actual solid rock cover and announced optical spray.
public enum NebelwachtDefinition {
    public static let start = SIMD3<Float>(0, 0, 34)
    public static let dataSite = SIMD3<Float>(-27, 0, -24)
    public static let radioSite = SIMD3<Float>(26, 0, -21)
    public static let supplyExit = SIMD3<Float>(0, 0, -35)
    public static let westExit = SIMD3<Float>(-31, 0, 29)

    // All authored Y values are terrain offsets. Fixed rock cover is represented
    // by honest solid boxes; the stone skin must preserve those outer faces.
    public static let obstacles: [Obstacle] = [
        Obstacle(id: 2701, kind: .bunker, position: SIMD3(-16,0,21), size: SIMD3(5,2,4)),
        Obstacle(id: 2702, kind: .bunker, position: SIMD3(-21,0,5), size: SIMD3(5,2.8,4)),
        Obstacle(id: 2703, kind: .bunker, position: SIMD3(-20,0,-10), size: SIMD3(6,3,5)),
        Obstacle(id: 2704, kind: .bunker, position: SIMD3(-31,0,-14), size: SIMD3(3,2.5,4)),
        Obstacle(id: 2710, kind: .bunker, position: SIMD3(-21,0,-27), size: SIMD3(10,3.5,7)),
        Obstacle(id: 2711, kind: .container, position: SIMD3(20,0,21), size: SIMD3(12,2.4,7)),
        Obstacle(id: 2712, kind: .container, position: SIMD3(23,0,7), size: SIMD3(9,2.8,6)),
        Obstacle(id: 2713, kind: .bunker, position: SIMD3(11.5,0,21), size: SIMD3(2,0.55,2.4)),
        Obstacle(id: 2714, kind: .bunker, position: SIMD3(13.2,0,21), size: SIMD3(1.6,1.2,2.4)),
        Obstacle(id: 2715, kind: .bunker, position: SIMD3(17,0,7), size: SIMD3(2,0.8,2.4)),
        Obstacle(id: 2716, kind: .bunker, position: SIMD3(17.9,0,7), size: SIMD3(1.2,1.55,2.4)),
        Obstacle(id: 2720, kind: .bunker, position: SIMD3(23,0,-29), size: SIMD3(8,2,8)),
        Obstacle(id: 2721, kind: .bunker, position: SIMD3(23,2,-29), size: SIMD3(5,3.6,5)),
        Obstacle(id: 2730, kind: .container, position: SIMD3(23,0,-22.8), size: SIMD3(1.6,1.4,1.2)),
        Obstacle(id: 2740, kind: .crate, position: SIMD3(-9,0,13), size: SIMD3(1.5,1.4,1.5)),
        Obstacle(id: 2741, kind: .crate, position: SIMD3(9,0,-10), size: SIMD3(1.6,1.6,1.6)),
        Obstacle(id: 2742, kind: .barrel, position: SIMD3(12,0,-12), size: SIMD3(0.8,1.15,0.8))
    ]

    public static func make() throws -> MapDefinition {
        let terrain = self.terrain
        var environment = MapEnvironmentDefinition()
        // Provisional direction; verify the brightest sky region during Metal QA.
        environment.sunDirection = simd_normalize(SIMD3(-0.38,0.62,-0.68))
        environment.sunIntensity = 0.55
        environment.fogColor = SIMD3(0.42,0.49,0.53)
        environment.shadowTarget = SIMD3(0,6,0); environment.shadowExtent = 66
        environment.groundRegions = [MapSurfaceRegion(minimum: SIMD2(-36,-40), maximum: SIMD2(-7,40),
            material: .concrete, camouflage: .rubble, soundSurface: .gravel)]
        environment.devices = [WorldInteractableDefinition(id: 2750, kind: .generator,
            ownerObstacleID: 2730, interactionPoints: [SIMD3(23,0,-20.9)], noiseEmitterIDs: [2751])]
        environment.noiseEmitters = [NoiseEmitterDefinition(id: 2751, position: SIMD3(23,1.2,-22.1),
            strength: 0.65, range: 16, ownerObstacleID: 2730)]
        environment.alarm = MapAlarmDefinition(radioDeviceID: 2750, radioPosition: SIMD3(23,1.18,-22.175),
            radioRange: 50, returnGuardPosts: [SIMD3(5,0,3), SIMD3(-8,0,-16)], reinforcementCount: 2)
        // Natural gusts have a seeded phase, then a regular period and an honest
        // three-second cue. The GPU consumes the actual core volume snapshots.
        environment.smokeEmitters = [
            SmokeEmitterDefinition(id: 2760, kind: .spray, position: SIMD3(0,0,6), radii: SIMD3(4,2.2,4),
                density: 3.2, lifetime: 8, interval: 24, startDelay: 6, warningLeadTime: 3, seededDelayRange: 2, warningIndicatorPosition: SIMD3(4.9,0,6)),
            SmokeEmitterDefinition(id: 2761, kind: .spray, position: SIMD3(0,0,-35), radii: SIMD3(4,2.2,4),
                density: 3.2, lifetime: 8, interval: 24, startDelay: 12, warningLeadTime: 3, seededDelayRange: 2, warningIndicatorPosition: SIMD3(4.9,0,-35))
        ]
        let operation = MapOperationDefinition(
            preparations: [OperationPreparationDefinition(kind: .disableRadio, deviceID: 2750)],
            extractions: [
                ExtractionDefinition(id: "supply", title: "Versorgungstor", detail:
                    "Kürzer über die offene Trasse. Eine angekündigte Gischtböe verdeckt zeitweise die Querung, schützt aber nicht vor Kugeln.",
                    position: supplyExit, radius: 2.5, holdDuration: 3, routeKind: .exposed),
                ExtractionDefinition(id: "rock", title: "Felsausgang West", detail:
                    "Länger über den westlichen Felsweg. Die Felsblöcke decken abschnittsweise gegen die Trasse; der Ausgang ist nicht rundum geschützt.",
                    position: westExit, radius: 2.5, holdDuration: 3, routeKind: .sheltered)
            ])
        return try MapDefinition(id: "nebelwacht", version: 2, displayName: "Nebelwacht",
            minimum: SIMD3(-36,-2,-40), maximum: SIMD3(36,16,40), terrain: terrain,
            obstacles: obstacles, playerStart: PlayerState(position: start),
            spawns: [SIMD3(-32,0,-35), SIMD3(5,0,-35), SIMD3(32,0,-17), SIMD3(-33,0,3),
                     SIMD3(32,0,34), SIMD3(-32,0,34), SIMD3(-8,0,-35), SIMD3(32,0,-34), SIMD3(-32,0,17)],
            reinforcementEntries: [SIMD3(-32,0,-35), SIMD3(5,0,-35), SIMD3(32,0,-17), SIMD3(32,0,34)],
            waveStaging: [SIMD3(-29,0,-17), SIMD3(4,0,-21), SIMD3(30,0,-7), SIMD3(12,0,31)],
            extraction: supplyExit, extractionRadius: 2.5, dataSite: dataSite, radioSite: radioSite,
            serviceApproach: SIMD3(23,0,-20.9),
            roads: [MapSurfaceRegion(minimum: SIMD2(-4.5,-38), maximum: SIMD2(4.5,38), material: .asphalt)],
            supportSurfaces: [Obstacle(id: -12701, kind: .bunker, position: .zero, size: SIMD3(9,0.016,76))],
            levelProps: [2713:.lowerServiceStep, 2714:.upperServiceStep, 2715:.lowerServiceStep, 2716:.upperServiceStep],
            scenery: NebelwachtScenery.make(obstacles: obstacles), environment: environment, resources: resources, operation: operation)
    }

    public static let terrain: TerrainProfile = try! makeTerrain()

    private static func makeTerrain() throws -> TerrainProfile {
        func smooth(_ value: Float) -> Float { let t = max(0,min(1,value)); return t*t*(3-2*t) }
        func bump(_ x: Float, _ z: Float, _ cx: Float, _ cz: Float, _ rx: Float, _ rz: Float) -> Float {
            exp(-pow((x-cx)/rx,2)-pow((z-cz)/rz,2))
        }
        var values = [Float](); values.reserveCapacity(257*257)
        for iz in -128...128 { for ix in -128...128 {
            let x = Float(ix), z = Float(iz)
            var y: Float = 6 + 2.1*bump(x,z,-25,-1,8,12) - 1.65*bump(x,z,-29,-18,7,9)
            y += 0.65*bump(x,z,-26,26,10,12)
            // The central road and module terraces have gentle, flat approaches.
            y = y*(1-smooth((x+12)/6)) + 6*smooth((x+12)/6)
            for box in obstacles {
                let dx = max(0,abs(x-box.position.x)-box.size.x*0.5-0.75)
                let dz = max(0,abs(z-box.position.z)-box.size.z*0.5-0.75)
                let pad = 1-smooth(max(dx,dz)/5)
                y = y*(1-pad) + 6*pad
            }
            // Cliffs and sea remain beyond the rectangular playable bounds.
            let coast = max(smooth((x-37)/13), smooth((-z-42)/15))
            y = y*(1-coast) - 1.4*coast
            if x < -44 { y += 11*smooth((-x-44)/35)*bump(x,z,-82,-13,40,80) }
            values.append(y)
        } }
        return .heightField(try TerrainHeightField(origin: SIMD2(-128,-128), width: 257, depth: 257, samples: values))
    }

    public static let resources: MapResourceReferences = {
        var paths = MapResourceReferences.blacksite.texturePaths.filter { (25...30).contains($0.key) }
        for start in [0,6,14] {
            for (offset,name) in ["color","normal","roughness"].enumerated() {
                paths[start+offset] = "maps/nebelwacht/textures/coastal-rock/\(name).jpg"
            }
        }
        for (offset,name) in ["color","normal","roughness"].enumerated() {
            paths[3+offset] = "maps/nebelwacht/textures/concrete/\(name).jpg"
            paths[17+offset] = "textures/asphalt/\(name).jpg"
        }
        paths[23] = "maps/nebelwacht/environment/sky.jpg"
        return MapResourceReferences(texturePaths: paths, soldierAsset: "characters/soldier/soldier.glb")
    }()

    // Ground routes used by the movement acceptance tests, not invulnerability claims.
    public static let westRoute: [SIMD3<Float>] = [start, SIMD3(-9,0,32), SIMD3(-29,0,28),
        SIMD3(-30,0,17), SIMD3(-29,0,9), SIMD3(-31,0,-1), SIMD3(-29,0,-8), SIMD3(-27,0,-17), dataSite]
    public static let centralRoute: [SIMD3<Float>] = [start, SIMD3(0,0,6), SIMD3(0,0,-4),
        SIMD3(-12,0,-6), SIMD3(-27,0,-6), SIMD3(-27,0,-17), dataSite]
    public static let supplyReturnRoute: [SIMD3<Float>] = [dataSite, SIMD3(-28,0,-34), supplyExit]
    public static let westReturnRoute: [SIMD3<Float>] = [dataSite, SIMD3(-28,0,-20), SIMD3(-27,0,-9), SIMD3(-31,0,-1), SIMD3(-29,0,9), SIMD3(-30,0,17), westExit]
    public static let eastGroundRoute: [SIMD3<Float>] = [start, SIMD3(31,0,32), SIMD3(32,0,18),
        SIMD3(32,0,5), SIMD3(31,0,-14), radioSite]
}
