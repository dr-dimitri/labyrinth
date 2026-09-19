import Testing
import Foundation
import BlacksiteCore
@testable import BlacksiteMac

struct NativeSoundSynthesisTests {
    @Test func glassFractureAndPanelTearAreDifferentFiniteCachedSizedSignals() {
        let glass = NativeSoundSynthesis.breakage(kind: .glass)
        let panel = NativeSoundSynthesis.breakage(kind: .lightPanel)
        #expect(glass == NativeSoundSynthesis.breakage(kind: .glass))
        #expect(panel == NativeSoundSynthesis.breakage(kind: .lightPanel))
        #expect(glass != panel)
        for samples in [glass,panel] {
            #expect(samples.count > 15_000 && samples.count < 31_000)
            #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 0.8 })
            #expect((samples.map(abs).max() ?? 0) > 0.08)
            #expect(samples.reduce(0.0) { $0+Double($1*$1) } > 0.1)
            #expect(abs(samples.first ?? 1) < 0.001 && abs(samples.last ?? 1) < 0.001)
        }
    }

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

    @Test func contactCallsAndRadioPhasesAreDistinctBoundedReusableBuffers() {
        let call=NativeSoundSynthesis.contactCall(),begin=NativeSoundSynthesis.radioContact(transmitted:false)
        let sent=NativeSoundSynthesis.radioContact(transmitted:true),interrupted=NativeSoundSynthesis.radioInterruption()
        #expect(call==NativeSoundSynthesis.contactCall())
        #expect(begin==NativeSoundSynthesis.radioContact(transmitted:false))
        #expect(sent==NativeSoundSynthesis.radioContact(transmitted:true))
        #expect(interrupted==NativeSoundSynthesis.radioInterruption())
        #expect(Set([call.count,begin.count,sent.count,interrupted.count]).count==4)
        for sound in [call,begin,sent,interrupted] {
            #expect(sound.count>=8_000 && sound.count<=21_000)
            #expect(sound.allSatisfy { $0.isFinite && abs($0)<0.5 })
            #expect((sound.map(abs).max() ?? 0)>0.04)
            #expect(sound.reduce(0.0) { $0+Double($1*$1) }>0.1)
            #expect(abs(sound.first ?? 1)<0.001 && abs(sound.last ?? 1)<0.001)
        }
    }
}
