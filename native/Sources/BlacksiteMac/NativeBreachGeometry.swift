import simd
import BlacksiteCore

/// Only the authored pane belongs to its destructible owner. Permanent frame
/// obstacles are separate real bodies and survive through exactly their AABBs.
enum NativeBreachGeometry {
    static let clearGlassMaterial:Float=32
    static let opaqueGlassMaterial:Float=33

    /// Unauthored glass is optically opaque in Core. Only an explicit clear
    /// definition may enable transparency; isolated legacy worlds stay honest.
    static func fallbackParts(obstacle:Obstacle)->[SoldierPart] {
        parts(obstacle:obstacle,definition:MapBreachDefinition(ownerObstacleID:obstacle.id,
            kind:obstacle.kind == .glass ? .glass:.lightPanel,visibility:.opaque))
    }

    static func parts(obstacle:Obstacle,definition:MapBreachDefinition)->[SoldierPart] {
        guard !obstacle.destroyed else { return [] }
        let p=obstacle.position,s=obstacle.size,damaged=obstacle.damageStage == .damaged
        let alongZ=s.z>s.x,width=alongZ ? s.z:s.x,thickness=alongZ ? s.x:s.z
        let orientation=alongZ ? simd_float4x4(simd_quatf(angle:.pi/2,axis:SIMD3<Float>(0,1,0))):matrix_identity_float4x4
        let base=translation(p+SIMD3(0,s.y*0.5,0))*orientation
        func part(_ position:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,_ material:SIMD4<Float>,mesh:Int=0,shadow:Bool=true)->SoldierPart {
            SoldierPart(mesh:mesh,transform:base*translation(position)*scale(size),color:color,material:material,castsShadow:shadow)
        }
        if definition.kind == .glass {
            // One two-sided plane, not the twelve triangles of a transparent
            // box: front/back faces must not darken the same view twice.
            if definition.visibility == .clear {
                return [part(.zero,SIMD3(width,s.y,1),SIMD3(0.48,0.61,0.57),
                    SIMD4(0.15,0,damaged ? 1:0,clearGlassMaterial),mesh:3,shadow:false)]
            }
            return [part(.zero,SIMD3(width,s.y,thickness),SIMD3(0.55,0.60,0.54),
                SIMD4(0.88,0,damaged ? 1:0,opaqueGlassMaterial))]
        }
        var result=[part(.zero,SIMD3(width,s.y,thickness),SIMD3(0.36,0.40,0.32),SIMD4(0.7,0.3,0,damaged ? 17:15))]
        for face:Float in [-1,1] {
            for y:Float in [-0.31,0.31] {
                result.append(part(SIMD3(0,s.y*y,face*(thickness*0.5+0.006)),SIMD3(width*0.94,0.055,0.012),
                    SIMD3(0.17,0.21,0.19),SIMD4(0.8,0.25,0,15)))
            }
            // Small removable-panel marking. It does not resemble an open
            // hole and is removed with the owner, rather than floating after it.
            result.append(part(SIMD3(0,s.y*0.15,face*(thickness*0.5+0.0015)),SIMD3(min(0.62,width*0.38),0.18,0.003),
                SIMD3(0.66,0.49,0.18),SIMD4(0.9,0,0,34),shadow:false))
        }
        return result
    }

    static func frame(obstacle:Obstacle)->[SoldierPart] {
        guard !obstacle.destroyed else { return [] }
        let matrix=translation(obstacle.position+SIMD3(0,obstacle.size.y*0.5,0))*scale(obstacle.size)
        return [SoldierPart(mesh:0,transform:matrix,color:SIMD3(0.20,0.25,0.24),material:SIMD4(0.78,0.45,0,15),castsShadow:true)]
    }
    private static func translation(_ p:SIMD3<Float>)->simd_float4x4 { var m=matrix_identity_float4x4;m.columns.3=SIMD4(p,1);return m }
    private static func scale(_ s:SIMD3<Float>)->simd_float4x4 { simd_float4x4(diagonal:SIMD4(s,1)) }
}

/// Camera-depth intervals share the existing bounded particle buffers with
/// glass; an effect behind a pane is blended before that pane, not over it.
enum NativeTransparencyOrder {
    static func ranges(sortedDepths:[Float],surfaces:[Float])->[Range<Int>] {
        var start=0,result:[Range<Int>]=[]
        for depth in surfaces {
            var end=start
            while end<sortedDepths.count && sortedDepths[end]>depth { end+=1 }
            result.append(start..<end);start=end
        }
        result.append(start..<sortedDepths.count)
        return result
    }
}
