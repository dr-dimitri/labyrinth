import simd

/// Purely visual material masks; they do not define stealth or collision rules.
public struct MapGroundAppearanceRegion: Sendable {
    public enum Shape: Sendable { case ellipse, rectangle }
    public let shape: Shape
    public let center, radii, inner, outer: SIMD2<Float>
    public let leafReduction, minimumLeaf, tintStrength, roughnessReduction: Float
    public let tint: SIMD3<Float>
    public init(shape: Shape, center: SIMD2<Float>, radii: SIMD2<Float> = SIMD2(repeating: 1),
                inner: SIMD2<Float>, outer: SIMD2<Float>, leafReduction: Float = 0, minimumLeaf: Float = 0,
                tint: SIMD3<Float> = SIMD3(repeating: 1), tintStrength: Float = 0, roughnessReduction: Float = 0) {
        self.shape=shape; self.center=center; self.radii=radii; self.inner=inner; self.outer=outer
        self.leafReduction=leafReduction; self.minimumLeaf=minimumLeaf; self.tint=tint
        self.tintStrength=tintStrength; self.roughnessReduction=roughnessReduction
    }
}
public struct MapTerrainAppearance: Sendable {
    /// X origin, inner/outer distance and strength of the broad leaf gradient.
    public var leafGradient=SIMD4<Float>(0,7,32,0)
    public var regions:[MapGroundAppearanceRegion]=[]
    public init() {}
}

private struct SceneryRandom {
    var seed:UInt64=183
    mutating func next()->Float { seed=2862933555777941757 &* seed &+ 3037000493;return Float((seed>>32)&0xffffff)/Float(0xffffff) }
}

