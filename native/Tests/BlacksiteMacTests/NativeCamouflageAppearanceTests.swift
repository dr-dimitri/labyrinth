import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeCamouflageAppearanceTests {
    @Test func clothingSelectionPreservesRoughnessMetalAndEmissionForEveryPattern() {
        let sleeve=SIMD4<Float>(0.94,0,0,16),glove=SIMD4<Float>(0.93,0,0,16)
        for original in [sleeve,glove] {
            #expect(NativeCamouflageAppearance.material(original,pattern:.none) == original)
            let vegetation=NativeCamouflageAppearance.material(original,pattern:.vegetation)
            let mineral=NativeCamouflageAppearance.material(original,pattern:.mineral)
            #expect(vegetation.w != mineral.w && vegetation.w != original.w && mineral.w != original.w)
            for styled in [vegetation,mineral] {
                #expect(SIMD3(styled.x,styled.y,styled.z) == SIMD3(original.x,original.y,original.z))
                // These IDs stay outside alpha-cutout plants, animated foliage,
                // reflective glass and the emissive reticle shadow exclusions.
                #expect(styled.w > 29 && styled.z == 0)
            }
        }
    }

    @Test func nonTextileFinishesCannotAcquirePlayerCamouflage() {
        let finishes:[Float]=[0,4,9,10,11,12,13,14,15,17,20,27,28,29]
        for id in finishes {
            let original=SIMD4<Float>(0.6,0.2,0.1,id)
            for pattern:CamouflagePattern in [.none,.vegetation,.mineral] {
                #expect(NativeCamouflageAppearance.material(original,pattern:pattern) == original)
            }
        }
    }
}
