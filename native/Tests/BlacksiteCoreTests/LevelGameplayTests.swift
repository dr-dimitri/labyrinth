import Foundation
import Testing
import simd
@testable import BlacksiteCore

struct LevelGameplayTests {
    @Test func missingAndBlockedMarkersHaveFocusableDiagnosticsWhileDraftSaves() throws {
        var doc = LevelDocument()
        #expect(doc.playIssues().contains { $0.message.contains("Spielerstart") })
        doc.installGameplayTemplate(.recoverData)
        #expect(doc.playIssues().isEmpty)
        let start = try #require(doc.markers.first { $0.kind == .playerStart })
        doc.objects = [LevelObject(id: "blocking",catalogID: "core.block",position: start.position)]
        #expect(doc.playIssues().contains { $0.itemID == start.id && $0.position == start.position })
        #expect(try LevelDocument.decode(doc.encoded()) == doc)
    }
    @Test func customDataMissionCanFinishWithoutMutatingTheDocument() throws {
        var doc = LevelDocument(); doc.installGameplayTemplate(.recoverData)
        doc.setMarker(.playerStart,at: .init(0,0,1)); doc.setMarker(.dataSite,at: .init(0,0,0)); doc.setMarker(.extraction,at: .init(0,0,2))
        let data = try doc.encoded(), map = try doc.makeMap()
        let game = CombatSimulation(map: map,difficulty: .easy,seed: 17,mission: doc.missionKind)
        var input = GameInput(); input.interact = true
        for _ in 0..<720 {
            game.step(deltaTime: 1.0/120,input: input)
            for i in game.enemies.indices where game.enemies[i].health > 0 { game.damageEnemy(index: i,amount: 10_000) }
        }
        #expect(game.state == .won)
        #expect(try doc.encoded() == data)
        let next = CombatSimulation(map: try doc.makeMap(),seed: 17,mission: doc.missionKind)
        #expect(next.state == .active && next.player.health == 100 && next.elapsed == 0)
    }
    @Test func deviceConnectionsRoundTripCopyAndDeleteWithoutDanglingReferences() throws {
        var doc = LevelDocument(); doc.installGameplayTemplate(.waves)
        let generator = LevelObject(id: "generator",catalogID: "device.generator",position: .init(-8,0,0))
        var gate = LevelObject(id: "gate",catalogID: "device.lift-gate"); gate.powerSourceID = generator.id
        doc.objects = [generator,gate]
        let map = try doc.makeMap(); #expect(map.environment.devices.count == 2)
        #expect(map.environment.devices.first { $0.kind == .serviceGate }?.generatorID == LevelDocument.deviceID(generator.id))
        var editor = LevelEditingSession(document: doc); editor.selection = [generator.id,gate.id]
        try editor.duplicateSelection()
        let copies = editor.document.objects.filter { editor.selection.contains($0.id) }
        #expect(copies.first { $0.catalogID == "device.lift-gate" }?.powerSourceID == copies.first { $0.catalogID == "device.generator" }?.id)
        #expect(try LevelDocument.decode(editor.document.encoded()) == editor.document)
        editor.selection = [gate.id]; try editor.setLocked(true)
        editor.selection = [generator.id]
        #expect(throws: LevelDocumentError.self) { try editor.deleteSelection() }
        editor.selection = [gate.id]; try editor.setLocked(false)
        editor.selection = [generator.id]; try editor.deleteSelection()
        #expect(editor.document.objects.first { $0.id == gate.id }?.powerSourceID == nil)
        doc.objects[1].quarterTurns = 1
        #expect(throws: LevelDocumentError.self) { try doc.encoded() }
    }
}
