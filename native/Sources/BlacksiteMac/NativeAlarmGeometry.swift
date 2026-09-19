import simd
import BlacksiteCore

/// Small physical radio attachments use the existing mesh/material batches.
/// Only an actual reporting state lights the chest indicator; no world-space
/// contact position, screen marker or additional light source is constructed.
enum NativeAlarmGeometry {
    static let maximumReporters=64
    static let reporterPartCount=3

    static func reporter(enemy:EnemyState,progress:Float?,radio:Bool,transmitted:Bool)->[SoldierPart] {
        guard enemy.health>0 else { return [] }
        let pose=EnemyPose(enemy)
        let base=translation(enemy.position)*simd_float4x4(simd_quatf(angle:enemy.yaw,axis:SIMD3(0,1,0)))
            * translation(SIMD3(-0.15,pose.bodyHeight+0.16,0.18))
        let active=progress != nil
        let value=max(0,min(1,progress ?? 0))
        let color:SIMD3<Float> = transmitted ? SIMD3(0.22,0.64,0.29):active ? (radio ? SIMD3(0.26,0.55,0.69):SIMD3(0.77,0.39,0.075)):SIMD3(0.035,0.045,0.031)
        let emission:Float=transmitted ? 0.7:active ? 0.5+value*0.65:0
        return [
            part(mesh:9,transform:base,scale:SIMD3(0.075,0.115,0.042),color:SIMD3(0.025,0.032,0.027),material:SIMD4(0.88,0,0,10)),
            part(mesh:2,transform:base*translation(SIMD3(-0.018,0.095,0)),scale:SIMD3(0.005,0.095,0.005),color:SIMD3(0.025,0.03,0.026),material:SIMD4(0.87,0,0,10)),
            part(mesh:1,transform:base*translation(SIMD3(0.019,0.03,0.024)),scale:SIMD3(0.013,0.01,0.005),color:color,material:SIMD4(0.45,0,emission,0),shadow:false)
        ]
    }

    static func module(position:SIMD3<Float>)->[SoldierPart] {
        let base=translation(position)
        return [
            // Axis-aligned housing participates in the existing bullet-mark
            // surface projection because it uses the actual cached box mesh.
            part(mesh:0,transform:base,scale:SIMD3(0.17,0.13,0.045),color:SIMD3(0.06,0.085,0.069),material:SIMD4(0.83,0.1,0,15)),
            part(mesh:0,transform:base*translation(SIMD3(-0.018,0,0.024)),scale:SIMD3(0.10,0.058,0.003),color:SIMD3(0.022,0.035,0.026),material:SIMD4(0.95,0,0,27),shadow:false),
            part(mesh:2,transform:base*translation(SIMD3(-0.055,0.135,0)),scale:SIMD3(0.007,0.18,0.007),color:SIMD3(0.025,0.034,0.028),material:SIMD4(0.9,0,0,10))
        ]
    }
    static func moduleIndicator(position:SIMD3<Float>,powered:Bool)->SoldierPart {
        part(mesh:1,transform:translation(position+SIMD3(0.06,0.035,0.027)),scale:SIMD3(0.013,0.011,0.006),
            color:powered ? SIMD3(0.19,0.51,0.32):SIMD3(0.035,0.05,0.035),material:SIMD4(0.5,0,powered ? 0.55:0,0),shadow:false)
    }
    private static func part(mesh:Int,transform:simd_float4x4,scale:SIMD3<Float>,color:SIMD3<Float>,material:SIMD4<Float>,shadow:Bool=true)->SoldierPart {
        SoldierPart(mesh:mesh,transform:transform*simd_float4x4(diagonal:SIMD4(scale,1)),color:color,material:material,castsShadow:shadow)
    }
    private static func translation(_ v:SIMD3<Float>)->simd_float4x4 {
        var result=matrix_identity_float4x4;result.columns.3=SIMD4(v,1);return result
    }
}
