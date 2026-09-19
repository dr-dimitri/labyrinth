import Foundation
import simd

/// A dry mountain barrier with two short channel lanes and independent west
/// and east bypasses. No required objective depends on either powered bulkhead.
public enum Kessel9Definition {
    public static let start = SIMD3<Float>(0,0,34)
    public static let dataSite = SIMD3<Float>(-12,0,-25)
    public static let radioSite = SIMD3<Float>(12,0,19)
    public static let northExit = SIMD3<Float>(-27,0,-34)
    public static let cableExit = SIMD3<Float>(29,0,32)
    public static let switchPoint = SIMD3<Float>(0,0,23.2)
    public static let gateA = SIMD3<Float>(-6,0,4)
    public static let gateB = SIMD3<Float>(8,0,4)
    private static func fixed(_ id: Int, _ p: SIMD3<Float>, _ size: SIMD3<Float>) -> Obstacle {
        var box = Obstacle(id: id,kind: .container,position: p,size: size); box.health = .infinity; return box
    }
    public static let obstacles: [Obstacle] = [
        // Concrete ribs leave two six-metre channel openings and both bypasses.
        Obstacle(id: 2901,kind: .bunker,position: SIMD3(-17,0,4),size: SIMD3(16,4.4,2)),
        Obstacle(id: 2902,kind: .bunker,position: SIMD3(1,0,4),size: SIMD3(8,4.4,2)),
        Obstacle(id: 2903,kind: .bunker,position: SIMD3(17,0,4),size: SIMD3(12,4.4,2)),
        fixed(2910,gateA,SIMD3(6,3.2,0.4)),
        fixed(2911,gateB,SIMD3(6,3.2,0.4)),
        // Low dividing channel walls preserve several transverse escape gaps.
        Obstacle(id: 2920,kind: .bunker,position: SIMD3(1,0,13),size: SIMD3(1.4,2.4,10)),
        Obstacle(id: 2921,kind: .bunker,position: SIMD3(1,0,-8),size: SIMD3(1.4,2.4,16)),
        Obstacle(id: 2922,kind: .bunker,position: SIMD3(-16,0,-28),size: SIMD3(12,3.6,3)),
        Obstacle(id: 2923,kind: .bunker,position: SIMD3(-21,0,-23),size: SIMD3(2,3.6,7)),
        // Cable-route bays protect against the central channel, with open ends.
        Obstacle(id: 2924,kind: .bunker,position: SIMD3(21,0,24),size: SIMD3(2,2.3,7)),
        Obstacle(id: 2925,kind: .bunker,position: SIMD3(21,0,-10),size: SIMD3(2,2.3,7)),
        Obstacle(id: 2926,kind: .bunker,position: SIMD3(21,0,-28),size: SIMD3(2,2.3,6)),
        Obstacle(id: 2930,kind: .container,position: SIMD3(0,0,22),size: SIMD3(1.2,1.3,0.6)),
        Obstacle(id: 2931,kind: .container,position: SIMD3(12,0,16.9),size: SIMD3(1.6,1.4,1.2)),
        Obstacle(id: 2940,kind: .crate,position: SIMD3(-16,0,17),size: SIMD3(1.7,1.4,1.7)),
        Obstacle(id: 2941,kind: .crate,position: SIMD3(16,0,-18),size: SIMD3(1.7,1.4,1.7)),
        Obstacle(id: 2942,kind: .barrel,position: SIMD3(18,0,-18),size: SIMD3(0.8,1.1,0.8))
    ]
    public static let terrain: TerrainProfile = {
        func smooth(_ x: Float) -> Float { let t = min(1,max(0,x)); return t*t*(3-2*t) }
        var heights: [Float] = []; heights.reserveCapacity(257*257)
        for z in -128...128 { for x in -128...128 {
            let px = Float(x), pz = Float(z)
            // The channel and all foundations are level. The east bypass is
            // reached by a real gradual terrain ramp beyond the concrete bays.
            var y: Float = 4 + 1.2*smooth((px-23)/5)
            let mountain = smooth((abs(px)-39)/22) * (3 + 7*smooth((-pz+15)/55))
            y += mountain + 5*smooth((-pz-44)/22)
            heights.append(y)
        } }
        return .heightField(try! TerrainHeightField(origin: SIMD2(-128,-128),width: 257,depth: 257,samples: heights))
    }()
    public static func make() throws -> MapDefinition {
        var environment = MapEnvironmentDefinition()
        environment.sunDirection = simd_normalize(SIMD3(-0.68,0.24,-0.69)); environment.sunIntensity = 0.85
        environment.fogColor = SIMD3(0.48,0.47,0.43); environment.shadowTarget = SIMD3(0,4,0); environment.shadowExtent = 66
        environment.groundRegions = [MapSurfaceRegion(minimum: SIMD2(-36,-40),maximum: SIMD2(-24,40),
            material: .concrete,camouflage: .rubble,soundSurface: .gravel)]
        environment.devices = [
            .init(id: 2950,kind: .maintenanceSwitch,ownerObstacleID: 2930,interactionPoints: [switchPoint],linkedGateIDs: [2951,2952]),
            .init(id: 2951,kind: .serviceGate,ownerObstacleID: 2910,interactionPoints: [gateA+SIMD3(0,0,1.6)],
                openOffset: SIMD3(0,3.6,0),controllerID: 2950),
            .init(id: 2952,kind: .serviceGate,ownerObstacleID: 2911,interactionPoints: [gateB+SIMD3(0,0,1.6)],
                openOffset: SIMD3(0,3.6,0),controllerID: 2950,initiallyOpen: true),
            .init(id: 2953,kind: .generator,ownerObstacleID: 2931,interactionPoints: [SIMD3(12,0,15.4)],noiseEmitterIDs: [2954])
        ]
        environment.noiseEmitters = [.init(id: 2954,position: SIMD3(12,1.2,16.2),strength: 0.65,range: 15,ownerObstacleID: 2931)]
        environment.alarm = .init(radioDeviceID: 2953,radioPosition: SIMD3(12,1.18,16.275),radioRange: 50,
            returnGuardPosts: [SIMD3(8,0,-3),SIMD3(28,0,9)],reinforcementCount: 2)
        let operation = MapOperationDefinition(preparations: [.init(kind: .openGate,deviceID: 2951),.init(kind: .disableRadio,deviceID: 2953)],extractions: [
            .init(id: "north",title: "Betriebsausgang Nord",detail: "Zurück durch den Kanal; die Schottstellung bestimmt die verfügbare Spur. Der offene Westweg bietet einen längeren Umweg.",
                position: northExit,radius: 2.5,holdDuration: 3,routeKind: .exposed),
            .init(id: "cable",title: "Kabelausgang Südost",detail: "Über die stets offene Kabelrampe mit festen Deckungsbuchten.",
                position: cableExit,radius: 2.5,holdDuration: 3,routeKind: .sheltered)
        ],requiredStages: [
            .init(id: "data",title: "Leitstanddaten sichern",kind: .collectData,
                targets: [.init(id: "control-data",title: "Leitstanddaten",position: dataSite)],interactionDuration: 0.8),
            .init(id: "radio",title: "Unteren Verteiler halten",kind: .radioTransfer,
                targets: [.init(id: "lower-relay",title: "Unterer Funkverteiler",position: radioSite)],interactionDuration: 1,holdDuration: 8)
        ])
        return try MapDefinition(id: "kessel9",displayName: "Kessel-9",minimum: SIMD3(-36,-2,-40),maximum: SIMD3(36,16,40),
            terrain: terrain,obstacles: obstacles,playerStart: PlayerState(position: start),
            spawns: [SIMD3(-29,0,-35),SIMD3(-6,0,-35),SIMD3(29,0,-35),SIMD3(-29,0,15),SIMD3(29,0,-15),
                     SIMD3(-29,0,34),SIMD3(29,0,34),SIMD3(-12,0,-15),SIMD3(8,0,-5)],
            reinforcementEntries: [SIMD3(-29,0,-35),SIMD3(-6,0,-35),SIMD3(29,0,-35),SIMD3(-29,0,34),SIMD3(29,0,34)],
            waveStaging: [SIMD3(-28,0,10),SIMD3(8,0,10),SIMD3(28,0,-20)],
            extraction: northExit,extractionRadius: 2.5,dataSite: dataSite,radioSite: radioSite,serviceApproach: switchPoint,
            roads: [MapSurfaceRegion(minimum: SIMD2(-10,-38),maximum: SIMD2(12,38),material: .concrete)],
            scenery: Kessel9Scenery.make(obstacles: obstacles),environment: environment,resources: resources,operation: operation)
    }
    public static let resources: MapResourceReferences = {
        var paths = MapResourceReferences.blacksite.texturePaths
        for (offset,name) in ["color","normal","roughness"].enumerated() {
            paths[offset] = "maps/nebelwacht/textures/concrete/\(name).jpg"
            paths[3+offset] = "maps/nebelwacht/textures/concrete/\(name).jpg"
            paths[6+offset] = "maps/nebelwacht/textures/coastal-rock/\(name).jpg"
            paths[14+offset] = "maps/nebelwacht/textures/coastal-rock/\(name).jpg"
        }
        return MapResourceReferences(texturePaths: paths,soldierAsset: "characters/soldier/soldier.glb")
    }()
    public static let westRoute = [start,SIMD3(-28,0,31),SIMD3(-28,0,-18),SIMD3(-12,0,-18),dataSite]
    public static let eastRoute = [start,SIMD3(28,0,31),SIMD3(28,0,-20),SIMD3(8,0,-20),SIMD3(-12,0,-20),dataSite]
    public static let channelA = [switchPoint,SIMD3(-6,0,21),SIMD3(-6,0,-20),SIMD3(-12,0,-20),dataSite]
    public static let channelB = [start,SIMD3(8,0,30),SIMD3(8,0,-20),SIMD3(-12,0,-20),dataSite]
    public static let radioReturnA = [dataSite,SIMD3(-6,0,-20),SIMD3(-6,0,20),SIMD3(8,0,20),radioSite]
    public static let radioReturnB = [dataSite,SIMD3(-12,0,-20),SIMD3(8,0,-20),SIMD3(8,0,20),radioSite]
    public static let radioReturnEast = [dataSite,SIMD3(-12,0,-20),SIMD3(28,0,-20),SIMD3(28,0,18),radioSite]
    public static let northReturn = [radioSite,SIMD3(8,0,20),SIMD3(-6,0,20),SIMD3(-28,0,20),SIMD3(-28,0,-34),northExit]
    public static let cableReturn = [radioSite,SIMD3(28,0,19),cableExit]
}
