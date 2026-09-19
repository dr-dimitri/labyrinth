import Foundation
import simd

/// A roofless salt greenhouse. Its three ground routes are always open;
/// breaking a side pane exchanges an optional shortcut for its optical cover.
public enum SiroccoDefinition {
    public static let start = SIMD3<Float>(0,0,34)
    public static let dataSite = SIMD3<Float>(0,0,-23)
    public static let radioSite = SIMD3<Float>(0,0,0)
    public static let northExit = SIMD3<Float>(0,0,-35)
    public static let saltExit = SIMD3<Float>(30,0,32)
    public static let paneCenters: [Float] = [-11.5,-6.9,-2.3,2.3,6.9,11.5]

    private static func fixed(_ id: Int, _ point: SIMD3<Float>, _ size: SIMD3<Float>, kind: ObstacleKind = .container) -> Obstacle {
        var box = Obstacle(id: id,kind: kind,position: point,size: size)
        box.health = .infinity
        return box
    }
    public static let breaches: [MapBreachDefinition] = (0..<12).map { index in
        let side = index/6, panel = index%6, firstPost = 3020+side*7+panel
        return MapBreachDefinition(ownerObstacleID: 3001+index,kind: .glass,
            visibility: [1,4].contains(panel) ? .clear : .opaque,
            frameObstacleIDs: [firstPost,firstPost+1,3034+side])
    }
    public static let obstacles: [Obstacle] = {
        var result: [Obstacle] = []
        for side in 0..<2 {
            let x: Float = side == 0 ? -12 : 12
            for (index,z) in paneCenters.enumerated() {
                result.append(Obstacle(id: 3001+side*6+index,kind: .glass,
                    position: SIMD3(x,0,z),size: SIMD3(0.14,3,4.4)))
            }
            for post in 0..<7 {
                result.append(fixed(3020+side*7+post,SIMD3(x,0,Float(post)*4.6-13.8),SIMD3(0.2,3.2,0.2)))
            }
            result.append(fixed(3034+side,SIMD3(x,3,0),SIMD3(0.2,0.2,27.8)))
        }
        for (index,point) in [SIMD3<Float>(-6,0,-8),SIMD3(6,0,-8),SIMD3(-6,0,8),SIMD3(6,0,8)].enumerated() {
            result.append(fixed(3040+index,point,SIMD3(3,1.1,8),kind: .bunker))
        }
        result += [
            fixed(3044,SIMD3(-20,0,6),SIMD3(6,2.5,8),kind: .bunker),
            fixed(3045,SIMD3(27,0,6),SIMD3(6,2.4,8)),
            fixed(3046,SIMD3(21.5,0,8),SIMD3(2,0.55,2.4),kind: .bunker),
            fixed(3047,SIMD3(23.2,0,8),SIMD3(1.6,1.2,2.4),kind: .bunker),
            fixed(3050,SIMD3(1.6,0,-2.2),SIMD3(1.6,1.4,1.2)),
            Obstacle(id: 3060,kind: .crate,position: SIMD3(-18,0,-19),size: SIMD3(1.6,1.4,1.6)),
            Obstacle(id: 3061,kind: .crate,position: SIMD3(6,0,23),size: SIMD3(1.6,1.4,1.6)),
            Obstacle(id: 3062,kind: .barrel,position: SIMD3(-19.8,0,-19),size: SIMD3(0.8,1.15,0.8))
        ]
        return result
    }()

    public static let terrain: TerrainProfile = {
        func smooth(_ value: Float) -> Float { let t = max(0,min(1,value)); return t*t*(3-2*t) }
        func base(_ x: Float,_ z: Float) -> Float {
            // The raised salt bank has broad walkable ground approaches, not
            // an invisible deck or a required climb. Its plateau is 1.8 m high.
            let bank = smooth((x-15)/9)*smooth((z+34)/8)*(1-smooth((z-16)/12))
            return 1+1.8*bank
        }
        var heights: [Float] = []; heights.reserveCapacity(257*257)
        for iz in -128...128 { for ix in -128...128 {
            let x = Float(ix), z = Float(iz)
            var y = base(x,z), foundation: Float?
            for box in obstacles {
                let low = SIMD2(floor(box.minimum.x),floor(box.minimum.z))-SIMD2(repeating: 0.75)
                let high = SIMD2(ceil(box.maximum.x),ceil(box.maximum.z))+SIMD2(repeating: 0.75)
                let dx = max(0,low.x-x,x-high.x), dz = max(0,low.y-z,z-high.y)
                let target: Float = [3045,3046,3047].contains(box.id) ? 2.8 : 1
                if dx == 0 && dz == 0 { foundation = target; break }
                let weight = 1-smooth(max(dx,dz)/4)
                y = y*(1-weight)+target*weight
            }
            if let foundation { y = foundation }
            // Distant low dunes establish the basin silhouette outside play.
            let outside = max(smooth((abs(x)-40)/22),smooth((abs(z)-44)/22))
            y += outside*(2.5+1.2*sin(x*0.045)*cos(z*0.055))
            heights.append(y)
        } }
        return .heightField(try! TerrainHeightField(origin: SIMD2(-128,-128),width: 257,depth: 257,samples: heights))
    }()

