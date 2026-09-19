import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeAlarmPresentationTests {
    @Test func generatorExplainsItsRadioConsequenceOnlyWhenActuallyConnected() {
        let status = DeviceInteractionStatus(id: 1, kind: .generator, action: .disableGenerator)
        #expect(!NativeDevicePresentation(status).detail.contains("Funk"))
        #expect(NativeDevicePresentation(status, suppliesRadio: true).detail.contains("Funk"))
    }
    private func game() -> CombatSimulation {
        CombatSimulation(world: [], startingPlayer: PlayerState(position: .zero), startingEnemies: [], startingWave: 3)
    }
    private func escalation(position: SIMD3<Float> = SIMD3(3, 1, 0), channel: ContactReportChannel = .radio,
                            expires: Double = 12) -> GameEvent {
        let report = ContactReport(id: 20, enemyID: 100, contactPosition: SIMD3(15, 0, 0),
            contactTime: 0, transmittedAt: 0, expiresAt: expires, channel: channel)
        let sound = HearingStimulus(id: 30, kind: channel == .radio ? .radio : .shout, position: position,
            time: 0, strength: 1, range: 24, source: .enemy, sourceID: 100)
        return GameEvent(kind: .alarmEscalated, position: position, hearing: sound, contactReport: report, alarmReportID: 20)
    }

    @Test func unheardLocalAndExpiredReportsCannotRevealEscalationOrArrivals() {
        let simulation = game(), presentation = NativeAlarmPresentation()
        #expect(presentation.consume([escalation(position: SIMD3(100, 1, 0)), escalation(channel: .localShout),
                                      escalation(expires: 0)], simulation: simulation) == nil)
        let arrival = GameEvent(kind: .reinforcementsArrived, position: SIMD3(20, 0, 0), alarmReportID: 20)
        #expect(presentation.arrivalNotice([arrival], simulation: simulation) == nil)
        #expect(presentation.accessibilityText.isEmpty)
    }

    @Test func heardAlarmAndSplitArrivalsAnnounceOnceAndResetForTheNextRun() {
        let simulation = game(), presentation = NativeAlarmPresentation()
        #expect(presentation.consume([escalation()], simulation: simulation) != nil)
        #expect(presentation.consume([escalation()], simulation: simulation) == nil)
        let ordinary = GameEvent(kind: .reinforcementsArrived, position: SIMD3(20, 0, 0))
        #expect(presentation.arrivalNotice([ordinary], simulation: simulation) == nil)
        let alarm = GameEvent(kind: .reinforcementsArrived, position: SIMD3(20, 0, 0), alarmReportID: 20)
        #expect(presentation.arrivalNotice([alarm], simulation: simulation)?.contains("RECHTS") == true)
        #expect(presentation.arrivalNotice([alarm], simulation: simulation) == nil)
        for _ in 0..<70 { simulation.step(deltaTime: 0.1, input: GameInput()) }
        _ = presentation.consume([], simulation: simulation)
        #expect(presentation.accessibilityText.isEmpty)
        presentation.clear()
        #expect(presentation.consume([escalation()], simulation: game()) != nil)
    }
}