extension MapSceneryDefinition {
    /// Authored coordinates and seeded placements of the original arena. The
    /// renderer consumes these records without recognizing the map's ID.
    public static let blacksite: MapSceneryDefinition = {
        var result=MapSceneryDefinition(), rng=SceneryRandom()
        result.renderMinimum=SIMD2(-220,-220);result.renderMaximum=SIMD2(220,220)
        result.denseMinimum=SIMD2(-48,-48);result.denseMaximum=SIMD2(48,48)
        result.menuEye=SIMD3(12,6.5,33);result.menuTarget=SIMD3(-3,2,-8)
        result.extractionGate=SIMD3(0,0,-39)
        result.watchtowers=[SIMD3(-32,0,-36),SIMD3(32,0,33)]
        result.lightPoles=[SIMD3(-8,0,25),SIMD3(9,0,-17),SIMD3(-11,0,-31),SIMD3(28,0,11)]
        for x:Float in [-38,38] { for z in stride(from:Float(-42),to:42,by:6) {
            result.fences.append(MapLineSegment(start:SIMD3(x,0,z),end:SIMD3(x,0,z+6)))
        } }
        for z:Float in [-42,42] { for x in stride(from:Float(-38),to:34,by:6) where abs(x+3)>7 {
            result.fences.append(MapLineSegment(start:SIMD3(x,0,z),end:SIMD3(x+6,0,z)))
        } }
        func box(_ position:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,
                 material:SIMD4<Float>=SIMD4(0.9,0,0,0),yaw:Float=0,shadow:Bool=true,
                 owner:Int?=nil,detail:Bool=false,mesh:MapVisualMesh = .box,grounded:Bool=false) {
            result.boxes.append(MapVisualBox(position:position,size:size,color:color,material:material,
                yaw:yaw,castsShadow:shadow,ownerID:owner,levelDetail:detail,mesh:mesh,grounded:grounded))
        }
        box(SIMD3(0,0.005,0),SIMD3(12,0.02,91),SIMD3(0.8,0.84,0.86),material:SIMD4(1,0,0,6),shadow:false,grounded:true)
        for z in stride(from:Float(-39),through:39,by:7) {
            box(SIMD3(0,0.0155,z),SIMD3(0.14,0.001,2.8),SIMD3(0.69,0.64,0.43),shadow:false,grounded:true)
        }
        for x:Float in [-6.2,6.2] {
            box(SIMD3(x,0.04,0),SIMD3(0.3,0.08,85),SIMD3(0.61,0.63,0.59),material:SIMD4(0.9,0,0,2),grounded:true)
        }
        // Preserve the original generator's random draw order exactly.
        for index in 0..<230 {
            let a=Float(index)*2.3999632+rng.next()*0.4
            let radius:Float=index<105 ? 55+rng.next()*50:105+rng.next()*100
            let x=cos(a)*radius,z=sin(a)*radius
            if abs(x)<41 && abs(z)<47 { continue }
            result.trees.append(MapTree(position:SIMD3(x,0,z),height:12+rng.next()*15,seed:UInt64(index+421)))
        }
        for index in 0..<25 {
            let a=Float(index)/25 * .pi*2,r:Float=174+rng.next()*50
            let s=SIMD3<Float>(16+rng.next()*20,11+rng.next()*19,18+rng.next()*24)
            box(SIMD3(cos(a)*r,-s.y*0.42,sin(a)*r),s,SIMD3(0.86,0.91,0.88),material:SIMD4(1,0,0,3),yaw:a,shadow:false,mesh:.rock,grounded:true)
        }
        for _ in 0..<42 {
            let a=rng.next() * .pi*2,r:Float=45+rng.next()*45,x=cos(a)*r,z=sin(a)*r
            if abs(x)<40 && abs(z)<45 { continue }
            let s:Float=0.7+rng.next()*2.8
            box(SIMD3(x,s*0.24,z),SIMD3(s*1.4,s,s),SIMD3(0.83,0.88,0.79),material:SIMD4(1,0,0,3),yaw:a,mesh:.rock,grounded:true)
        }
        for _ in 0..<250 {
            let x=(rng.next()-0.5)*130,z=(rng.next()-0.5)*130,s=0.08+rng.next()*0.38
            if abs(x)<6 { continue }
            box(SIMD3(x,s*0.2,z),SIMD3(s,s*0.5,s*0.8),SIMD3(0.6,0.62,0.55),material:SIMD4(1,0,0,3),shadow:false,mesh:.rock,grounded:true)
        }
        for _ in 0..<1700 {
            var x=(rng.next()-0.5)*120;if abs(x)<7 { x += x<0 ? -8:8 };let z=(rng.next()-0.5)*120
            let s=0.25+rng.next()*0.6,tone=0.62+rng.next()*0.55,scale=SIMD3<Float>(0.6+rng.next(),s*0.6,1)
            box(SIMD3(x,0,z),scale,SIMD3(0.26,0.33,0.15)*tone,material:SIMD4(1,0,0,8),yaw:rng.next() * .pi*2,shadow:false,mesh:.grass,grounded:true)
        }
        result.signs.append(MapSign(position:SIMD3(0,6.9,-38.624),width:4.8,materialID:23))
        let amber=SIMD3<Float>(0.70,0.51,0.19),blue=SIMD3<Float>(0.28,0.49,0.55),ivory=SIMD3<Float>(0.74,0.78,0.62)
        func stripe(_ a:SIMD2<Float>,_ b:SIMD2<Float>,width:Float,color:SIMD3<Float>) {
            let delta=b-a,center=(a+b)*0.5
            box(SIMD3(center.x,0.0162,center.y),SIMD3(width,0.001,simd_length(delta)),color,
                material:SIMD4(0.96,0,0,0),yaw:atan2(delta.x,delta.y),shadow:false,detail:true,grounded:true)
        }
        for (position,direction,word,color):(SIMD2<Float>,SIMD2<Float>,Float,SIMD3<Float>) in [
            (SIMD2(-2.7,25.3),SIMD2(-1,0),21,amber),(SIMD2(2.7,12.1),SIMD2(1,0),22,blue),(SIMD2(0,-28),SIMD2(0,-1),23,ivory)
        ] {
            box(SIMD3(position.x,0.0162,position.y),SIMD3(2.5,0.001,0.7),SIMD3(repeating:1),material:SIMD4(0.97,0,0,word),shadow:false,detail:true,grounded:true)
            let base=position+SIMD2<Float>(0,-1.6),tip=base+direction*0.65,side=SIMD2(-direction.y,direction.x)
            stripe(base-direction*0.55,tip,width:0.14,color:color)
            stripe(tip,tip-direction*0.44+side*0.34,width:0.14,color:color)
            stripe(tip,tip-direction*0.44-side*0.34,width:0.14,color:color)
        }
        for (side,start,color):(Float,Float,SIMD3<Float>) in [(-1,19.8,amber),(1,6.9,blue)] {
            for index in 0..<3 { let z=start+Float(index)*2;stripe(SIMD2(side*3.9,z),SIMD2(side*5.75,z),width:0.075,color:color) }
            stripe(SIMD2(side*5.75,start),SIMD2(side*5.75,start+4),width:0.075,color:color)
        }
        for x:Float in [-2.8,2.8] { for z:Float in [-32.8,-37.2] {
            stripe(SIMD2(x,z),SIMD2(x-(x<0 ? -0.8:0.8),z),width:0.13,color:ivory)
            stripe(SIMD2(x,z),SIMD2(x,z+(z < -35 ? 0.8:-0.8)),width:0.13,color:ivory)
        } }
        func sign(_ owner:Int,_ offset:SIMD3<Float>,width:Float,word:Float,yaw:Float=0) {
            result.signs.append(MapSign(position:offset,width:width,materialID:word,yaw:yaw,ownerID:owner))
        }
        // Relative placements are owned by their destructible obstacle, never
        // independent scenery that survives destruction of its support.
        sign(2,SIMD3(0,1.72,5.6),width:2.5,word:21)
        sign(2,SIMD3(1.883,1.72,0),width:2.8,word:21,yaw:.pi/2)
        sign(4,SIMD3(-2.2,1.72,1.885),width:3,word:21)
        sign(3,SIMD3(2.4,1.72,1.883),width:3.1,word:22)
        sign(3,SIMD3(5.583,1.72,0),width:2.7,word:22,yaw:.pi/2)
        let maintenance=BlacksiteMapData.obstacles.first { $0.id==11 }!.size
        sign(11,SIMD3(0,maintenance.y*0.58,maintenance.z*0.5+0.085),width:2.25,word:22)
        for x:Float in [-maintenance.x*0.38,maintenance.x*0.38] {
            box(SIMD3(x,maintenance.y*0.5,maintenance.z*0.5+0.052),SIMD3(0.14,maintenance.y*0.9,0.004),SIMD3(0.18,0.35,0.42),material:SIMD4(0.94,0,0,0),shadow:false,owner:11,detail:true)
        }
        box(SIMD3(3.25,2.35,6.512),SIMD3(2.3,0.56,0.003),SIMD3(repeating:1),material:SIMD4(0.98,0,0,21),shadow:false,owner:0,detail:true)
        box(SIMD3(-6.002,6.35,3),SIMD3(0.003,0.56,2),SIMD3(repeating:1),material:SIMD4(0.98,0,0,24),shadow:false,owner:1,detail:true)
        result.terrainAppearance.leafGradient=SIMD4(0,7,32,0.36)
        result.terrainAppearance.regions=[
            MapGroundAppearanceRegion(shape:.ellipse,center:SIMD2(-21,20),radii:SIMD2(12,18),inner:SIMD2(repeating:0.65),outer:SIMD2(repeating:1.15),leafReduction:0.72,tint:SIMD3(1.08,1.02,0.88),tintStrength:0.60),
            MapGroundAppearanceRegion(shape:.ellipse,center:SIMD2(31,5),radii:SIMD2(9,18),inner:SIMD2(repeating:0.58),outer:SIMD2(repeating:1.12),minimumLeaf:0.78,tint:SIMD3(0.73,0.80,0.73),tintStrength:0.70,roughnessReduction:0.10),
            MapGroundAppearanceRegion(shape:.rectangle,center:SIMD2(-32,5),inner:SIMD2(0.65,25),outer:SIMD2(1.9,30),leafReduction:0.85),
            MapGroundAppearanceRegion(shape:.rectangle,center:SIMD2(32.5,-8),inner:SIMD2(0.65,21),outer:SIMD2(1.9,27),leafReduction:0.85)
        ]
        return result
    }()
}

