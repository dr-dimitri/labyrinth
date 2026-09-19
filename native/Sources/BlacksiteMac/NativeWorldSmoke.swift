import simd
import BlacksiteCore

/// Fragment buffer 6. No frame-matrix change, texture or transparency draw is
/// needed: each visible surface integrates extinction along its real eye ray.
struct GPUWorldSmokeVolume {
    var centerDensity=SIMD4<Float>(0,0,0,0)
    var radiiKind=SIMD4<Float>(1,1,1,0)
    var clipMinimum=SIMD4<Float>(0,0,0,0)
    var clipMaximum=SIMD4<Float>(0,0,0,0)
    var scatterColor=SIMD4<Float>(0,0,0,0)

    init() {}
    init(volume:SmokeVolumeState,light:SIMD2<Float>) {
        centerDensity=SIMD4(volume.position,volume.density)
        radiiKind=SIMD4(volume.radii,volume.kind == .smoke ? 0:volume.kind == .steam ? 1:2)
        clipMinimum=SIMD4(volume.clipMinimum,0);clipMaximum=SIMD4(volume.clipMaximum,0)
        let base:SIMD3<Float> = volume.kind == .smoke ? SIMD3(0.41,0.43,0.40):
            volume.kind == .steam ? SIMD3(0.59,0.62,0.60):SIMD3(0.57,0.64,0.67)
        let illumination:Float=0.70+0.30*light.x+0.20*light.y
        scatterColor=SIMD4(base*illumination,volume.age)
    }
}
struct GPUWorldSmoke {
    var counts=SIMD4<Float>(0,SmokeVolumeState.opaqueOpticalDepth,20,0)
    var first=GPUWorldSmokeVolume()
    var second=GPUWorldSmokeVolume()
    var third=GPUWorldSmokeVolume()
    var fourth=GPUWorldSmokeVolume()

    init(volumes:[SmokeVolumeState],lighting:[SIMD2<Float>]) {
        assert(volumes.count<=SmokeVolumeState.maximumCount)
        counts.x=Float(min(SmokeVolumeState.maximumCount,volumes.count))
        for (index,volume) in volumes.prefix(SmokeVolumeState.maximumCount).enumerated() {
            let light=lighting.indices.contains(index) ? lighting[index]:SIMD2<Float>(1,0)
            let value=GPUWorldSmokeVolume(volume:volume,light:light)
            switch index { case 0:first=value;case 1:second=value;case 2:third=value;default:fourth=value }
        }
    }
}

enum NativeSmokeGeometry {
    static let grenadePartCount=5
    /// Core uses the same 9cm collision sphere as the acoustic throwable. Its
    /// small upright canister fits the sphere and rests on the actual surface.
    static func grenade(position:SIMD3<Float>)->[SoldierPart] {
        let base=translation(position)
        func part(_ offset:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,mesh:Int=0)->SoldierPart {
            SoldierPart(mesh:mesh,transform:base*translation(offset)*simd_float4x4(diagonal:SIMD4(size,1)),
                color:color,material:SIMD4(0.72,0.3,0,15),castsShadow:true)
        }
        return [part(SIMD3(0,0,0),SIMD3(0.043,0.13,0.043),SIMD3(0.28,0.36,0.31),mesh:2),
                part(SIMD3(0,-0.045,0),SIMD3(repeating:0.045),SIMD3(0.28,0.36,0.31),mesh:1),
                part(SIMD3(0,0,0),SIMD3(0.044,0.040,0.044),SIMD3(0.72,0.74,0.65),mesh:2),
                part(SIMD3(0,0.0675,0),SIMD3(0.034,0.020,0.034),SIMD3(0.14,0.17,0.15),mesh:2),
                part(SIMD3(0,0.0825,0),SIMD3(0.035,0.008,0.014),SIMD3(0.29,0.31,0.28))]
    }
    private static func translation(_ p:SIMD3<Float>)->simd_float4x4 {
        var matrix=matrix_identity_float4x4;matrix.columns.3=SIMD4(p,1);return matrix
    }
}
