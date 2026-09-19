import simd

/// Small reusable meshes shared by both first-person weapons and every casing.
/// These buffers are generated once at startup, never in the frame loop.
enum WeaponGeometry {
    static func meshes() -> [(String, [GPUVertex])] {
        [ ("Bevelled weapon housing", bevelledBox()),
          ("Hollow machined tube", lathe([(1,-0.5),(1,0.5),(0.72,0.5),(0.72,-0.5),(1,-0.5)])),
          ("Open brass cartridge case", lathe([(0,-0.5),(0.88,-0.5),(1.04,-0.47),(1.04,-0.40),(0.84,-0.40),(0.84,-0.34),(0.96,-0.32),(0.88,0.20),(0.65,0.32),(0.65,0.5),(0.48,0.5),(0.48,0.30),(0,0.28)])),
          ("Contoured receiver", receiver()),
          ("Curved magazine", magazine()),
          ("Tapered cloth forearm", lathe([(0,-0.5),(1.1,-0.5),(1.08,-0.38),(0.97,-0.16),(0.86,0.13),(0.68,0.43),(0.67,0.5),(0,0.5)])),
          ("Convex optical lens", lathe([(0,-0.1),(1,-0.1),(1,0),(0.92,0.1),(0.7,0.27),(0.4,0.39),(0,0.45)],segments:48)) ]
            .map { ($0.0, orientedTriangles($0.1)) }
    }
    /// Profiles and side polygons use different construction directions. Give
    /// every cached triangle consistent outward winding and omit pole slivers.
    private static func orientedTriangles(_ vertices:[GPUVertex]) -> [GPUVertex] {
        var out:[GPUVertex]=[]; out.reserveCapacity(vertices.count)
        for i in stride(from:0,to:vertices.count,by:3) {
            let a=vertices[i],b=vertices[i+1],c=vertices[i+2]
            let cross=simd_cross(b.position-a.position,c.position-a.position)
            guard simd_length_squared(cross)>1e-14 else { continue }
            if simd_dot(cross,a.normal+b.normal+c.normal)<0 { out.append(contentsOf:[a,c,b]) }
            else { out.append(contentsOf:[a,b,c]) }
        }
        return out
    }
    private static func bevelledBox() -> [GPUVertex] {
        let faces: [(SIMD3<Float>,SIMD3<Float>,SIMD3<Float>)] = [
            (SIMD3(0,0,1),SIMD3(1,0,0),SIMD3(0,1,0)),(SIMD3(0,0,-1),SIMD3(-1,0,0),SIMD3(0,1,0)),
            (SIMD3(1,0,0),SIMD3(0,0,-1),SIMD3(0,1,0)),(SIMD3(-1,0,0),SIMD3(0,0,1),SIMD3(0,1,0)),
            (SIMD3(0,1,0),SIMD3(1,0,0),SIMD3(0,0,-1)),(SIMD3(0,-1,0),SIMD3(1,0,0),SIMD3(0,0,1))]
        let axis: [Float] = [-0.5,-0.42,0,0.42,0.5]
        let corners = [(0,0),(1,0),(1,1),(0,0),(1,1),(0,1)]
        var out: [GPUVertex] = []
        for (n,t,b) in faces { for y in 0..<4 { for x in 0..<4 { for (dx,dy) in corners {
            let u=axis[x+dx],v=axis[y+dy],p=n*0.5+t*u+b*v
            let inner=simd_clamp(p,SIMD3(repeating:-0.42),SIMD3(repeating:0.42))
            let normal=simd_normalize(p-inner)
            out.append(GPUVertex(position:inner+normal*0.08,normal:normal,uv:SIMD2(u+0.5,v+0.5)))
        } } } }
        return out
    }
    /// Radius/height profile revolves around local +Y, including the mouth,
    /// inner wall, extractor groove and base. Hollow ends are actual geometry.
    private static func lathe(_ profile: [(Float,Float)], segments: Int = 32) -> [GPUVertex] {
        var out: [GPUVertex] = []
        for row in 0..<(profile.count-1) {
            let (r0,y0)=profile[row],(r1,y1)=profile[row+1]
            let dr=r1-r0,dy=y1-y0
            for i in 0..<segments {
                func point(_ radius:Float,_ y:Float,_ theta:Float)->GPUVertex {
                    let n=simd_normalize(SIMD3<Float>(cos(theta)*dy,-dr,sin(theta)*dy))
                    return GPUVertex(position:SIMD3(cos(theta)*radius,y,sin(theta)*radius),normal:n,uv:SIMD2(theta/(2 * .pi),y+0.5))
                }
                let a=Float(i)/Float(segments)*2 * .pi,b=Float(i+1)/Float(segments)*2 * .pi
                let p0=point(r0,y0,a),p1=point(r0,y0,b),p2=point(r1,y1,b),p3=point(r1,y1,a)
                out.append(contentsOf:[p0,p1,p2,p0,p2,p3])
            }
        }
        return out
    }
    private static func receiver() -> [GPUVertex] {
        // Side silhouette includes the stepped upper/lower junction and beveled
        // rear, rather than scaling a single rectangular block into a firearm.
        let polygon:[SIMD2<Float>] = [SIMD2(-0.50,-0.25),SIMD2(-0.49,0.22),SIMD2(-0.35,0.43),SIMD2(0.28,0.43),SIMD2(0.5,0.24),SIMD2(0.5,-0.22),SIMD2(0.23,-0.45),SIMD2(-0.28,-0.45)]
        var out:[GPUVertex]=[]
        for side:Float in [-1,1] {
            for i in polygon.indices {
                let a=polygon[i],b=polygon[(i+1)%polygon.count]
                let innerA=SIMD3<Float>(side*0.5,a.y*0.86,a.x*0.96),innerB=SIMD3<Float>(side*0.5,b.y*0.86,b.x*0.96)
                let outerA=SIMD3<Float>(side*0.39,a.y,a.x),outerB=SIMD3<Float>(side*0.39,b.y,b.x)
                let faceNormal=SIMD3<Float>(side,0,0)
                for p in [SIMD3<Float>(side*0.5,0,0),innerA,innerB] { out.append(GPUVertex(position:p,normal:faceNormal,uv:SIMD2(p.z+0.5,p.y+0.5))) }
                var bevel=simd_normalize(simd_cross(innerB-innerA,outerA-innerA)); if simd_dot(bevel,innerA)<0 { bevel = -bevel }
                for p in [innerA,innerB,outerB,innerA,outerB,outerA] { out.append(GPUVertex(position:p,normal:bevel,uv:SIMD2(p.z+0.5,p.y+0.5))) }
            }
        }
        for i in polygon.indices {
            let a=polygon[i],b=polygon[(i+1)%polygon.count]
            let p0=SIMD3<Float>(-0.39,a.y,a.x),p1=SIMD3<Float>(0.39,a.y,a.x),p2=SIMD3<Float>(0.39,b.y,b.x),p3=SIMD3<Float>(-0.39,b.y,b.x)
            var n=simd_normalize(simd_cross(p1-p0,p2-p0)); if simd_dot(n,p0)<0 { n = -n }
            for p in [p0,p1,p2,p0,p2,p3] { out.append(GPUVertex(position:p,normal:n,uv:SIMD2(p.x+0.5,p.z+0.5))) }
        }
        return out
    }
    private static func magazine() -> [GPUVertex] {
        let ring:[SIMD2<Float>] = [SIMD2(-0.35,-0.5),SIMD2(0.35,-0.5),SIMD2(0.5,-0.35),SIMD2(0.5,0.35),SIMD2(0.35,0.5),SIMD2(-0.35,0.5),SIMD2(-0.5,0.35),SIMD2(-0.5,-0.35)]
        func point(_ i:Int,_ t:Float)->SIMD3<Float> { let r=ring[i%8]; return SIMD3(r.x*(1-t*0.08),0.5-t,r.y+t*t*0.35) }
        var out:[GPUVertex]=[]
        for layer in 0..<6 { for i in 0..<8 {
            let t0=Float(layer)/6,t1=Float(layer+1)/6
            let p0=point(i,t0),p1=point(i+1,t0),p2=point(i+1,t1),p3=point(i,t1)
            let n=simd_normalize(simd_cross(p1-p0,p3-p0))
            for p in [p0,p1,p2,p0,p2,p3] { out.append(GPUVertex(position:p,normal:n,uv:SIMD2(p.z+0.5,p.y+0.5))) }
        } }
        for t:Float in [0,1] { for i in 0..<8 { let n=SIMD3<Float>(0,t==0 ? 1:-1,0); for p in [SIMD3<Float>(0,0.5-t,t*t*0.35),point(i,t),point(i+1,t)] { out.append(GPUVertex(position:p,normal:n,uv:SIMD2(p.x+0.5,p.z+0.5))) } } }
        return out
    }
}
