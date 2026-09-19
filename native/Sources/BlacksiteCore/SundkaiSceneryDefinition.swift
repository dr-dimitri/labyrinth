import simd

/// Authored harbor presentation. Routes and all solid bodies use the audited
/// Core heightfield/AABBs; decorative roots remain outside the playable area.
public enum SundkaiScenery {
    public static func make(obstacles:[Obstacle])->MapSceneryDefinition {
        var result=MapSceneryDefinition()
        result.renderMinimum=SIMD2(-100,-100);result.renderMaximum=SIMD2(100,100)
        result.denseMinimum=SIMD2(-40,-44);result.denseMaximum=SIMD2(40,44)
        result.menuEye=SIMD3(28,9,34);result.menuTarget=SIMD3(-3,1,-5)
        result.terrainAppearance.leafGradient=SIMD4(0,0,1,0)
        result.terrainAppearance.materialScales=SIMD4(1/2.35,0.5,1/2.38,1/2.35)
        result.terrainAppearance.surfaceWetness=0.32
        result.terrainAppearance.regions=[
            MapGroundAppearanceRegion(shape:.rectangle,center:SIMD2(-26,0),inner:SIMD2(1.5,36),outer:SIMD2(3.8,40),tint:SIMD3(1.08,1.02,0.91),tintStrength:0.4),
            MapGroundAppearanceRegion(shape:.rectangle,center:SIMD2(24,0),inner:SIMD2(1.5,30),outer:SIMD2(4.5,35),tint:SIMD3(0.80,0.85,0.72),tintStrength:0.5)]
        let concrete=SIMD3<Float>(0.56,0.58,0.52),dark=SIMD3<Float>(0.095,0.13,0.12)
        func box(_ p:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,material:SIMD4<Float>,
                 owner:Int?=nil,shadow:Bool=true,grounded:Bool=false,replacement:Bool=false,mesh:MapVisualMesh = .box,yaw:Float=0) {
            result.boxes.append(MapVisualBox(position:p,size:size,color:color,material:material,yaw:yaw,
                castsShadow:shadow,ownerID:owner,mesh:mesh,grounded:grounded,replacesOwnerBody:replacement))
        }
        for owner in obstacles {
            let s=owner.size
            if (2801...2803).contains(owner.id) {
                let color:SIMD3<Float>=owner.id==2801 ? SIMD3(0.32,0.43,0.38):owner.id==2802 ? SIMD3(0.34,0.41,0.46):SIMD3(0.49,0.43,0.30)
                box(SIMD3(0,s.y*0.5,0),s,color,material:SIMD4(0.85,0.12,0,15),owner:owner.id,replacement:true)
                // Shallow ribs and a closed roller shutter are attached to the
                // real wall; dark window strips never imply an open passage.
                for x in stride(from:-s.x*0.5+0.5,to:s.x*0.5,by:1.0) {
                    for side:Float in [-1,1] {
                        box(SIMD3(x,s.y*0.5,side*(s.z*0.5+0.016)),SIMD3(0.035,s.y,0.032),color*0.75,
                            material:SIMD4(0.83,0.12,0,15),owner:owner.id)
                    }
                }
                box(SIMD3(-s.x*0.5-0.007,s.y*0.46,0),SIMD3(0.014,s.y*0.78,3.4),dark,
                    material:SIMD4(0.84,0.1,0,27),owner:owner.id,shadow:false)
                for side:Float in [-1,1] {
                    box(SIMD3(0,s.y-0.39,side*(s.z*0.5+0.007)),SIMD3(s.x*0.73,0.30,0.014),SIMD3(0.10,0.17,0.17),
                        material:SIMD4(0.25,0.16,0,9),owner:owner.id,shadow:false)
                }
                box(SIMD3(0,s.y-0.003,0),SIMD3(s.x,0.005,s.z),concrete*0.7,material:SIMD4(0.87,0.05,0,15),owner:owner.id,shadow:false)
                box(SIMD3(-s.x*0.5-0.002,0.14,0),SIMD3(0.004,0.22,s.z),concrete*0.78,material:SIMD4(0.95,0,0,2),owner:owner.id,shadow:false)
            } else if (2811...2813).contains(owner.id) {
                box(SIMD3(0,s.y*0.5,0),s,concrete,material:SIMD4(0.9,0,0,2),owner:owner.id,replacement:true)
                box(SIMD3(s.x*0.5+0.002,s.y-0.17,0),SIMD3(0.004,0.18,s.z-0.08),SIMD3(0.65,0.51,0.19),material:SIMD4(0.88,0,0,0),owner:owner.id,shadow:false)
            } else if owner.id==2830 || owner.id==2831 {
                box(SIMD3(0,s.y*0.5,0),s,SIMD3(0.40,0.44,0.37),material:SIMD4(0.75,0.12,0,15),owner:owner.id,replacement:true)
            }
        }
        // These exact 15-mm tops match the three authored support plates. The
        // dry strips are raised heightfield, never a second navigable level.
        for z:Float in [29,1,-26] {
            box(SIMD3(0,0.0075,z),SIMD3(24,0.015,3),SIMD3(0.36,0.31,0.22),
                material:SIMD4(0.94,0,0,38),shadow:false,grounded:true)
        }
        // Coastal trees are intentionally outside the arena, including their
        // .7*height bounding radius. Their 3D stilt roots have no hidden walls.
        for index in 0..<7 {
            let z=Float(index)*12-37,height:Float=8+Float(index%3)*0.65
            result.trees.append(MapTree(position:SIMD3(-46-Float(index%2)*3,0,z),height:height,seed:UInt64(28000+index),kind:.mangrove))
            result.trees.append(MapTree(position:SIMD3(46+Float(index%2)*4,0,z+2),height:height+0.4,seed:UInt64(28100+index),kind:.mangrove))
        }
        for index in 0..<5 {
            result.trees.append(MapTree(position:SIMD3(Float(index)*16-32,0,-51-Float(index%2)*4),height:8.8,
                seed:UInt64(28200+index),kind:.mangrove))
        }
        // Distant estuary water is still the decorative sea mesh, separate from
        // the two exact shallow gameplay planes and beyond the walking bounds.
        box(SIMD3(77,-0.65,0),SIMD3(70,1,200),SIMD3(0.06,0.13,0.105),material:SIMD4(0.24,0,0,36),shadow:false,mesh:.water)
        box(SIMD3(-77,-0.65,0),SIMD3(70,1,200),SIMD3(0.06,0.13,0.105),material:SIMD4(0.24,0,0,36),shadow:false,mesh:.water)
        // The visible fence sits on the existing collision boundary, not in a
        // dry route. Deep estuary scenery is clearly behind that barrier.
        for side:Float in [-36,36] {
            for z in stride(from:Float(-40),to:40,by:5) {
                result.fences.append(MapLineSegment(start:SIMD3(side,0,z),end:SIMD3(side,0,z+5)))
            }
        }
        func endFence(z:Float,from:Float,to:Float) {
            for x in stride(from:from,to:to,by:4) {
                result.fences.append(MapLineSegment(start:SIMD3(x,0,z),end:SIMD3(min(x+4,to),0,z)))
            }
        }
        // Both extraction rings remain inside; their named exits have visible
        // outward openings rather than a misleading route into the deep water.
        endFence(z:-40,from:-36,to:-4);endFence(z:-40,from:4,to:36)
        endFence(z:40,from:-36,to:27);endFence(z:40,from:35,to:36)
        return result
    }
}