    public static func make() throws -> MapDefinition {
        var environment = MapEnvironmentDefinition()
        environment.sunDirection = simd_normalize(SIMD3(-0.48,0.71,-0.51))
        environment.sunIntensity = 0.88
        environment.fogColor = SIMD3(0.66,0.65,0.57)
        environment.shadowTarget = SIMD3(0,2,0); environment.shadowExtent = 66
        environment.groundRegions = [
            MapSurfaceRegion(minimum: SIMD2(-36,-40),maximum: SIMD2(-14,40),material: .concrete,camouflage: .rubble,soundSurface: .gravel),
            MapSurfaceRegion(minimum: SIMD2(14,-40),maximum: SIMD2(36,40),material: .concrete,camouflage: .rubble,soundSurface: .gravel)
        ]
        let operation = MapOperationDefinition(extractions: [
            ExtractionDefinition(id: "north",title: "Salztor Nord",detail: "Kurzer Rückweg vom Funk über die offene Nordkante.",
                position: northExit,radius: 2.5,holdDuration: 3,routeKind: .exposed),
            ExtractionDefinition(id: "salt",title: "Salzrampe Südost",detail: "Länger am Pumpenhaus vorbei über die erhöhte Salzrampe zum Südausgang.",
                position: saltExit,radius: 2.5,holdDuration: 3,routeKind: .sheltered)
        ],requiredStages: [
            OperationStageDefinition(id: "data",title: "Gewächshausdaten sichern",kind: .collectData,
                targets: [.init(id: "greenhouse-data",title: "Gewächshausdaten",position: dataSite)],interactionDuration: 0.8),
            OperationStageDefinition(id: "radio",title: "Funktransfer halten",kind: .radioTransfer,
                targets: [.init(id: "salt-radio",title: "Salzfunk",position: radioSite,ownerObstacleID: 3050)],interactionDuration: 0.8,holdDuration: 12)
        ])
        return try MapDefinition(id: "sirocco",version: 2,displayName: "Sirocco",minimum: SIMD3(-36,-2,-40),maximum: SIMD3(36,12,40),
            terrain: terrain,obstacles: obstacles,playerStart: PlayerState(position: start),
            spawns: [SIMD3(-30,0,-30),SIMD3(5,0,-32),SIMD3(31,0,-30),SIMD3(-29,0,0),SIMD3(31,0,-6),
                     SIMD3(-29,0,27),SIMD3(31,0,27),SIMD3(-3,0,15.5),SIMD3(9,0,-17)],
            reinforcementEntries: [SIMD3(-31,0,-34),SIMD3(6,0,-34),SIMD3(32,0,-30),SIMD3(-31,0,32),SIMD3(32,0,32)],
            waveStaging: [SIMD3(-24,0,-18),SIMD3(25,0,-13),SIMD3(0,0,18)],
            extraction: northExit,extractionRadius: 2.5,dataSite: dataSite,radioSite: radioSite,serviceApproach: radioSite,
            roads: [MapSurfaceRegion(minimum: SIMD2(-3.5,-30),maximum: SIMD2(3.5,30),material: .concrete)],
            levelProps: [3046:.lowerServiceStep,3047:.upperServiceStep],
            scenery: SiroccoScenery.make(obstacles: obstacles),environment: environment,resources: resources,operation: operation,breaches: breaches)
    }

    /// Existing photographed concrete and coastal rock retain their detail;
    /// the map's small salt tint is authored by its terrain appearance.
    public static let resources: MapResourceReferences = {
        var paths = MapResourceReferences.blacksite.texturePaths.filter { (25...30).contains($0.key) }
        for start in [0,6,14] { for (offset,name) in ["color","normal","roughness"].enumerated() {
            paths[start+offset] = "maps/nebelwacht/textures/coastal-rock/\(name).jpg"
        } }
        for start in [3,17] { for (offset,name) in ["color","normal","roughness"].enumerated() {
            paths[start+offset] = "maps/nebelwacht/textures/concrete/\(name).jpg"
        } }
        paths[23] = "maps/nebelwacht/environment/sky.jpg"
        return MapResourceReferences(texturePaths: paths,soldierAsset: "characters/soldier/soldier.glb")
    }()

    public static let westRoute = [start,SIMD3(-26,0,30),SIMD3(-26,0,-23),dataSite]
    public static let centralRoute = [start,SIMD3(0,0,16),SIMD3(0,0,-16),dataSite]
    public static let eastRoute = [start,SIMD3(33,0,30),SIMD3(33,0,-16),SIMD3(18,0,-17),SIMD3(0,0,-17),dataSite]
    public static let dataToRadioRoute = [dataSite,radioSite]
    public static let northReturnRoute = [radioSite,SIMD3(0,0,-16),northExit]
    public static let saltReturnRoute = [radioSite,SIMD3(0,0,16),saltExit]
    public static let breachedSaltReturnRoute = [radioSite,SIMD3(9,0,3.5),SIMD3(14,0,3.5),saltExit]
}
