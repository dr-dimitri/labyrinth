import simd

/// A real broad coastal leaf island in the unmodified Island Tree 01 atlas.
/// Curvature and its midrib are geometric; the photographed alpha supplies the
/// irregular outline in every main/shadow pass, never a solid card rectangle.
enum NativeMangroveGeometry {
    static let leafMesh=18
    static let atlasMinimum=SIMD2<Float>(0.161,0.008)
    static let atlasMaximum=SIMD2<Float>(0.340,0.403)
    static func leafVertices()->[GPUVertex] {
        var result:[GPUVertex]=[]
        func vertex(_ x:Float,_ t:Float)->GPUVertex {
            let across=(x-0.5)*0.453
            let bend=sin(t*Float.pi)*0.055+abs(across)*0.12
            let normal=simd_normalize(SIMD3<Float>(x<0.5 ? 0.12:-0.12,-cos(t*Float.pi)*0.055*Float.pi,1))
            let uv=SIMD2(atlasMinimum.x+x*(atlasMaximum.x-atlasMinimum.x),atlasMaximum.y-t*(atlasMaximum.y-atlasMinimum.y))
            return GPUVertex(position:SIMD3(across,t,bend),normal:normal,uv:uv)
        }
        for y in 0..<3 { for x in 0..<2 {
            let a=vertex(Float(x)/2,Float(y)/3),b=vertex(Float(x+1)/2,Float(y)/3)
            let c=vertex(Float(x)/2,Float(y+1)/3),d=vertex(Float(x+1)/2,Float(y+1)/3)
            result.append(contentsOf:[a,b,c,b,d,c])
        } }
        return result
    }
    static func clusterVertices()->[GPUVertex] {
        let leaf=leafVertices()
        return (0..<8).flatMap { index -> [GPUVertex] in
            let tier=Float(index/2),side:Float=index%2==0 ? -1:1
            let rotation=simd_quatf(angle:side*(0.55+tier*0.12),axis:SIMD3(0,0,1))
                * simd_quatf(angle:0.25+Float(index%3)*0.23,axis:SIMD3(0,1,0))
            let base=SIMD3<Float>(0,tier*0.20,0),size:Float=0.55+Float(index%3)*0.10
            return leaf.map { GPUVertex(position:base+rotation.act($0.position*size),normal:rotation.act($0.normal),uv:$0.uv) }
        }
    }
}
