import simd

/// Reused, quality-independent meshes. The sea is decorative outside gameplay
/// bounds; its analytic motion never changes collision or visibility volumes.
enum NativeCoastalGeometry {
    static let domeMesh = 16
    static let waterMesh = 17
    static let waterMaterial: Float = 36
    static let domeMaterial: Float = 37
    static let waterMaximumDisplacement: Float = 0.29
    static let waterResolution = 64

    static func domeVertices() -> [GPUVertex] {
        let sectors=48,rings=20
        func vertex(_ sector:Int,_ ring:Int)->GPUVertex {
            let u=Float(sector)/Float(sectors),v=Float(ring)/Float(rings)
            let latitude=v * .pi * 0.5,azimuth=u * .pi * 2
            let position=SIMD3<Float>(cos(latitude)*cos(azimuth),sin(latitude),cos(latitude)*sin(azimuth))
            return GPUVertex(position:position,normal:position,uv:SIMD2(u,v))
        }
        var result:[GPUVertex]=[];result.reserveCapacity(sectors*rings*6)
        for ring in 0..<rings { for sector in 0..<sectors {
            let a=vertex(sector,ring),b=vertex(sector+1,ring),c=vertex(sector,ring+1),d=vertex(sector+1,ring+1)
            result.append(contentsOf:[a,c,b])
            if ring<rings-1 { result.append(contentsOf:[b,c,d]) }
        } }
        // Close the real overhanging underside. Looking up from the pedestal
        // must reveal its dark base, never the sunlit far side of an open shell.
        let centre=GPUVertex(position:.zero,normal:SIMD3(0,-1,0),uv:SIMD2(0.5,0.5))
        for sector in 0..<sectors {
            var a=vertex(sector,0),b=vertex(sector+1,0)
            a.normal=SIMD3(0,-1,0);b.normal=a.normal
            a.uv=SIMD2(a.position.x,a.position.z)*0.5+0.5
            b.uv=SIMD2(b.position.x,b.position.z)*0.5+0.5
            result.append(contentsOf:[centre,a,b])
        }
        return result
    }

    static func waterVertices() -> [GPUVertex] {
        var result:[GPUVertex]=[];result.reserveCapacity(waterResolution*waterResolution*6)
        func vertex(_ x:Int,_ z:Int)->GPUVertex {
            let uv=SIMD2<Float>(Float(x),Float(z))/Float(waterResolution)
            return GPUVertex(position:SIMD3(uv.x-0.5,0,uv.y-0.5),normal:SIMD3(0,1,0),uv:uv)
        }
        for z in 0..<waterResolution { for x in 0..<waterResolution {
            let a=vertex(x,z),b=vertex(x+1,z),c=vertex(x,z+1),d=vertex(x+1,z+1)
            result.append(contentsOf:[a,c,b,b,c,d])
        } }
        return result
    }

    /// Mirrors the broad shader waves for a deterministic extent/normal test.
    static func waterHeight(x:Float,z:Float,time:Float)->Float {
        sin(x*0.42+z*0.19-time*1.35)*0.18
            + sin(x * -0.23+z*0.61-time*1.85)*0.075
            + sin(x*0.83+z * -0.47-time*2.4)*0.025
    }
}
