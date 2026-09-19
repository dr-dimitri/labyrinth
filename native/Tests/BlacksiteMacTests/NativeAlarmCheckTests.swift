import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@Suite(.serialized)
@MainActor
struct NativeAlarmCheckTests {
    @Test func pendingAndTransmittedFixturesUseRealAIAndRetainTheirLoadout() throws {
        let loadout = LoadoutDefinition(camouflage: .mineral)
        let pending = try NativeAlarmCheck.makeScenario(scene: "alarm-started", loadout: loadout)
        let sent = try NativeAlarmCheck.makeScenario(scene: "alarm-transmitted", loadout: loadout)
        try pending.simulation.map.validateGameplay()
        #expect(pending.simulation.loadout == loadout && sent.simulation.loadout == loadout)
        #expect(pending.metadata["reportStarted"] as? Int == 1)
        #expect(pending.metadata["reportTransmitted"] as? Int == 0)
        #expect(sent.metadata["reportTransmitted"] as? Int == 1)
        #expect(sent.metadata["alarmReinforcementsCommitted"] as? Int == 2)
        #expect(sent.metadata["receiverSeesPlayer"] as? Bool == false)
        #expect(sent.metadata["receiverRecognition"] as? Float == 0)
        #expect(JSONSerialization.isValidJSONObject(pending.metadata))
        #expect(JSONSerialization.isValidJSONObject(sent.metadata))
    }

    @Test func killingTheActualReporterInterruptsItsAttemptWithoutSendingTheReport() throws {
        let result = try NativeAlarmCheck.makeScenario(scene: "alarm-interrupted")
        #expect(result.metadata["reportInterrupted"] as? Int == 1)
        #expect(result.metadata["reportTransmitted"] as? Int == 0)
        #expect(result.metadata["alarmEscalated"] as? Bool == false)
        #expect(result.events.filter { $0.kind == .shot }.count == 1)
        #expect(result.events.contains { $0.kind == .kill && $0.headshot })
        #expect(JSONSerialization.isValidJSONObject(result.metadata))
    }
}
