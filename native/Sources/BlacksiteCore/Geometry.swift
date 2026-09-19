import Foundation
import simd

struct RayHit {
    var distance: Float
    var normal: SIMD3<Float> = SIMD3(0, 1, 0)
    var obstacleIndex: Int?
    var hitGround = false
    var enemyIndex: Int?
    var headshot = false
}

func rayBox(origin: SIMD3<Float>, direction: SIMD3<Float>, minimum: SIMD3<Float>, maximum: SIMD3<Float>) -> RayHit? {
    var near: Float = 0, far: Float = .infinity
    var normal = SIMD3<Float>(0, 1, 0)
    for axis in 0..<3 {
        if abs(direction[axis]) < 0.000_001 {
            if origin[axis] < minimum[axis] || origin[axis] > maximum[axis] { return nil }
        } else {
            let first = (minimum[axis] - origin[axis]) / direction[axis]
            let second = (maximum[axis] - origin[axis]) / direction[axis]
            if min(first, second) > near {
                near = min(first, second)
                normal = .zero; normal[axis] = direction[axis] > 0 ? -1 : 1
            }
            far = min(far, max(first, second))
            if near > far || far < 0 { return nil }
        }
    }
    return RayHit(distance: near, normal: normal)
}

func raySphere(origin: SIMD3<Float>, direction: SIMD3<Float>, center: SIMD3<Float>, radius: Float) -> Float {
    let offset = origin - center
    let b = simd_dot(offset, direction), c = simd_dot(offset, offset) - radius * radius
    let discriminant = b * b - c
    guard discriminant >= 0 else { return .infinity }
    let distance = -b - sqrt(discriminant)
    return distance >= 0 ? distance : c <= 0 ? 0 : .infinity
}
