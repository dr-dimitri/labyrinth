import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeLoadoutTests {
    @Test func nativeDraftCancelAndApplyPreserveActiveEquipmentAndPersistOnlyOnCommit() throws {
        let suite = "blacksite.loadout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = NativeSettings(defaults: defaults)
        settings.selectedCamouflage = .mineral; settings.save(defaults: defaults)
        let active = CombatSimulation(world: [], loadout: LoadoutDefinition(camouflage: .mineral))
        let view = NativeLoadoutView(pattern: settings.selectedCamouflage)
        var applies = 0, cancels = 0
        view.onApply = { pattern in
            applies += 1; settings.selectedCamouflage = pattern; settings.save(defaults: defaults)
        }
        view.onCancel = { cancels += 1 }
        view.patternChoice.selectItem(at: try #require(CamouflagePattern.allCases.firstIndex(of: .none)))
        if let action = view.patternChoice.action { _ = view.patternChoice.sendAction(action, to: view.patternChoice.target) }
        #expect(view.previewLoadout.fragmentationGrenades == 4)
        #expect(NativeSettings(defaults: defaults).selectedCamouflage == .mineral && applies == 0)
        view.cancelButton.performClick(nil)
        #expect(cancels == 1 && applies == 0)
        #expect(active.loadout.camouflage == .mineral && active.grenadeCount == 3)

        let reopened = NativeLoadoutView(pattern: NativeSettings(defaults: defaults).selectedCamouflage)
        reopened.onApply = view.onApply
        reopened.patternChoice.selectItem(at: try #require(CamouflagePattern.allCases.firstIndex(of: .vegetation)))
        reopened.applyButton.performClick(nil)
        #expect(applies == 1 && NativeSettings(defaults: defaults).selectedCamouflage == .vegetation)
        #expect(active.loadout.camouflage == .mineral && active.grenadeCount == 3)
        let retry = CombatSimulation(world: [], loadout: active.loadout)
        #expect(retry.loadout == active.loadout && retry.grenadeCount == 3)

        let reset = NativeSettingsView(settings: settings)
        reset.resetControls()
        #expect(reset.editedSettings().selectedCamouflage == .vegetation)
        defaults.set("unavailable-future-pattern", forKey: "native.camouflage")
        #expect(NativeSettings(defaults: defaults).selectedCamouflage == .none)
    }

    @Test func equipmentControlsFitMinimumWindowAndExposeKeyboardAndAccessibilityActions() throws {
        for pattern in CamouflagePattern.allCases {
            let view = NativeLoadoutView(pattern: pattern)
            #expect(view.bounds.width < 960 && view.bounds.height + 22 < 618)
            #expect(view.subviews.allSatisfy { view.bounds.contains($0.frame) })
            #expect(view.patternChoice.nextKeyView === view.cancelButton)
            #expect(view.cancelButton.nextKeyView === view.applyButton)
            #expect(view.applyButton.nextKeyView === view.patternChoice)
            #expect(view.applyButton.keyEquivalent == "\r" && view.cancelButton.keyEquivalent == "\u{1b}")
            #expect(!(view.patternChoice.accessibilityLabel() ?? "").isEmpty)
            let rendered = view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
            let simulation = CombatSimulation(world: [], loadout: view.previewLoadout)
            #expect(rendered.contains("\(simulation.grenadeCount) Splittergranaten"))
            #expect(view.selectedPattern == pattern)
        }
        #expect(try NativeLoadoutCheck.loadout(arguments: ["--camouflage", "mineral"]).camouflage == .mineral)
        #expect(throws: (any Error).self) { try NativeLoadoutCheck.loadout(arguments: ["--camouflage"]) }
    }
}
