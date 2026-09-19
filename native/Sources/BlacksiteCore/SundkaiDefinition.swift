import Foundation
import simd

/// Single-surface harbor terrain: shallow basins have a real floor, and the
/// dry cross-strips and east dike are raised terrain rather than floating decks.
public enum SundkaiDefinition {
    public static let start = SIMD3<Float>(0,0,34)
    public static let relayWest = SIMD3<Float>(-26,0,18)
    public static let relayEast = SIMD3<Float>(24,0,-10)
    public static let dataSite = SIMD3<Float>(-24,0,-28)
    public static let radioSite = SIMD3<Float>(27,0,-23.5)
    public static let serviceExit = SIMD3<Float>(0,0,-35)
    public static let harborExit = SIMD3<Float>(31,0,31)
    public static let pools = [
        MapShallowWaterZone(id: 2860,minimum: SIMD2(-10,5),maximum: SIMD2(10,25),surfaceHeight: 1),
        MapShallowWaterZone(id: 2861,minimum: SIMD2(-10,-21),maximum: SIMD2(10,-1),surfaceHeight: 1)
    ]
    private static func fixed(_ id: Int, _ p: SIMD3<Float>, _ size: SIMD3<Float>) -> Obstacle {
        var box = Obstacle(id: id,kind: .container,position: p,size: size); box.health = .infinity; return box
    }
    public static let obstacles: [Obstacle] = [
        Obstacle(id: 2801,kind: .bunker,position: SIMD3(-18,0,18),size: SIMD3(10,3,10)),
        Obstacle(id: 2802,kind: .bunker,position: SIMD3(-18,0,-11),size: SIMD3(10,3,10)),
        Obstacle(id: 2803,kind: .bunker,position: SIMD3(-17,0,-28),size: SIMD3(10,3.2,8)),
        Obstacle(id: 2810,kind: .container,position: SIMD3(15,0,18),size: SIMD3(5,2.4,6)),
        Obstacle(id: 2811,kind: .bunker,position: SIMD3(20,0,16),size: SIMD3(1,1.5,3)),
        Obstacle(id: 2812,kind: .bunker,position: SIMD3(20,0,5),size: SIMD3(1,1.5,3)),
        Obstacle(id: 2813,kind: .bunker,position: SIMD3(20,0,-18),size: SIMD3(1,1.5,3)),
        fixed(2830,SIMD3(-24.8,0,17.2),SIMD3(0.7,1.1,0.45)),
        fixed(2831,SIMD3(25.1,0,-11),SIMD3(0.7,1.1,0.45)),
        Obstacle(id: 2832,kind: .container,position: SIMD3(27,0,-25),size: SIMD3(1.6,1.4,1.2)),
        Obstacle(id: 2840,kind: .crate,position: SIMD3(-12,0,7),size: SIMD3(1.5,1.3,1.5)),
        Obstacle(id: 2841,kind: .crate,position: SIMD3(15,0,-18),size: SIMD3(1.5,1.3,1.5)),
        Obstacle(id: 2842,kind: .barrel,position: SIMD3(16.7,0,-18),size: SIMD3(0.8,1.15,0.8))
    ]
    public static let terrain: TerrainProfile = {
        func smooth(_ n: Float) -> Float { let t = max(0,min(1,n)); return t*t*(3-2*t) }
        func base(_ x: Float,_ z: Float) -> Float {
            let dike = smooth((x-18)/3) * (1-smooth((x-27)/3)) * smooth((z+34)/4) * (1-smooth((z-30)/4))
            var y: Float = 1 + 0.55*dike
            for pool in pools where pool.contains(x: x,z: z) {
                let edge = min(x-pool.minimum.x,pool.maximum.x-x,z-pool.minimum.y,pool.maximum.y-z)
                y -= 0.25*smooth(edge/1.5)
            }
            return y
        }
        var heights: [Float] = []; heights.reserveCapacity(257*257)
        for z in -128...128 { for x in -128...128 {
            let px = Float(x), pz = Float(z); var y = base(px,pz)
            // Every raster vertex enclosing an actual footprint is fixed to
            // its foundation. A neighbouring soft blend must not tilt it again.
            // The full surrounding cell matters for fractional barrel corners.
            if !pools.contains(where: { $0.contains(x: px,z: pz) }) {
                var foundation: Float?
                for box in obstacles {
                    let low = SIMD2(floor(box.minimum.x),floor(box.minimum.z))-SIMD2(repeating: 0.75)
                    let high = SIMD2(ceil(box.maximum.x),ceil(box.maximum.z))+SIMD2(repeating: 0.75)
                    let dx = max(0,low.x-px,px-high.x), dz = max(0,low.y-pz,pz-high.y)
                    if dx == 0 && dz == 0 { foundation = base(box.position.x,box.position.z); break }
                    let weight = 1-smooth(max(dx,dz)/2)
                    y = y*(1-weight)+base(box.position.x,box.position.z)*weight
                }
                if let foundation { y = foundation }
            }
            let coast = max(smooth((abs(px)-39)/10),smooth((abs(pz)-43)/10))
            y = y*(1-coast)-1.2*coast
            heights.append(y)
        } }
        return .heightField(try! TerrainHeightField(origin: SIMD2(-128,-128),width: 257,depth: 257,samples: heights))
    }()
    public static func make() throws -> MapDefinition {
        var environment = MapEnvironmentDefinition()
        environment.sunDirection = simd_normalize(SIMD3(-0.55,0.68,-0.48)); environment.sunIntensity = 0.85
        environment.shadowTarget = SIMD3(0,1,0); environment.shadowExtent = 66
        environment.fogColor = SIMD3(0.48,0.56,0.52); environment.shallowWaterZones = pools
        environment.vegetationZones = [SIMD2<Float>(-29,7),SIMD2(-28,-18),SIMD2(28,7),SIMD2(28,-24)].enumerated().map {
            EnvironmentZone(id: "sundkai-reeds-\($0.offset)",center: $0.element,radii: SIMD2(1.7,2.7),height: 1.2,density: 0.7,kind: .tallGrass)
        }
        environment.devices = [WorldInteractableDefinition(id: 2850,kind: .generator,ownerObstacleID: 2832,
            interactionPoints: [radioSite],noiseEmitterIDs: [2851])]
        environment.noiseEmitters = [NoiseEmitterDefinition(id: 2851,position: SIMD3(27,1.2,-24.3),strength: 0.65,range: 16,ownerObstacleID: 2832)]
        environment.alarm = MapAlarmDefinition(radioDeviceID: 2850,radioPosition: SIMD3(27,1.18,-24.375),radioRange: 50,
            returnGuardPosts: [SIMD3(-26,0,-3),SIMD3(24,0,3)],reinforcementCount: 2)
        let operation = MapOperationDefinition(preparations: [.init(kind: .disableRadio,deviceID: 2850)],extractions: [
            ExtractionDefinition(id: "service",title: "Serviceausgang Nord",detail: "Trockener kurzer Rückweg an den Lagerhäusern entlang.",
                position: serviceExit,radius: 2.5,holdDuration: 3,routeKind: .sheltered),
            ExtractionDefinition(id: "harbor",title: "Hafenrand Südost",detail: "Länger über den trockenen Damm. Die freie Wasserkante bietet keine harte Deckung.",
                position: harborExit,radius: 2.5,holdDuration: 3,routeKind: .exposed)
        ],requiredStages: [
            OperationStageDefinition(id: "relays",title: "Beide Hafenrelais aktivieren",kind: .relayGroup,targets: [
                .init(id: "relay-west",title: "Relais Lagerweg",position: relayWest,ownerObstacleID: 2830),
                .init(id: "relay-east",title: "Relais Ostdamm",position: relayEast,ownerObstacleID: 2831)]),
            OperationStageDefinition(id: "data",title: "Versanddaten sichern",kind: .collectData,
                targets: [.init(id: "shipping-data",title: "Versanddaten",position: dataSite)],interactionDuration: 0.8)
        ])
        return try MapDefinition(id: "sundkai",version: 2,displayName: "Sundkai",minimum: SIMD3(-36,-2,-40),maximum: SIMD3(36,12,40),
            terrain: terrain,obstacles: obstacles,playerStart: PlayerState(position: start),
            spawns: [SIMD3(-32,0,-35),SIMD3(4,0,-35),SIMD3(32,0,-30),SIMD3(32,0,-5),SIMD3(32,0,20),
                     SIMD3(32,0,35),SIMD3(-32,0,35),SIMD3(-32,0,4),SIMD3(-32,0,-18)],
            reinforcementEntries: [SIMD3(-32,0,-35),SIMD3(4,0,-35),SIMD3(32,0,-30),SIMD3(32,0,35),SIMD3(-32,0,35)],
            waveStaging: [SIMD3(-26,0,0),SIMD3(24,0,0)],extraction: serviceExit,extractionRadius: 2.5,
            dataSite: dataSite,radioSite: radioSite,serviceApproach: radioSite,
            roads: [29,1,-26].map { MapSurfaceRegion(minimum: SIMD2(-12,Float($0)-1.5),maximum: SIMD2(12,Float($0)+1.5),material: .wood,soundSurface: .wood) },
            supportSurfaces: [29,1,-26].enumerated().map { Obstacle(id: -12800-$0.offset,kind: .bunker,
                position: SIMD3(0,0,Float($0.element)),size: SIMD3(24,0.015,3)) },
            scenery: SundkaiScenery.make(obstacles: obstacles),environment: environment,resources: resources,operation: operation)
    }
    public static let resources: MapResourceReferences = {
        var paths = MapResourceReferences.blacksite.texturePaths
        for (offset,name) in ["color","normal","roughness"].enumerated() {
            let path = "maps/sundkai/textures/mud/\(name).jpg"
            paths[offset] = path; paths[14+offset] = path; paths[17+offset] = path
         }
        // Gameplay reeds use the grass mesh. These uncropped maps belong only
        // to the separately authored, outside-arena mangrove canopy.
        for (slot,name) in [(9,"color"),(20,"normal"),(21,"alpha"),(22,"roughness")] {
            paths[slot] = "maps/sundkai/foliage/broadleaf/\(name).jpg"
        }
        return MapResourceReferences(texturePaths: paths,soldierAsset: "characters/soldier/soldier.glb")
    }()
    public static let dryWestRoute = [start,SIMD3(-26,0,32),relayWest,SIMD3(-26,0,2),SIMD3(-26,0,-18),dataSite]
    public static let dryEastRoute = [start,SIMD3(24,0,32),SIMD3(24,0,16),relayEast,SIMD3(24,0,-22),SIMD3(-26,0,-22),dataSite]
    public static let wetRelayRoute = [relayWest,SIMD3(-26,0,11),SIMD3(-11,0,11),SIMD3(11,0,-10),relayEast]
    public static let dryRelayRoute = [relayWest,SIMD3(-26,0,1),SIMD3(24,0,1),relayEast]
    public static let serviceReturnRoute = [dataSite,SIMD3(-26,0,-34),serviceExit]
    public static let harborReturnRoute = [dataSite,SIMD3(-26,0,1),SIMD3(24,0,1),SIMD3(31,0,1),harborExit]
}
