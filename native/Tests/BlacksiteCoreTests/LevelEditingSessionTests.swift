import Testing
@testable import BlacksiteCore

struct LevelEditingSessionTests {
    @Test func gesturesUndoExactlyAndDoNotMarkSelectionAsDirty() throws {
        var editor = LevelEditingSession(saved: true)
        let original = editor.document
        editor.beginGesture("Pinsel")
        for _ in 0..<20 { try editor.edit("Pinsel") { $0.terrain.heights[0] += 0.2 } }
        editor.endGesture()
        let painted = editor.document
        #expect(editor.canUndo && editor.isDirty)
        editor.undo(); #expect(editor.document == original && !editor.canUndo && !editor.isDirty)
        editor.redo(); #expect(editor.document == painted)
        editor.beginGesture("Abbruch")
        try editor.edit("Abbruch") { $0.name = "Verwerfen" }
        editor.endGesture(cancel: true); #expect(editor.document == painted)
    }
    @Test func failedEditsAndDocumentChangesPreserveConsistentSelection() throws {
        var editor = LevelEditingSession()
        let object = LevelObject(id: "object",catalogID: "core.crate")
        try editor.edit("Platzieren") { $0.objects.append(object) }; editor.selection = [object.id]
        try editor.deleteSelection(); #expect(editor.selection.isEmpty)
        editor.undo(); #expect(editor.selection == [object.id]); #expect(editor.document.objects == [object])
        let before = editor.document
        #expect(throws: LevelDocumentError.self) { try editor.edit("Fehler") { $0.bounds.width = -1 } }
        #expect(editor.document == before)
        try editor.replace(with: LevelDocument(),saved: true)
        #expect(editor.selection.isEmpty && !editor.canUndo && !editor.canRedo && !editor.isDirty)
    }
    @Test func savingThenUndoingAndRedoingUsesContentIdentity() throws {
        var editor = LevelEditingSession()
        try editor.edit("Name") { $0.name = "A" }; editor.markSaved()
        try editor.edit("Name") { $0.name = "B" }; editor.undo(); #expect(!editor.isDirty)
        editor.redo(); #expect(editor.isDirty)
        editor.undo(); try editor.edit("Neu") { $0.name = "C" }; #expect(!editor.canRedo)
    }
}
