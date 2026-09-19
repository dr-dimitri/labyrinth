import simd
import BlacksiteCore

/// Fragment buffer 4: three float4 header fields and eight 64-byte regions.
/// Keeping this packet separate permits byte-offset checks without a GPU.
enum NativeMapAppearance {
    static let byteCount=560
    static func fields(_ appearance:MapTerrainAppearance)->[SIMD4<Float>] {
        var fields=[SIMD4<Float>](repeating:.zero,count:35)
        fields[0]=appearance.leafGradient
        fields[1]=SIMD4(Float(appearance.regions.count),appearance.surfaceWetness,0,0)
        fields[2]=appearance.materialScales
        for (index,region) in appearance.regions.prefix(8).enumerated() {
            let offset=3+index*4
            fields[offset]=SIMD4(region.center.x,region.center.y,region.radii.x,region.radii.y)
            fields[offset+1]=SIMD4(region.inner.x,region.inner.y,region.outer.x,region.outer.y)
            fields[offset+2]=SIMD4(region.shape == .ellipse ? 0:1,region.leafReduction,region.minimumLeaf,region.roughnessReduction)
            fields[offset+3]=SIMD4(region.tint,region.tintStrength)
        }
        return fields
    }
}
