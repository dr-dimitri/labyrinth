import simd
import BlacksiteCore

/// Three float4s match ContactPatch in Metal (48 bytes). Axes include half size.
struct FootContactPatch {
    var centerOpacity: SIMD4<Float>
    var axisU: SIMD4<Float>
    var axisV: SIMD4<Float>
}

enum FootContactMath {
    private struct Support { let height: Float; let normal: SIMD3<Float> }

    private static func support(at point: SIMD3<Float>, terrain: TerrainProfile, obstacles: [Obstacle]) -> Support {
        var height = terrain.height(x: point.x, z: point.z)
        var normal = terrain.normal(x: point.x, z: point.z)
        for box in obstacles where !box.destroyed {
            let low=box.position-SIMD3(box.size.x*0.5,0,box.size.z*0.5)
            let high=box.position+SIMD3(box.size.x*0.5,box.size.y,box.size.z*0.5)
            if point.x >= low.x && point.x <= high.x && point.z >= low.z && point.z <= high.z &&
                high.y <= point.y + 0.045 && high.y > height {
                height=high.y;normal=SIMD3(0,1,0)
            }
        }
        return Support(height:height,normal:normal)
    }

    static func patch(sole: SoldierSolePoints, grounded: Bool, terrain: TerrainProfile, obstacles: [Obstacle]) -> FootContactPatch? {
        guard grounded else { return nil }
        let heel=(sole.heelLeft+sole.heelRight)*0.5, toe=(sole.toeLeft+sole.toeRight)*0.5
        let center=(heel+toe)*0.5
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { return nil }
        let base=support(at:center,terrain:terrain,obstacles:obstacles)
        let n=base.normal
        var gap: Float = 0
        for corner in [sole.heelLeft,sole.heelRight,sole.toeLeft,sole.toeRight] {
            let hit=support(at:corner,terrain:terrain,obstacles:obstacles)
            let planeHeight=base.height-(n.x*(corner.x-center.x)+n.z*(corner.z-center.z))/max(n.y,0.4)
            // Do not project a full sole across a roof edge onto empty space.
            guard abs(hit.height-planeHeight)<0.055 else { return nil }
            gap += corner.y-hit.height
        }
        gap *= 0.25
        guard gap > -0.055, gap < 0.12 else { return nil }
        var forward=toe-heel;forward -= n*simd_dot(forward,n)
        guard simd_length_squared(forward)>0.00001 else { return nil }
        forward=simd_normalize(forward)
        let right=simd_normalize(simd_cross(n,forward))
        let halfLength=min(0.25,max(0.14,simd_distance(heel,toe)*0.5+0.055))
        let halfWidth=min(0.15,max(0.085,max(simd_distance(sole.heelLeft,sole.heelRight),simd_distance(sole.toeLeft,sole.toeRight))*0.5+0.045))
        let t=min(1,max(0,(gap-0.015)/0.105)), fade=1-t*t*(3-2*t)
        let position=SIMD3(center.x,base.height,center.z)+n*0.0025
        // The soft falloff extends beyond the photographed sole. Validate the
        // entire quad, not just the foot samples, against the receiving surface.
        for u: Float in [-1,1] {
            for v: Float in [-1,1] {
                let corner=position+right*(halfWidth*u)+forward*(halfLength*v)
                let hit=support(at:corner,terrain:terrain,obstacles:obstacles)
                guard abs(hit.height-(corner.y-n.y*0.0025))<0.055 else { return nil }
            }
        }
        return FootContactPatch(centerOpacity:SIMD4(position,0.42*fade),axisU:SIMD4(right*halfWidth,0),axisV:SIMD4(forward*halfLength,0))
    }
}
