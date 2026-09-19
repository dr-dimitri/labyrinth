import simd
import BlacksiteCore

/// Cached geometry for the two physical extraction choices. These small lamps
/// identify a pickup area, not new cover. Only the housings cast real shadows;
/// the ground markings and lenses use ordinary depth testing without shadows.
enum NativeOperationVisual {
    static let maximumExits = 2
    static let segmentsPerExit = 32
    static let propPartsPerExit = 6

    struct Geometry {
        let props: [SoldierPart]
        let ring: [SoldierPart]
    }

    static func geometry(position: SIMD3<Float>, radius: Float, routeKind: OperationRouteKind,
                         terrain: TerrainProfile, supportSurfaces: [Obstacle]) -> Geometry {
        guard radius.isFinite, radius > 0, position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            return Geometry(props: [], ring: [])
        }
        var ring: [SoldierPart] = [], props: [SoldierPart] = []
        ring.reserveCapacity(segmentsPerExit); props.reserveCapacity(propPartsPerExit)
        func surface(_ point: SIMD3<Float>) -> SIMD3<Float> {
            var height = terrain.height(x: point.x, z: point.z)
            for box in supportSurfaces where !box.destroyed &&
                abs(point.x-box.position.x) <= box.size.x*0.5 && abs(point.z-box.position.z) <= box.size.z*0.5 {
                height = max(height, box.position.y+box.size.y)
            }
            return SIMD3(point.x, height, point.z)
        }
        for index in 0..<segmentsPerExit {
            let angle = Float(index)/Float(segmentsPerExit)*2*Float.pi
            let next = Float(index+1)/Float(segmentsPerExit)*2*Float.pi
            let a = surface(position+SIMD3(sin(angle)*radius,0,cos(angle)*radius))
            let b = surface(position+SIMD3(sin(next)*radius,0,cos(next)*radius))
            let delta = b-a, length = simd_length(delta), along = delta/max(length,0.0001)
            let midpoint = (a+b)*0.5, ground = surface(midpoint)
            let up = terrain.normal(x: midpoint.x,z: midpoint.z)
            let right = simd_normalize(simd_cross(up,along)), normal = simd_normalize(simd_cross(along,right))
            let center = SIMD3(midpoint.x,max(midpoint.y,ground.y)+0.016,midpoint.z)
            let transform = simd_float4x4(columns:(SIMD4(right*0.05,0),SIMD4(normal*0.003,0),
                SIMD4(along*length,0),SIMD4(center,1)))
            ring.append(SoldierPart(mesh:0,transform:transform,color:SIMD3(repeating:1),
                material:SIMD4(1,0,0.3,0),castsShadow:false))
        }
        for side: Float in [-1,1] {
            let point = surface(position+SIMD3(side*radius*0.82,0,-radius*0.48))
            // A flat support surface overrides a sloping terrain normal too.
            let onSupport = supportSurfaces.contains { !$0.destroyed &&
                abs(point.x-$0.position.x) <= $0.size.x*0.5 && abs(point.z-$0.position.z) <= $0.size.z*0.5 &&
                abs(point.y-($0.position.y+$0.size.y)) < 0.0001 }
            let normal = onSupport ? SIMD3<Float>(0,1,0) : terrain.normal(x:point.x,z:point.z)
            let base = translation(point+normal*0.002)*simd_float4x4(simd_quatf(from:SIMD3(0,1,0),to:normal))
            func part(_ offset:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,
                      material:SIMD4<Float>,shadow:Bool=true) {
                props.append(SoldierPart(mesh:0,transform:base*translation(offset)*simd_float4x4(diagonal:SIMD4(size,1)),
                    color:color,material:material,castsShadow:shadow))
            }
            part(SIMD3(0,0.009,0),SIMD3(0.17,0.018,0.23),SIMD3(0.11,0.14,0.12),material:SIMD4(0.85,0.15,0,15))
            part(SIMD3(0,0.094,0),SIMD3(0.11,0.152,0.14),SIMD3(0.16,0.19,0.17),material:SIMD4(0.7,0.3,0,15))
            part(SIMD3(0,0.175,0),SIMD3(0.087,0.010,0.105),color(for:routeKind),material:SIMD4(0.35,0,0.75,0),shadow:false)
        }
        return Geometry(props:props,ring:ring)
    }

    static func color(for route: OperationRouteKind) -> SIMD3<Float> {
        route == .exposed ? SIMD3(0.87,0.57,0.19) : SIMD3(0.22,0.62,0.75)
    }

    static func ringAppearance(exit: ExtractionSnapshot, segment: Int) -> (color: SIMD3<Float>, emission: Float) {
        if exit.blocked { return (SIMD3(0.48,0.18,0.10),0.18) }
        if !exit.unlocked { return (color(for:exit.routeKind)*0.25,0) }
        let complete = exit.active && Float(segment) < exit.fraction*Float(segmentsPerExit)
        let tint = exit.active ? SIMD3<Float>(0.22,0.72,0.42) : color(for:exit.routeKind)
        return (tint*(complete ? 1:0.6), complete ? 0.75:0.32)
    }

    private static func translation(_ point:SIMD3<Float>)->simd_float4x4 {
        var result=matrix_identity_float4x4;result.columns.3=SIMD4(point,1);return result
    }
}
