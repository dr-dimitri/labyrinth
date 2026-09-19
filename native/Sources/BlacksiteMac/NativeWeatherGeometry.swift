import Foundation
import simd
import BlacksiteCore

/// A physical coastal warning beacon. The simulation alone owns the warning
/// interval; there are no forecast particles or premature visibility volumes.
enum NativeWeatherGeometry {
    static let housingPartCount=3
    static let lensPartCount=2
    static func housing(position:SIMD3<Float>)->[SoldierPart] {
        [part(position+SIMD3(0,0.44,0),SIMD3(0.055,1.04,0.055),SIMD3(0.23,0.27,0.27),material:SIMD4(0.82,0.30,0,15)),
         part(position+SIMD3(0,1.0,0),SIMD3(0.18,0.20,0.15),SIMD3(0.35,0.34,0.21),material:SIMD4(0.75,0.25,0,15),mesh:9),
         part(position+SIMD3(0,1.12,0),SIMD3(0.23,0.025,0.21),SIMD3(0.11,0.15,0.16),material:SIMD4(0.70,0.25,0,15))]
    }
    static func lenses(position:SIMD3<Float>,warning:SmokeWarning?,time:Double)->[SoldierPart] {
        let lit=warning.map { time >= $0.beginsAt && time < $0.startsAt } ?? false
        let pulse:Float=lit ? 0.62+0.38*Float(pow(sin((time-(warning?.beginsAt ?? time)) * .pi*2),2)):0
        return [-1,1].map { side in
            part(position+SIMD3(0,1.01,Float(side)*0.080),SIMD3(0.12,0.105,0.012),
                 lit ? SIMD3(0.92,0.32,0.035):SIMD3(0.055,0.040,0.017),
                 material:SIMD4(0.43,0,1.7*pulse,0),shadow:false)
        }
    }
    private static func part(_ position:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,material:SIMD4<Float>,mesh:Int=0,shadow:Bool=true)->SoldierPart {
        var transform=simd_float4x4(diagonal:SIMD4(size,1));transform.columns.3=SIMD4(position,1)
        return SoldierPart(mesh:mesh,transform:transform,color:color,material:material,castsShadow:shadow)
    }
}
