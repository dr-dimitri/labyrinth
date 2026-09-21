import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeEditorTests {
    @MainActor @Test func editorPersistenceAndDocumentSwitchResetTransientTools() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LevelFileStore(root:root); try store.prepare()
        defer { try? FileManager.default.removeItem(at:root) }
        let url = try store.libraryURL(), doc = LevelDocument()
        try LevelFileStore.save(doc,to:url)
        let editor = NativeEditorWindow(document:doc,fileURL:url,store:store)
        defer { editor.recoveryTimer?.invalidate(); editor.window?.orderOut(nil) }
        try editor.session.edit("Name") { $0.name = "Gesichert" }
        editor.writeRecovery()
        #expect(try store.recoveries().first?.1.document == editor.session.document)
        #expect(editor.save(as:false))
        #expect(!editor.session.isDirty); #expect(try store.recoveries().isEmpty)
        #expect(try LevelFileStore.read(url).name == "Gesichert")
        editor.placement = "core.crate"; editor.markerPlacement = .patrol
        editor.session.beginGesture("Offene Geste")
        #expect(editor.open(url))
        #expect(editor.placement == nil && editor.markerPlacement == nil && !editor.session.canUndo)
    }
    @MainActor @Test func popupMenuActionsSelectAndNotifyEvenForDuplicateTitles() throws {
        _ = NSApplication.shared
        var selected = -1
        let popup = EditorPopup(["Gleich", "Gleich", "Dritter"],label: "Test") { selected = $0 }
        let menu = try #require(popup.menu)
        #expect(popup.numberOfItems == 3)
        menu.performActionForItem(at: 1)
        #expect(selected == 1 && popup.indexOfSelectedItem == 1)
        menu.performActionForItem(at: 2)
        #expect(selected == 2 && popup.indexOfSelectedItem == 2)
    }
}
