import Foundation
import Testing
import simd
@testable import BlacksiteCore

struct LevelTerrainEditingTests {
    @Test func landscapeResizeAndBrushRoundTripWithoutLosingContent() throws {
        var doc = LevelDocument(bounds: .init(width: 64,depth: 32))
        doc.generate(.hills,seed: 47); var duplicate = doc; duplicate.generate(.hills,seed: 47)
        #expect(doc.terrain == duplicate.terrain)
        doc.objects = [LevelObject(id: "outside",catalogID: "core.crate",position: .init(40,0,0))]
        doc.environment.surfaces = [LevelSurface(x: 35,z: 0,width: 5,depth: 5,material: .asphalt)]
        let original = doc
        var editor = LevelEditingSession(document: doc)
        try editor.edit("Größe") { try $0.resize(width: 24,depth: 48,anchor: .center) }
        #expect(editor.document.objects == original.objects)
        #expect(editor.document.environment.surfaces == original.environment.surfaces)
        #expect(try LevelDocument.decode(editor.document.encoded()) == editor.document)
        _ = try editor.document.makeMap(purpose: .preview)
        editor.undo(); #expect(editor.document == original)
        try doc.brush(.flatten,at: .init(0,0),radius: 4,strength: 1,target: 5)
        #expect(try doc.terrainProfile().height(x: 0,z: 0) == 5)
        #expect(throws: LevelDocumentError.self) { try doc.resize(width: Int.max,depth: 20,anchor: .center) }
    }
    @Test func waterSurvivesDraftEditsAndHasRealMovementRules() throws {
        var doc = LevelDocument()
        try doc.addWater(x: -6,z: -6,width: 6,depth: 6,surfaceHeight: 0)
        let map = try doc.makeMap(purpose: .preview)
        let game = CombatSimulation(map: map)
        let contact = try #require(game.waterContact(at: SIMD3(-3,-0.3,-3),grounded: true))
        #expect(abs(contact.depth-0.3)<0.0001 && contact.movementMultiplier < 1)
        try doc.brush(.lower,at: .init(-3,-3),radius: 2,strength: 1,target: 0)
        #expect(try LevelDocument.decode(doc.encoded()) == doc)
        #expect(try doc.makeMap(purpose: .preview).environment.shallowWaterZones.isEmpty)
        #expect(throws: LevelDocumentError.self) { try doc.addWater(x: Int.max,z: 0,width: 2,depth: 2,surfaceHeight: 0) }
    }
    @Test func groundedObjectsFollowTerrainWhileAbsoluteObjectsAreFlagged() throws {
        var doc = LevelDocument()
        var absolute = LevelObject(id: "absolute",catalogID: "core.crate",position: .init(0,0,0)); absolute.heightMode = .absolute
        doc.objects = [absolute,LevelObject(id: "grounded",catalogID: "core.crate",position: .init(4,0,4))]
        doc.terrain.heights = doc.terrain.heights.map { _ in 5 }
        let warnings = try doc.placementWarnings()
        #expect(warnings.contains { $0.id == "absolute" && $0.message.contains("versenkt") })
        #expect(!warnings.contains { $0.id == "grounded" })
        let map = try doc.makeMap(purpose: .preview)
        #expect(map.grounded(map.obstacles[1].position).y == 5)
    }
    @Test func templatesRespectCurrentEngineBudgets() throws {
        for landscape in LevelLandscape.allCases {
            var doc = LevelDocument(bounds: .init(width: 128,depth: 128)); doc.generate(landscape,seed: UInt64.max)
            let map = try doc.makeMap(purpose: .preview)
            #expect(map.environment.vegetationZones.count <= 8)
            #expect(try LevelDocument.decode(doc.encoded()) == doc)
        }
    }
}
