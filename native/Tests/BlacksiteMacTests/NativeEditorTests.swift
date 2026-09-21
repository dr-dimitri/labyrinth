import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeEditorTests {
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
