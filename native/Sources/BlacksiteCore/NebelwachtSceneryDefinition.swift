import simd

/// Authored coastal presentation. Collision, objectives and weather timing are
/// supplied by NebelwachtDefinition; this factory only describes visible parts.
public enum NebelwachtScenery {
    public static func make(obstacles:[Obstacle])->MapSceneryDefinition {
        var result=MapSceneryDefinition()
        result.renderMinimum=SIMD2(-128,-128);result.renderMaximum=SIMD2(128,128)
        result.denseMinimum=SIMD2(-40,-44);result.denseMaximum=SIMD2(40,44)
        result.menuEye=SIMD3(34,17,37);result.menuTarget=SIMD3(8,8,-16)
        result.extractionGate=SIMD3(0,0,-38)
        result.terrainAppearance.leafGradient=SIMD4(0,0,1,0)
        result.terrainAppearance.materialScales=SIMD4(0.5,1/1.55,0.5,0.5)
        result.terrainAppearance.surfaceWetness=0.74
        let stone=SIMD3<Float>(0.76,0.79,0.79),yellow=SIMD3<Float>(0.68,0.47,0.12)
        let trim=SIMD3<Float>(0.11,0.15,0.16)
        func box(_ position:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,material:SIMD4<Float>,
                 owner:Int?=nil,shadow:Bool=true,mesh:MapVisualMesh = .box,grounded:Bool=false,replacement:Bool=false,yaw:Float=0) {
            result.boxes.append(MapVisualBox(position:position,size:size,color:color,material:material,
                yaw:yaw,castsShadow:shadow,ownerID:owner,mesh:mesh,grounded:grounded,replacesOwnerBody:replacement))
        }
        for obstacle in obstacles {
            let size=obstacle.size,owner=obstacle.id
            if (2701...2704).contains(owner) {
                // A true stone retaining block: no bunker windows or an
                // irregular skin implying walkable holes in its solid AABB.
                box(SIMD3(0,size.y*0.5,0),size,stone,material:SIMD4(0.84,0,0,3),owner:owner,replacement:true)
            } else if [2710,2711,2712].contains(owner) {
                box(SIMD3(0,size.y*0.5,0),size,yellow,material:SIMD4(0.68,0.18,0,15),owner:owner,replacement:true)
                for side:Float in [-1,1] {
                    // Recess-looking opaque windows retain the body's real
                    // closed wall. They never suggest a transparent firing slit.
                    let face=side*(size.z*0.5+0.006),windowY=min(size.y-0.63,1.72)
                    box(SIMD3(0,windowY,face),SIMD3(size.x*0.57,0.64,0.012),SIMD3(0.045,0.078,0.087),material:SIMD4(0.22,0.30,0,9),owner:owner,shadow:false)
                    for x in [-size.x*0.285,0,size.x*0.285] {
                        box(SIMD3(x,windowY,face+side*0.008),SIMD3(0.045,0.69,0.021),trim,material:SIMD4(0.71,0.3,0,15),owner:owner)
                    }
                    for y:Float in [0.14,size.y-0.10] {
                        box(SIMD3(0,y,side*(size.z*0.5+0.004)),SIMD3(size.x,0.11,0.008),trim,material:SIMD4(0.78,0.1,0,15),owner:owner,shadow:false)
                    }
                }
                // Panel seams are shallow metal details attached to the owner.
                for x in stride(from:-size.x*0.5+1.4,to:size.x*0.5,by:2.0) {
                    box(SIMD3(x,size.y*0.5,size.z*0.5+0.002),SIMD3(0.012,size.y,0.004),yellow*0.57,material:SIMD4(0.82,0.1,0,15),owner:owner,shadow:false)
                }
                box(SIMD3(0,size.y-0.002,0),SIMD3(size.x-0.1,0.003,size.z-0.1),SIMD3(0.26,0.30,0.30),material:SIMD4(0.78,0.15,0,15),owner:owner,shadow:false)
            } else if (2713...2716).contains(owner) || owner==2720 || owner==2721 {
                box(SIMD3(0,size.y*0.5,0),size,stone,material:SIMD4(0.90,0,0,2),owner:owner,replacement:true)
                if owner==2721 {
                    box(SIMD3(0,size.y,0),SIMD3(repeating:3.4),SIMD3(0.80,0.83,0.81),material:SIMD4(0.69,0,0,37),owner:owner,mesh:.dome)
                    for side:Float in [-1,1] {
                        box(SIMD3(0,size.y-0.20,side*(size.z*0.5+0.002)),SIMD3(size.x,0.16,0.004),yellow,material:SIMD4(0.75,0.2,0,15),owner:owner,shadow:false)
                    }
                } else if (2713...2716).contains(owner) {
                    box(SIMD3(-size.x*0.5-0.002,size.y-0.065,0),SIMD3(0.004,0.11,size.z-0.12),yellow,material:SIMD4(0.86,0,0,0),owner:owner,shadow:false)
                }
            }
        }
        // The top matches the authored support plate exactly (terrain +16mm).
        box(SIMD3(0,0.008,0),SIMD3(9,0.016,76),SIMD3(0.64,0.67,0.68),material:SIMD4(0.90,0,0,6),shadow:false,grounded:true)
        for z in stride(from:Float(-35),through:35,by:7) {
            box(SIMD3(0,0.017,z),SIMD3(0.12,0.001,2.3),SIMD3(0.64,0.62,0.46),material:SIMD4(0.92,0,0,0),shadow:false,grounded:true)
        }
        // Two nonoverlapping open-sea surfaces begin below the outer cliffs,
        // beyond every playable X/Z point. There is no water physics promise.
        box(SIMD3(151,-1,0),SIMD3(210,1,512),SIMD3(0.055,0.12,0.14),material:SIMD4(0.19,0,0,36),shadow:false,mesh:.water)
        box(SIMD3(-41,-1,-154),SIMD3(174,1,204),SIMD3(0.055,0.12,0.14),material:SIMD4(0.19,0,0,36),shadow:false,mesh:.water)
        // Irregular silhouettes belong outside the arena. Gameplay cover above
        // deliberately keeps its honest rectangular support/collision faces.
        for index in 0..<13 {
            let z=Float(index)*8-45,x:Float=43+Float(index%3)*2.2
            box(SIMD3(x,-1.6,z),SIMD3(2.6+Float(index%3),3.2+Float(index%4)*0.7,4.8),stone*0.83,
                material:SIMD4(0.91,0,0,3),mesh:.rock,grounded:true,yaw:Float(index)*1.31)
        }
        for index in 0..<7 {
            box(SIMD3(Float(index)*13-43,-1.5,-47-Float(index%2)*3),SIMD3(4.5,3.8+Float(index%3),5.2),stone*0.87,
                material:SIMD4(0.9,0,0,3),mesh:.rock,grounded:true,yaw:Float(index)*1.7)
        }
        for index in 0..<6 {
            box(SIMD3(-56-Float(index%2)*9,-3,Float(index)*25-65),SIMD3(9,11+Float(index%3)*3,14),stone*0.79,
                material:SIMD4(0.93,0,0,3),mesh:.rock,grounded:true,yaw:Float(index)*1.11)
        }
        for z in stride(from:Float(-39),to:39,by:6) {
            result.fences.append(MapLineSegment(start:SIMD3(35.8,0,z),end:SIMD3(35.8,0,min(z+6,39))))
        }
        for x in stride(from:Float(-36),through:30,by:6) where abs(x+3)>6 {
            result.fences.append(MapLineSegment(start:SIMD3(x,0,-39.8),end:SIMD3(x+6,0,-39.8)))
        }
        return result
    }
}
