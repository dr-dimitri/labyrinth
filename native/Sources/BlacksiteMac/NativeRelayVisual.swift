import simd
import BlacksiteCore

enum NativeRelayVisual {
    static let partsPerTerminal=4
    /// The front lies on the owner's actual face towards its authored standing
    /// point. Completion comes only from the immutable mission snapshot.
    static func parts(target:OperationTargetSnapshot,owner:Obstacle)->[SoldierPart] {
        let delta=target.position-owner.position
        let normal:SIMD3<Float>=abs(delta.x)>abs(delta.z) ? SIMD3(delta.x<0 ? -1:1,0,0):SIMD3(0,0,delta.z<0 ? -1:1)
        let face=owner.position+normal*owner.size*0.5+SIMD3(0,min(owner.size.y*0.67,0.86),0)
        let rotation=simd_float4x4(simd_quatf(from:SIMD3<Float>(0,0,1),to:normal))
        var base=rotation;base.columns.3=SIMD4(face,1)
        func part(_ p:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,emission:Float=0,shadow:Bool)->SoldierPart {
            var local=matrix_identity_float4x4;local.columns.3=SIMD4(p,1)
            return SoldierPart(mesh:0,transform:base*local*simd_float4x4(diagonal:SIMD4(size,1)),color:color,
                material:SIMD4(0.76,0.08,emission,0),castsShadow:shadow)
        }
        let color:SIMD3<Float>=target.completed ? SIMD3(0.15,0.63,0.31):target.available ? SIMD3(0.76,0.49,0.13):SIMD3(0.16,0.20,0.19)
        let fraction=target.completed ? 1:min(1,max(0,target.progress/max(0.001,target.requiredProgress)))
        return [part(SIMD3(0,0,0.01),SIMD3(0.29,0.32,0.020),SIMD3(0.075,0.095,0.085),shadow:true),
                part(SIMD3(0,0.035,0.022),SIMD3(0.22,0.18,0.004),color,emission:0.25,shadow:false),
                part(SIMD3(0,-0.090,0.023),SIMD3(0.22,0.028,0.004),SIMD3(0.045,0.06,0.045),shadow:false),
                part(SIMD3(-0.11+0.11*fraction,-0.090,0.026),SIMD3(max(0.002,0.22*fraction),0.023,0.002),color,emission:fraction>0 ? 0.35:0,shadow:false)]
    }
}
