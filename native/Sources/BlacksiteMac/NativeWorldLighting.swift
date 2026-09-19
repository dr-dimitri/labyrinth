import simd
import BlacksiteCore

/// Two fixed spot maps in both graphics profiles. This buffer is separate from
/// the existing 336-byte frame block, so all other rendering passes retain it.
struct GPUWorldLight {
    var matrix=matrix_identity_float4x4
    var positionRange=SIMD4<Float>(0,0,0,1)
    var directionOuter=SIMD4<Float>(0,-1,0,0.8)
    var colorPower=SIMD4<Float>(0,0,0,0)
    var parameters=SIMD4<Float>(0.9,0.1,0,0)
}
struct GPUWorldLighting {
    var counts=SIMD4<Float>(0,512,0,0)
    var first=GPUWorldLight()
    var second=GPUWorldLight()
    init(lights:[WorldSpotlightState]) {
        counts.x=Float(min(2,lights.count))
        for (index,light) in lights.prefix(2).enumerated() {
            let near=SpotShadowVolume.nearPlane
            let value=GPUWorldLight(matrix:SpotShadowVolume(light:light).matrix,
                positionRange:SIMD4(light.position,light.range),directionOuter:SIMD4(light.direction,light.outerCos),
                colorPower:SIMD4(light.color,light.enabled ? light.power:0),
                parameters:SIMD4(light.innerCos,near*light.range/(light.range-near),Float(light.id),0))
            if index==0 { first=value } else { second=value }
        }
    }
}

/// Perspective frustum planes, including Metal's asymmetric depth range.
/// Sphere culling retains off-camera casters, moving gates and nearby branches.
struct SpotShadowVolume {
    static let resolution=512
    static let nearPlane:Float=0.15
    let matrix:simd_float4x4
    private let planes:[SIMD4<Float>]
    init(light:WorldSpotlightState) {
        let z = -simd_normalize(light.direction),x=DirectionalShadowVolume.rightVector(for:z),y=simd_cross(z,x)
        let view=simd_float4x4(columns:(SIMD4(x.x,y.x,z.x,0),SIMD4(x.y,y.y,z.y,0),SIMD4(x.z,y.z,z.z,0),
            SIMD4(-simd_dot(x,light.position),-simd_dot(y,light.position),-simd_dot(z,light.position),1)))
        let cotangent=1/tan(acos(light.outerCos)),near=Self.nearPlane,depth=light.range/(near-light.range)
        let projection=simd_float4x4(columns:(SIMD4(cotangent,0,0,0),SIMD4(0,cotangent,0,0),
            SIMD4(0,0,depth,-1),SIMD4(0,0,depth*near,0)))
        matrix=projection*view
        let row=matrix.transpose
        planes=[row.columns.3+row.columns.0,row.columns.3-row.columns.0,
            row.columns.3+row.columns.1,row.columns.3-row.columns.1,row.columns.2,row.columns.3-row.columns.2].map {
                $0/simd_length(SIMD3($0.x,$0.y,$0.z))
            }
    }
    func intersects(center:SIMD3<Float>,radius:Float)->Bool {
        planes.allSatisfy { simd_dot($0,SIMD4(center,1)) >= -max(0,radius) }
    }
}
