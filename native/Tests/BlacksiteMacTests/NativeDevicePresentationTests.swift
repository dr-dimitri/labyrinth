import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeDevicePresentationTests {
    private func status(action: DeviceAction = .disableGenerator, available: Bool = true,
                        manual: Bool = false, moving: Bool = false, blocked: Bool = false,
                        destroyed: Bool = false, interruption: DeviceInterruption? = nil) -> DeviceInteractionStatus {
        let gate = action == .openGate || action == .closeGate
        return DeviceInteractionStatus(id: gate ? 24 : 23, kind: gate ? .serviceGate : .generator,
            action: action, enabled: action == .disableGenerator || action == .closeGate,
            powered: !manual, manual: manual, position: .zero, distance: 1.5,
            progress: 0.5, requiredProgress: manual ? 4 : 2, gateProgress: 0.6,
            isMoving: moving, blockedByActor: blocked, destroyed: destroyed,
            interactionAvailable: available, interruption: interruption)
    }

    @Test func generatorNamesBothTradeoffsAndUsesActualBindingAndProgress() {
        let on = NativeDevicePresentation(status(), interactionLabel: "MAUS 5 / NUM ENTER")
        #expect(on.title.contains("MAUS 5 / NUM ENTER HALTEN"))
        #expect(on.detail.contains("STROM AN") && on.detail.contains("Licht und Geräuschdeckung entfallen"))
        #expect(on.fraction == 0.25 && on.showsProgress)
        let off = NativeDevicePresentation(status(action: .enableGenerator))
        #expect(off.title.contains("EINSCHALTEN") && off.detail.contains("STROM AUS"))
        #expect(off.accessibilityText.contains("Maschinenlärm"))
    }

    @Test func gateMotionAndActorWaitNeverAdvertiseAnotherHoldAction() {
        let blocked = NativeDevicePresentation(status(action: .openGate, available: false, blocked: true))
        #expect(blocked.title.contains("WARTET") && !blocked.title.contains(" HALTEN"))
        #expect(blocked.detail.contains("freigeben") && blocked.fraction == 0.6)
        let moving = NativeDevicePresentation(status(action: .closeGate, available: false, moving: true))
        #expect(moving.title.contains("BEWEGUNG") && !moving.title.contains(" HALTEN"))
        #expect(moving.detail.contains("60 %") && moving.fraction == 0.6)
        let manual = NativeDevicePresentation(status(action: .openGate, manual: true))
        #expect(manual.detail.contains("HANDBETRIEB") && manual.detail.contains("4.0"))
        #expect(manual.fraction == 0.125)
    }

    @Test func destroyedAndUnavailableContextsExplainRecoveryInsteadOfPromisingAnAction() {
        let destroyed = NativeDevicePresentation(status(available: false, destroyed: true))
        #expect(destroyed.title.contains("ZERSTÖRT") && destroyed.detail.contains("von Hand"))
        #expect(!destroyed.showsProgress && !destroyed.title.contains(" HALTEN"))
        let unbound = NativeDevicePresentation(status(), interactionLabel: NativeControlLabels.unboundLabel)
        #expect(unbound.title == "INTERAGIEREN NICHT BELEGT" && !unbound.detail.contains("E halten"))
        let airborne = NativeDevicePresentation(status(available: false, interruption: .notGrounded))
        #expect(airborne.detail.contains("Am Boden stehen") && !airborne.title.contains(" HALTEN"))
        let heldAfterCompletion = NativeDevicePresentation(status(action: .enableGenerator, available: false, interruption: .releaseRequired))
        #expect(heldAfterCompletion.detail.contains("Taste loslassen") && !heldAfterCompletion.title.contains(" HALTEN"))
    }
}
