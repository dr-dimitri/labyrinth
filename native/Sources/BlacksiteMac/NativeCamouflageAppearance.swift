import simd
import BlacksiteCore

/// A visual material choice for the player's existing textile pieces. The
/// immutable loadout supplies the pattern; neither lighting nor graphics quality
/// participates in perception or changes the equipment during a match.
enum NativeCamouflageAppearance {
    static func material(_ original: SIMD4<Float>, pattern: CamouflagePattern) -> SIMD4<Float> {
        guard original.w == 16 else { return original }
        var result = original
        switch pattern {
        case .none: break
        case .vegetation: result.w = 30
        case .mineral: result.w = 31
        }
        return result
    }
}
