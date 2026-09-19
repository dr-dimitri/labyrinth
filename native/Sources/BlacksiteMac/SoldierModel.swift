import simd
import BlacksiteCore

struct SoldierPart {
    var mesh:Int
    var transform:simd_float4x4
    var color:SIMD3<Float>
    var material:SIMD4<Float>
    var castsShadow:Bool
}

/// The shared weapon frame remains authoritative for both muzzle flash and AI
/// shots. The character's textured skin and hands are rendered by SoldierAsset.
enum SoldierModel {
    private static let straps=SIMD3<Float>(0.035,0.040,0.032)
    private static let cloth=SIMD4<Float>(0.92,0,0,11)
    private static let polymer=SIMD4<Float>(0.80,0.03,0,10)
    private static let metal=SIMD4<Float>(0.54,0.68,0,9)

    static func weaponParts(enemy:EnemyState,time:Double) -> [SoldierPart] {
        let dead=enemy.health<=0
        if let death=enemy.deathTime,time-death>8 { return [] }
        let pose=EnemyPose(enemy)
        let fallen=dead ? min(1,max(0,Float(time-(enemy.deathTime ?? time))*2.7)):0
        let upright=translation(enemy.position)*rotationY(enemy.yaw)
        let base=upright*translation(SIMD3(0,fallen*0.19,0))*rotationX(fallen * .pi/2)
        let gunLocal=upright.inverse*pose.gunTransform*rotationX(fallen*(enemy.aimPitch - .pi/2))*rotationZ(fallen * .pi/2)
        let gun=base*gunLocal
        var out=rifleDetails.map { part -> SoldierPart in
            var placed=part; placed.transform=gun*part.transform; return placed
        }
        out.append(SoldierPart(mesh:9,
            transform:gun*translation(SIMD3(0.033,0.008,0.119-enemy.recoil*0.027))*scale(SIMD3(0.009,0.023,0.047)),
            color:SIMD3(0.18,0.19,0.18),material:metal,castsShadow:true))
        if !dead && enemy.recoil>0.65 {
            out.append(SoldierPart(mesh:1,
                transform:gun*translation(SIMD3(0,0,0.755))*scale(SIMD3(0.033,0.030,0.065)),
                color:SIMD3(1,0.48,0.07),material:SIMD4(0.5,0,4,0),castsShadow:false))
        }
        return out
    }

    private static let rifleDetails:[SoldierPart] = {
        var p:[SoldierPart]=[]
        // Linear reflectances for dark coated metal and polymer, matching the
        // textured soldier's exposure instead of a pale untextured receiver.
        let gun=SIMD3<Float>(0.028,0.032,0.030),steel=SIMD3<Float>(0.075,0.082,0.077),plastic=SIMD3<Float>(0.045,0.053,0.038)
        p.append(piece(SIMD3(0,-0.006,0.115),SIMD3(0.069,0.087,0.24),gun,mesh:12,material:metal))
        p.append(piece(SIMD3(0,0.008,0.354),SIMD3(0.074,0.077,0.25),gun,mesh:12,material:metal))
        p.append(piece(SIMD3(0,0,-0.067),SIMD3(0.026,0.13,0.026),gun,mesh:2,material:metal,rx:.pi/2))
        p.append(piece(SIMD3(0,-0.012,-0.104),SIMD3(0.065,0.091,0.13),plastic,material:polymer))
        p.append(piece(SIMD3(0,-0.039,-0.164),SIMD3(0.073,0.15,0.028),straps,material:polymer))
        p.append(piece(SIMD3(0,-0.076,0.050),SIMD3(0.042,0.12,0.060),plastic,material:polymer,rx:0.20))
        p.append(piece(SIMD3(0,-0.133,0.178),SIMD3(0.050,0.18,0.085),plastic,mesh:13,material:polymer,ry:.pi))
        p.append(piece(SIMD3(0,-0.221,0.15),SIMD3(0.056,0.014,0.09),straps,material:polymer))
        p.append(piece(SIMD3(0,0.050,0.258),SIMD3(0.038,0.012,0.43),gun,material:metal))
        for i in 0..<13 { p.append(piece(SIMD3(0,0.06,0.066+Float(i)*0.030),SIMD3(0.041,0.009,0.011),steel,material:metal)) }
        for side:Float in [-1,1] { for i in 0..<4 {
            p.append(piece(SIMD3(side*0.036,0.010,0.282+Float(i)*0.048),SIMD3(0.003,0.025,0.032),straps,material:polymer))
        } }
        p.append(piece(SIMD3(0,0,0.585),SIMD3(0.012,0.24,0.012),steel,mesh:2,material:metal,rx:.pi/2))
        p.append(piece(SIMD3(0,0,0.691),SIMD3(0.020,0.058,0.020),gun,mesh:10,material:metal,rx:.pi/2))
        p.append(piece(SIMD3(0,0.089,0.123),SIMD3(0.027,0.048,0.027),gun,mesh:10,material:metal,rx:.pi/2))
        p.append(piece(SIMD3(0,0.059,0.120),SIMD3(0.039,0.033,0.049),gun,material:metal))
        p.append(piece(SIMD3(0,0.047,0.475),SIMD3(0.008,0.045,0.013),steel,material:metal))
        p.append(piece(SIMD3(0.036,0.003,0.116),SIMD3(0.006,0.039,0.091),straps,material:polymer))
        p.append(piece(SIMD3(0.042,-0.021,0.116),SIMD3(0.005,0.029,0.089),gun,material:metal,rz:-0.55))
        p.append(piece(SIMD3(0,-0.055,0.100),SIMD3(0.034,0.008,0.056),gun,material:metal))
        return p
    }()

    private static func piece(_ p:SIMD3<Float>,_ s:SIMD3<Float>,_ c:SIMD3<Float>,mesh:Int=9,material:SIMD4<Float>?=nil,rx:Float=0,ry:Float=0,rz:Float=0)->SoldierPart {
        SoldierPart(mesh:mesh,transform:translation(p)*rotationX(rx)*rotationY(ry)*rotationZ(rz)*scale(s),color:c,material:material ?? cloth,castsShadow:true)
    }
    private static func translation(_ v:SIMD3<Float>)->simd_float4x4 { var m=matrix_identity_float4x4;m.columns.3=SIMD4(v,1);return m }
    private static func scale(_ v:SIMD3<Float>)->simd_float4x4 { simd_float4x4(diagonal:SIMD4(v,1)) }
    private static func rotationX(_ a:Float)->simd_float4x4 { simd_float4x4(simd_quatf(angle:a,axis:SIMD3(1,0,0))) }
    private static func rotationY(_ a:Float)->simd_float4x4 { simd_float4x4(simd_quatf(angle:a,axis:SIMD3(0,1,0))) }
    private static func rotationZ(_ a:Float)->simd_float4x4 { simd_float4x4(simd_quatf(angle:a,axis:SIMD3(0,0,1))) }
}
