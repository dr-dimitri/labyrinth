import simd
import BlacksiteCore

enum NativeOperatorGeometry {
    static let maximumMarkerParts=ReconMark.maximumCount*4
    static let maximumChargeParts=8

    /// The supplied point is a past observation. Camera-facing orientation is
    /// purely presentation; nothing here can query or follow a target actor.
    static func marker(_ mark:ReconMark,eye:SIMD3<Float>,time:Double)->[SoldierPart] {
        guard time<mark.expiresAt else { return [] }
        let delta=eye-mark.position
        guard simd_length_squared(delta)>0.0001 else { return [] }
        let normal=simd_normalize(delta),reference=abs(normal.y)>0.97 ? SIMD3<Float>(0,0,1):SIMD3<Float>(0,1,0)
        let right=simd_normalize(simd_cross(reference,normal)),up=simd_cross(normal,right)
        // Preserve a readable angular size at ordinary combat ranges. The
        // observation itself remains the exact, depth-tested world point;
        // scale is bounded by the recon gadget's 70m observation distance.
        let distance=min(70,simd_length(delta))
        let halfHeight=max(0.18,distance*0.015),halfWidth=halfHeight*(0.14/0.18)
        let thickness=max(0.012,distance*0.002)
        let corners=[up*halfHeight,right*halfWidth,-up*halfHeight,-right*halfWidth]
        let fade=Float(min(1,max(0,(mark.expiresAt-time)/2)))
        return corners.indices.map { index in
            let a=mark.position+corners[index],b=mark.position+corners[(index+1)%4],axis=b-a
            let rotation=simd_float4x4(simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(axis)))
            return SoldierPart(mesh:0,transform:translation((a+b)*0.5)*rotation*scale(SIMD3(thickness,simd_length(axis),thickness)),
                color:SIMD3(0.94,0.24,0.025)*(0.5+fade*0.5),material:SIMD4(0.9,0,1.1*fade,0),castsShadow:false)
        }
    }

    /// Core supplies the centre and real contact normal throughout placement,
    /// detachment and rest. Local +Z is the six-centimetre housing thickness.
    static func charge(_ charge:BreachChargeState)->[SoldierPart] {
        let valid=charge.normal.x.isFinite && charge.normal.y.isFinite && charge.normal.z.isFinite && simd_length_squared(charge.normal)>0.0001
        let normal=valid ? simd_normalize(charge.normal):SIMD3<Float>(0,1,0)
        let base=translation(charge.position)*simd_float4x4(simd_quatf(from:SIMD3<Float>(0,0,1),to:normal))
        func part(_ position:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,mesh:Int=0,emission:Float=0,shadow:Bool=true)->SoldierPart {
            SoldierPart(mesh:mesh,transform:base*translation(position)*scale(size),color:color,
                material:SIMD4(0.76,0.12,emission,emission>0 ? 0:15),castsShadow:shadow)
        }
        var parts=[part(.zero,SIMD3(0.12,0.08,0.06),SIMD3(0.24,0.29,0.20),mesh:9),
                   part(SIMD3(0,0,0.031),SIMD3(0.096,0.057,0.002),SIMD3(0.035,0.048,0.036)),
                   part(SIMD3(0,0.018,0.033),SIMD3(0.055,0.012,0.002),SIMD3(0.66,0.48,0.14),shadow:false)]
        if charge.attached {
            // Initial centre is 5cm off the hit surface. This small attachment
            // pad spans the remaining 2cm; it is not part of the fallen body.
            parts.append(part(SIMD3(0,0,-0.04),SIMD3(0.09,0.06,0.02),SIMD3(0.09,0.11,0.08)))
        }
        let remaining=max(0,min(3,Int(ceil(charge.fuse))))
        for index in 0..<3 {
            let lit=index<remaining && (charge.fuse>0.65 || Int(charge.fuse*8)%2==0)
            parts.append(part(SIMD3(Float(index-1)*0.025,-0.008,0.033),SIMD3(0.013,0.011,0.002),
                lit ? (remaining>1 ? SIMD3(0.78,0.40,0.07):SIMD3(0.81,0.08,0.035)):SIMD3(0.033,0.026,0.019),
                emission:lit ? 1.1:0,shadow:false))
        }
        return parts
    }
    private static func translation(_ p:SIMD3<Float>)->simd_float4x4 { var m=matrix_identity_float4x4;m.columns.3=SIMD4(p,1);return m }
    private static func scale(_ s:SIMD3<Float>)->simd_float4x4 { simd_float4x4(diagonal:SIMD4(s,1)) }
}
