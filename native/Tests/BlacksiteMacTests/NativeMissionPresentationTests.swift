import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeMissionPresentationTests {
    private func status(_ phase: MissionPhase, kind: MissionKind = .recoverData,
                        progress: Float = 0, required: Float = 0.8,
                        interruption: MissionInterruption? = nil, available: Bool = false) -> MissionStatus {
        MissionStatus(kind: kind, phase: phase, objectivePosition: SIMD3(0,0,0), objectiveRadius: 2,
                      distance: 7.2, progress: progress, requiredProgress: required,
                      interruption: interruption, interactionAvailable: available)
    }

    @Test func savedMissionRoundTripsAndUnknownValuesFallBackWithoutChangingOtherSettings() throws {
        let suite = "blacksite.mission-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NativeSettings(defaults: defaults).selectedMission == .waves)
        for mission in MissionKind.allCases {
            var settings = NativeSettings(defaults: defaults)
            settings.selectedMission = mission; settings.musicVolume = 0.2; settings.effectsVolume = 0.7
            settings.save(defaults: defaults)
            let restored = NativeSettings(defaults: defaults)
            #expect(restored.selectedMission == mission)
            #expect(abs(restored.musicVolume - 0.2) < 0.001 && abs(restored.effectsVolume - 0.7) < 0.001)
        }
        defaults.set("retired-mode", forKey: "native.mission")
        #expect(NativeSettings(defaults: defaults).selectedMission == .waves)
    }

    @Test func progressAndActionHintsUseTheSnapshotInsteadOfRecomputingEligibility() {
        let loading = NativeMissionPresentation(status(.collectData, progress: 0.4, required: 0.8, available: true))
        #expect(abs(loading.fraction - 0.5) < 0.0001)
        #expect(loading.title == "Daten sichern" && loading.interactionTitle?.contains("E HALTEN") == true)
        // The distance alone must not override authoritative availability.
        let walking = NativeMissionPresentation(status(.collectData, interruption: .outOfRange))
        #expect(walking.interactionTitle == nil && walking.title == "Datenstation erreichen")
        #expect(walking.detail.contains("8 m") && walking.reason.contains("zurück"))
        let customDuration = NativeMissionPresentation(status(.holdRadio, kind: .secureRadio, progress: 6, required: 24))
        #expect(abs(customDuration.fraction - 0.25) < 0.0001)
        #expect(customDuration.progressText.contains("24"))
        #expect(customDuration.interactionTitle == nil)
    }

    @Test func interruptionMessagesExplainResetVersusRetainedControlAndRemainAccessible() {
        let released = NativeMissionPresentation(status(.collectData, interruption: .interactionReleased, available: true))
        #expect(released.reason.contains("Loslassen") && released.reason.contains("zurück"))
        let airborne = NativeMissionPresentation(status(.extract, required: 3, interruption: .notGrounded))
        #expect(airborne.accessibilityText.contains("Bodenkontakt") && airborne.accessibilityText.contains("Nordtor"))
        for reason in [MissionInterruption.outOfRange, .contested, .notGrounded] {
            let hold = NativeMissionPresentation(status(.holdRadio, kind: .secureRadio, progress: 12, required: 45, interruption: reason))
            #expect(hold.reason.contains("PAUSIERT"))
            #expect(hold.accessibilityText.contains("Fortschritt bleibt erhalten"))
            #expect(hold.progressText.contains("12") && hold.fraction > 0)
        }
        let finished = NativeMissionPresentation(status(.completed, kind: .secureRadio))
        #expect(!finished.showsProgress && finished.title == "Funkstation gesichert")
        #expect(!finished.accessibilityText.contains("Evakuierung"))
    }

    @Test func phaseNoticesUseEventPhaseAndCompletionDoesNotDuplicateTheResultScreen() {
        #expect(NativeMissionPresentation.banner(for: .waves) == nil)
        #expect(NativeMissionPresentation.banner(for: .completed) == nil)
        let phases: [MissionPhase] = [.collectData, .extract, .activateRadio, .holdRadio]
        let notices = phases.compactMap { NativeMissionPresentation.banner(for: $0) }
        #expect(notices.count == phases.count && Set(notices.map(\.title)).count == phases.count)
        #expect(NativeMissionPresentation.banner(for: .extract)?.title == "ZUR EVAKUIERUNG")
        #expect(NativeMissionPresentation.banner(for: .holdRadio)?.title == "BEREICH SICHERN")
    }
}
