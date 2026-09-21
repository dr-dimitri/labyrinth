import Testing
import simd
@testable import BlacksiteCore

struct LevelObjectEditingTests {
    @Test func duplicateGroupRemapsIDsAndUndoRestoresTheWholeDocument() throws {
        var doc = LevelDocument(); doc.objects = [LevelObject(id: "a",catalogID: "core.crate"),LevelObject(id: "b",catalogID: "core.crate",position: .init(2,0,0))]
        var editor = LevelEditingSession(document: doc); editor.selection = ["a","b"]
        try editor.groupSelection(); let grouped = editor.document
        try editor.edit("Langer Gruppenname") { $0.groups[0].name = String(repeating: "A",count: 120) }
        let beforeCopy = editor.document
        editor.selectObject("a"); #expect(editor.selection == ["a","b"])
        try editor.duplicateSelection()
        let copies = editor.document.objects.filter { editor.selection.contains($0.id) }
        #expect(copies.count == 2 && Set(copies.map(\.id)).isDisjoint(with: ["a","b"]))
        #expect(copies[0].groupID == copies[1].groupID && copies[0].groupID != grouped.objects[0].groupID)
        #expect(try LevelDocument.decode(editor.document.encoded()) == editor.document)
        editor.undo(); #expect(editor.document == beforeCopy)
        editor.redo(); #expect(editor.document.objects.count == 4)
    }
    @Test func groupTransformsRespectLockedObjectsAndGroundAttachments() throws {
        var doc = LevelDocument(); doc.generate(.hills,seed: 4)
        var fixed = LevelObject(id: "fixed",catalogID: "core.crate",position: .init(8,0,0)); fixed.locked = true
        doc.objects = [LevelObject(id: "a",catalogID: "core.crate",position: .init(-2,0,0)),LevelObject(id: "b",catalogID: "core.crate",position: .init(2,0,0)),fixed]
        var editor = LevelEditingSession(document: doc); editor.selection = ["a","b","fixed"]
        try editor.transformSelection(translation: SIMD3(1,0,3),quarterTurns: 1,scale: 2)
        #expect(editor.document.objects[0].position == LevelVector(1,0,7))
        #expect(editor.document.objects[1].position == LevelVector(1,0,-1))
        #expect(editor.document.objects[2] == fixed)
        let map = try editor.document.makeMap(purpose: .preview)
        #expect(map.grounded(map.obstacles[0].position).y == map.terrain.height(x: 1,z: 7))
        try editor.setHidden(true); #expect(!editor.document.objects[2].hidden)
        try editor.deleteSelection(); #expect(editor.document.objects == [fixed])
    }
    @Test func dragUsesOriginalCoordinatesAndIsOneUndoStep() throws {
        var doc = LevelDocument(); doc.objects = [LevelObject(id: "a",catalogID: "core.crate")]
        var editor = LevelEditingSession(document: doc); editor.selection = ["a"]; editor.beginGesture("Ziehen")
        for distance in 1...10 { try editor.transformSelection(translation: SIMD3(Float(distance),0,0),originals: doc.objects) }
        editor.endGesture(); #expect(editor.document.objects[0].position.x == 10)
        editor.undo(); #expect(editor.document == doc && !editor.canUndo)
        #expect(throws: LevelDocumentError.self) { try editor.transformSelection(scale: 10) }
        #expect(editor.document == doc)
    }
    @Test func solidOverlapIsWarnedWhileDecorationMayOverlap() throws {
        var doc = LevelDocument(); doc.objects = [LevelObject(id: "a",catalogID: "core.crate"),LevelObject(id: "b",catalogID: "core.crate")]
        #expect(try doc.placementWarnings().contains { $0.message.contains("überlappen") })
        doc.objects[1].catalogID = "nature.bush"
        #expect(try !doc.placementWarnings().contains { $0.message.contains("überlappen") })
    }
}
