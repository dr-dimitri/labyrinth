import Testing
import Foundation
import BlacksiteCore
@testable import BlacksiteMac

struct NativeSoundSynthesisTests {
    @Test func everySurfaceHasDistinctFiniteBoundedAndRepeatableFootfalls() {
        var signatures=Set<Int>()
        for surface in SurfaceSound.allCases {
            let samples=NativeSoundSynthesis.step(surface:surface,variant:1)
            #expect(samples == NativeSoundSynthesis.step(surface:surface,variant:1))
            #expect(samples != NativeSoundSynthesis.step(surface:surface,variant:2))
            #expect(samples.count>=6_000 && samples.count<=15_000)
            #expect(samples.allSatisfy { $0.isFinite && abs($0)<=0.8 })
            let energy=samples.reduce(0.0) { $0+Double($1*$1) }
            #expect(energy>0.05)
            #expect(abs(samples.first ?? 1)<0.001 && abs(samples.last ?? 1)<0.001)
            signatures.insert(Int(energy*1_000_000))
        }
        #expect(signatures.count == SurfaceSound.allCases.count)
    }

    @Test func reusableMachineLoopHasNoDiscontinuousSeamAndDecoyIsAudible() {
        let machine=NativeSoundSynthesis.machine(),decoy=NativeSoundSynthesis.decoy()
        #expect(machine.count == 88_200)
        #expect(abs(machine.first! - machine.last!)<0.004)
        #expect(machine.allSatisfy { $0.isFinite && abs($0)<0.3 })
        #expect(decoy.allSatisfy { $0.isFinite && abs($0)<0.4 })
        #expect((decoy.map(abs).max() ?? 0)>0.05)
        #expect(abs(decoy.first!)<0.001 && abs(decoy.last!)<0.001)
    }
}
