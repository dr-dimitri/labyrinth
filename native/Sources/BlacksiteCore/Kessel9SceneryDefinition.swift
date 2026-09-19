import simd

/// A dry mountain works site. Solid architecture follows its Core owner;
/// the large dam and mountain silhouettes stay outside the playable boundary.
public enum Kessel9Scenery {
    public static func make(obstacles: [Obstacle]) -> MapSceneryDefinition {
        var result = MapSceneryDefinition()
        result.renderMinimum = SIMD2(-110,-110); result.renderMaximum = SIMD2(110,110)
        result.denseMinimum = SIMD2(-40,-44); result.denseMaximum = SIMD2(40,44)
        result.menuEye = SIMD3(29,14,33); result.menuTarget = SIMD3(-4,6,-7)
        result.terrainAppearance.leafGradient = SIMD4(0,0,1,0)
        result.terrainAppearance.materialScales = SIMD4(0.5,1/1.55,0.5,0.5)
        result.terrainAppearance.surfaceWetness = 0
        result.terrainAppearance.regions = [
            MapGroundAppearanceRegion(shape: .rectangle, center: SIMD2(0,0), inner: SIMD2(10,32),
                outer: SIMD2(15,38), tint: SIMD3(0.76,0.72,0.65), tintStrength: 0.45),
            MapGroundAppearanceRegion(shape: .rectangle, center: SIMD2(28,0), inner: SIMD2(2,33),
                outer: SIMD2(4,38), tint: SIMD3(0.89,0.78,0.61), tintStrength: 0.35)
        ]
        let concrete = SIMD3<Float>(0.63,0.60,0.53), rust = SIMD3<Float>(0.39,0.21,0.12)
        let yellow = SIMD3<Float>(0.73,0.51,0.17), metal = SIMD3<Float>(0.14,0.18,0.19)
        func box(_ p: SIMD3<Float>, _ size: SIMD3<Float>, _ color: SIMD3<Float>,
                 material: SIMD4<Float>, owner: Int? = nil, shadow: Bool = true,
                 replacement: Bool = false, grounded: Bool = false, mesh: MapVisualMesh = .box, yaw: Float = 0) {
            result.boxes.append(MapVisualBox(position: p,size: size,color: color,material: material,yaw: yaw,
                castsShadow: shadow,ownerID: owner,mesh: mesh,grounded: grounded,replacesOwnerBody: replacement))
        }
        for owner in obstacles where owner.kind == .bunker {
            let s = owner.size
            box(SIMD3(0,s.y/2,0),s,concrete,material: SIMD4(0.92,0,0,2),owner: owner.id,replacement: true)
            // Staining lies on the physical faces; there are no false doors.
            for side: Float in [-1,1] {
                box(SIMD3(0,0.15,side*(s.z/2+0.003)),SIMD3(s.x,0.22,0.006),concrete*0.67,
                    material: SIMD4(0.96,0,0,2),owner: owner.id,shadow: false)
                if s.x > 3 {
                    for x in stride(from: -s.x/2+1, to: s.x/2, by: 2.4) {
                        box(SIMD3(x,s.y*0.68,side*(s.z/2+0.004)),SIMD3(0.11,s.y*0.55,0.008),rust,
                            material: SIMD4(0.93,0,0,17),owner: owner.id,shadow: false)
                    }
                }
            }
            if s.y < 2.1 {
                box(SIMD3(s.x/2+0.003,s.y-0.15,0),SIMD3(0.006,0.18,max(0.1,s.z-0.1)),yellow,
                    material: SIMD4(0.9,0,0,0),owner: owner.id,shadow: false)
            }
        }
        // Fixed lintels and vertical rails visually frame the two lift gates.
        // Rails are surface details on the permanent neighbouring concrete;
        // the actual passage and headroom remain defined by Core geometry.
        for gate in obstacles where gate.id == 2910 || gate.id == 2911 {
            let p = gate.position
            for side: Float in [-1,1] {
                box(p+SIMD3(side*(gate.size.x/2+0.16),3.5,0),SIMD3(0.10,7,0.13),metal,
                    material: SIMD4(0.7,0.2,0,15),grounded: true)
            }
        }
        // A recognisable concrete dam, beyond the north collision fence.
        box(SIMD3(0,11,-57),SIMD3(99,22,7),concrete*0.82,material: SIMD4(0.95,0,0,2),grounded: true)
        for x in stride(from: Float(-45), through: 45, by: 10) {
            box(SIMD3(x,10,-52.8),SIMD3(1.3,20,1.4),concrete*0.9,material: SIMD4(0.91,0,0,2),grounded: true)
        }
        box(SIMD3(0,22.5,-56),SIMD3(99,1,8),concrete*0.75,material: SIMD4(0.89,0,0,2),grounded: true)
        for side: Float in [-1,1] {
            for index in 0..<7 {
                box(SIMD3(side*(58+Float(index%3)*9),1,Float(index)*21-54),
                    SIMD3(10,13+Float(index%3)*4,14),SIMD3(0.49,0.48,0.43),
                    material: SIMD4(0.95,0,0,3),grounded: true,mesh: .rock,yaw: Float(index)*1.31)
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
