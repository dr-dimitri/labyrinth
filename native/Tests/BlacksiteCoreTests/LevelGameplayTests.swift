import Foundation
import Testing
import simd
@testable import BlacksiteCore

struct LevelGameplayTests {
    @Test func impossibleSpawnDistancesAreRejectedWithoutPreventingDraftEditing() throws {
        var doc = LevelDocument(bounds: .init(x: -6, z: -6, width: 12, depth: 12))
        doc.installGameplayTemplate(.waves)
        #expect(try LevelDocument.decode(doc.encoded()) == doc)
        _ = try doc.makeMap(purpose: .preview)
        #expect(doc.playIssues().contains { $0.message.contains("14 m") })
        #expect(throws: MapValidationError.self) { try doc.makeMap() }
    }

    @Test func spawnValidationUsesAllAuthoredPointsAndBothMapDimensions() throws {
        var doc = LevelDocument(bounds: .init(x: -6, z: -6, width: 12, depth: 12))
        doc.installGameplayTemplate(.waves)
        // A corner spawn really can appear while the player is in the opposite
        // corner. Rejecting every 12 m map, or checking only entries, is wrong.
        doc.setMarker(.enemySpawn, at: .init(-4.8, 0, -4.8))
        let map = try doc.makeMap()
        #expect(doc.playIssues().isEmpty)
        var player = PlayerState(position: SIMD3(5.4, 0, 5.4)); player.yaw = -.pi * 0.75
        let game = CombatSimulation(world: map.obstacles, startingPlayer: player, map: map)
        game.spawnWave()
        #expect(game.aliveCount == 1)
        #expect(game.enemies.first?.position == SIMD3<Float>(-4.8, 0, -4.8))
        #expect(game.enemies.allSatisfy { horizontalDistance($0.position, player.position) >= 14 })
        for (width, depth) in [(12, 32), (32, 12)] {
            var rectangular = LevelDocument(bounds: .init(x: 100, z: -80, width: width, depth: depth))
            rectangular.installGameplayTemplate(.waves)
            #expect(rectangular.playIssues().isEmpty)
            _ = try rectangular.makeMap()
        }
    }

    @Test func excessiveDevicesRemainVisibleInSavedDraftsButCannotStart() throws {
        var doc = LevelDocument(); doc.installGameplayTemplate(.waves)
        for i in 0..<3 {
            let generator = LevelObject(id: "generator-\(i)", catalogID: "device.generator", position: .init(Float(i*6-6), 0, 0))
            var gate = LevelObject(id: "gate-\(i)", catalogID: "device.lift-gate", position: .init(Float(i*6-6), 0, 5))
            gate.powerSourceID = generator.id
            // Put linked gates before generators to exercise reference handling.
            doc.objects += [gate, generator]
        }
        let loaded = try LevelDocument.decode(doc.encoded())
        #expect(loaded == doc)
        let preview = try loaded.makeMap(purpose: .preview)
        #expect(preview.obstacles.count == 6 && preview.scenery.boxes.count == 6)
        #expect(loaded.playIssues().contains { $0.message.contains("vier Geräte") })
        #expect(throws: MapValidationError.self) { try loaded.makeMap() }
        doc.objects.removeLast(2)
        #expect(try doc.makeMap().environment.devices.count == 4)
    }

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
