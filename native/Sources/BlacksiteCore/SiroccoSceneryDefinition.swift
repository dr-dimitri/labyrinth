import simd

/// Salt-stained research beds and pump buildings surround real glass owners.
/// All large decorative structures stay beyond the playable perimeter.
public enum SiroccoScenery {
    public static func make(obstacles: [Obstacle]) -> MapSceneryDefinition {
        var result = MapSceneryDefinition()
        result.renderMinimum = SIMD2(-100,-100); result.renderMaximum = SIMD2(100,100)
        result.denseMinimum = SIMD2(-40,-44); result.denseMaximum = SIMD2(40,44)
        result.menuEye = SIMD3(29,11,34); result.menuTarget = SIMD3(0,3,-6)
        result.terrainAppearance.leafGradient = SIMD4(0,0,1,0)
        result.terrainAppearance.materialScales = SIMD4(1/1.55,1/1.55,0.5,0.5)
        result.terrainAppearance.surfaceWetness = 0
        result.terrainAppearance.regions = [
            MapGroundAppearanceRegion(shape: .rectangle,center: .zero,inner: SIMD2(100,100),outer: SIMD2(110,110),
                tint: SIMD3(1.25,1.22,1.12),tintStrength: 0.65),
            MapGroundAppearanceRegion(shape: .rectangle,center: SIMD2(0,0),inner: SIMD2(9,14),outer: SIMD2(12,17),
                tint: SIMD3(0.65,0.64,0.55),tintStrength: 0.32)
        ]
        let shell = SIMD3<Float>(0.77,0.74,0.64), trim = SIMD3<Float>(0.22,0.26,0.22)
        func box(_ p: SIMD3<Float>,_ s: SIMD3<Float>,_ color: SIMD3<Float>,material: SIMD4<Float>,
                 owner: Int? = nil,shadow: Bool = true,replacement: Bool = false,grounded: Bool = false,
                 mesh: MapVisualMesh = .box,yaw: Float = 0) {
            result.boxes.append(MapVisualBox(position: p,size: s,color: color,material: material,yaw: yaw,
                castsShadow: shadow,ownerID: owner,mesh: mesh,grounded: grounded,replacesOwnerBody: replacement))
        }
        for owner in obstacles where (3040...3047).contains(owner.id) {
            let s = owner.size
            box(SIMD3(0,s.y/2,0),s,shell,material: SIMD4(0.9,0,0,2),owner: owner.id,replacement: true)
            if owner.id <= 3043 {
                // Beds have a solid substrate; their top is the same support
                // surface used by climbing, footstep material and projectiles.
                box(SIMD3(0,s.y+0.002,0),SIMD3(s.x-0.12,0.004,s.z-0.12),SIMD3(0.20,0.23,0.14),
                    material: SIMD4(0.97,0,0,7),owner: owner.id,shadow: false)
                for side: Float in [-1,1] {
                    box(SIMD3(side*(s.x/2+0.003),s.y*0.35,0),SIMD3(0.006,0.12,s.z),trim,
                        material: SIMD4(0.86,0.12,0,15),owner: owner.id,shadow: false)
                }
            } else if owner.id <= 3045 {
                for side: Float in [-1,1] {
                    box(SIMD3(0,s.y-0.5,side*(s.z/2+0.006)),SIMD3(s.x*0.7,0.55,0.012),trim,
                        material: SIMD4(0.83,0.12,0,27),owner: owner.id,shadow: false)
                    box(SIMD3(0,0.13,side*(s.z/2+0.002)),SIMD3(s.x,0.2,0.004),shell*0.68,
                        material: SIMD4(0.95,0,0,2),owner: owner.id,shadow: false)
                }
            }
        }
        // Bleached low service buildings and solar racks in the distance.
        for index in 0..<5 {
            let x = Float(index)*17-34
            box(SIMD3(x,2,-56),SIMD3(10,4,6),shell*0.86,material: SIMD4(0.91,0,0,2),grounded: true)
            box(SIMD3(x,4.1,-56),SIMD3(10,0.2,6),trim,material: SIMD4(0.75,0.25,0,15),grounded: true)
        }
        for side: Float in [-1,1] {
            for index in 0..<7 {
                box(SIMD3(side*(49+Float(index%2)*5),0,Float(index)*15-40),SIMD3(3,1.8,4.2),shell*0.90,
                    material: SIMD4(0.96,0,0,3),grounded: true,mesh: .rock,yaw: Float(index)*1.9)
            }
            for z in stride(from: Float(-40),to: 40,by: 5) {
                result.fences.append(MapLineSegment(start: SIMD3(side*36,0,z),end: SIMD3(side*36,0,z+5)))
            }
        }
        for z: Float in [-40,40] {
            for x in stride(from: Float(-36),to: 36,by: 4) {
                result.fences.append(MapLineSegment(start: SIMD3(x,0,z),end: SIMD3(x+4,0,z)))
            }
        }
        return result
    }
}
