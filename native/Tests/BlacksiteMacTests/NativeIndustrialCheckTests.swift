import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
struct NativeIndustrialCheckTests {
    @Test func switchViewUsesHeldInputAndActualOpposedGatePositions() throws {
        let closed = try NativeIndustrialCheck.makeScenario(scene: "kessel-gates")
        let opened = try NativeIndustrialCheck.makeScenario(scene: "kessel-switched")
        #expect(closed.simulation.devices.first { $0.id == 2951 }?.gateProgress == 0)
        #expect(opened.simulation.devices.first { $0.id == 2951 }?.gateProgress == 1)
        #expect(opened.simulation.devices.first { $0.id == 2952 }?.gateProgress == 0)
        #expect(opened.simulation.enemies.count >= 9)
        #expect(opened.simulation.map.id == "kessel9" && opened.simulation.state == .active)
        let state = try #require(opened.simulation.deviceInteractionStatus)
        let text = NativeDevicePresentation(state)
        #expect(text.detail.contains("Westschott offen"))
    }

    @Test func destroyedAndOccupiedSwitchTellPlayerAboutTheOpenBypass() {
        let destroyed = NativeDevicePresentation(DeviceInteractionStatus(id: 2950,kind: .maintenanceSwitch,
            action: .switchBulkheads,destroyed: true,interactionAvailable: false))
        #expect(destroyed.title.contains("ZERSTÖRT") && destroyed.detail.contains("Kabelrampe"))
        #expect(!destroyed.showsProgress)
        let blocked = NativeDevicePresentation(DeviceInteractionStatus(id: 2950,kind: .maintenanceSwitch,
            action: .switchBulkheads,isMoving: true,blockedByActor: true,interactionAvailable: false))
        #expect(blocked.title.contains("WARTEN") && blocked.detail.contains("Beide Öffnungen"))
        #expect(!blocked.title.contains("HALTEN"))
    }
}
