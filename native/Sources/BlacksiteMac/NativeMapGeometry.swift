import simd
import BlacksiteCore

/// Pure terrain construction shared by the renderer and CPU migration checks.
/// Fine cells retain the collision heightfield's exact integer-aligned diagonal.
enum NativeMapGeometry {
    static func axis(minimum: Float, maximum: Float, denseMinimum: Float, denseMaximum: Float) -> [Float] {
        let low = floor(minimum), high = ceil(maximum)
        let fineLow = max(low, floor(denseMinimum)), fineHigh = min(high, ceil(denseMaximum))
        var result: [Float] = []
        var value = low
        while value < fineLow { result.append(value); value = min(value + 4, fineLow) }
        value = fineLow
        while value <= fineHigh { result.append(value); value += 1 }
        value = fineHigh + 4
        while value <= high { result.append(value); value += 4 }
        if result.last != high { result.append(high) }
        return result
    }

    static func vertices(map: MapDefinition) -> [GPUVertex] {
        let scenery = map.scenery
        let x = axis(minimum: scenery.renderMinimum.x, maximum: scenery.renderMaximum.x,
                     denseMinimum: scenery.denseMinimum.x, denseMaximum: scenery.denseMaximum.x)
        let z = axis(minimum: scenery.renderMinimum.y, maximum: scenery.renderMaximum.y,
                     denseMinimum: scenery.denseMinimum.y, denseMaximum: scenery.denseMaximum.y)
        var vertices: [GPUVertex] = []
        vertices.reserveCapacity(max(0, x.count - 1) * max(0, z.count - 1) * 6)
        func vertex(_ x: Float, _ z: Float) -> GPUVertex {
            GPUVertex(position: SIMD3(x, map.terrain.height(x: x, z: z), z),
                      normal: map.terrain.normal(x: x, z: z), uv: SIMD2(x, z) * 0.01)
        }
        for row in 0..<(z.count - 1) { for column in 0..<(x.count - 1) {
            let a = vertex(x[column], z[row]), b = vertex(x[column + 1], z[row])
            let c = vertex(x[column], z[row + 1]), d = vertex(x[column + 1], z[row + 1])
            vertices.append(contentsOf: [a, c, b, b, c, d])
        } }
        return vertices
    }
}