extension MapResourceReferences {
    public static let blacksite: MapResourceReferences = {
        var paths:[Int:String]=[:]
        for (folder,first) in [("forest-earth",0),("floor",3),("forest-rock",6),("forest-bark",11),("forest-ground",14),("asphalt",17),("weapon-metal",25),("weapon-fabric",28)] {
            for (index,file) in ["color","normal","roughness"].enumerated() { paths[first+index]="textures/\(folder)/\(file).jpg" }
        }
        paths[9]="textures/pine/color.jpg";paths[20]="textures/pine/normal.jpg";paths[21]="textures/pine/alpha.jpg";paths[22]="textures/pine/roughness.jpg"
        paths[23]="environment/sunrise.jpg"
        let crops=Dictionary(uniqueKeysWithValues:[9,20,21,22].map { ($0,SIMD4<Float>(0,0,0.25,0.5)) })
        return MapResourceReferences(texturePaths:paths,textureCrops:crops,soldierAsset:"characters/soldier/soldier.glb")
    }()
    public static let testRange: MapResourceReferences = {
        let used:Set<Int>=[0,1,2,3,4,5,6,7,8,14,15,16,25,26,27,28,29,30]
        return MapResourceReferences(texturePaths:MapResourceReferences.blacksite.texturePaths.filter { used.contains($0.key) },soldierAsset:MapResourceReferences.blacksite.soldierAsset)
    }()
}

/// Shared playable cover patches. The visual foliage and perception query read
/// these same terrain-relative ellipses; decorative scenery remains unrelated.
public enum BlacksiteVegetation {
    public static let zones:[EnvironmentZone] = [
        EnvironmentZone(id:"west-loading-brush",center:SIMD2(-31,17),radii:SIMD2(1.7,2.7),height:1.2,density:0.7,kind:.brush),
        EnvironmentZone(id:"west-bypass-grass",center:SIMD2(-32,-21),radii:SIMD2(1.7,2.7),height:0.95,density:0.6,kind:.tallGrass),
        EnvironmentZone(id:"east-service-brush",center:SIMD2(31,2),radii:SIMD2(1.7,2.7),height:1.2,density:0.7,kind:.brush),
        EnvironmentZone(id:"east-bypass-grass",center:SIMD2(33,-18),radii:SIMD2(1.7,2.7),height:0.95,density:0.6,kind:.tallGrass),
        EnvironmentZone(id:"south-slope-grass",center:SIMD2(-11,30),radii:SIMD2(1.7,2.7),height:0.95,density:0.6,kind:.tallGrass)
    ]
}
