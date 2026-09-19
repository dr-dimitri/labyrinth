import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeClassPresentationTests {
    @Test func savedRoleIsForFutureRunsAndRetryKeepsTheOriginalKit() throws {
        let suite = "BlacksiteClass.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = NativeSettings(defaults: defaults)
        #expect(settings.selectedClass == .assault)
        settings.selectedClass = .engineer; settings.save(defaults: defaults)
        #expect(NativeSettings(defaults: defaults).selectedClass == .engineer)
        let run = ActiveRunConfiguration(map: .blacksite, seed: 1919, mission: .operation,
            difficulty: .normal, loadout: .init(operatorClass: settings.selectedClass, camouflage: .mineral))
        settings.selectedClass = .recon; settings.save(defaults: defaults)
        let retry = try run.makeSimulation()
        #expect(retry.loadout.operatorClass == .engineer && retry.loadout.camouflage == .mineral)
        #expect(retry.breachChargeCount == 1 && retry.smokeGrenadeCount == 0 && retry.noiseDecoyCount == 0)
        #expect(retry.weapons[.rifle]?.reserve == retry.loadout.rifleReserve)
        defaults.set("unknown", forKey: "native.operatorClass")
        #expect(NativeSettings(defaults: defaults).selectedClass == .assault)
    }

    @Test func newGadgetBindingPreservesExistingCustomKeyAndLabelsFollowRemapping() throws {
        let old = Data(#"{"version":1,"bindings":{"interact":{"primary":{"key":{"_0":11}}}}}"#.utf8)
        let migrated = try JSONDecoder().decode(NativeBindings.self, from: old)
        #expect(migrated.inputs(for: .classGadget).isEmpty)
        #expect(migrated.button(for: .interact, slot: .primary) == .key(11))
        var binding = NativeBindings.defaults
        _ = binding.assign(.key(7), to: .classGadget, slot: .primary)
        let recon = CombatSimulation(loadout: .init(operatorClass: .recon))
        let label = NativeControlLabels.label(for: .classGadget, bindings: binding)
        #expect(NativeClassPresentation.stockText(recon, bindings: binding).hasPrefix(label))
        #expect(NativeClassPresentation.description(.recon, gadgetKey: label).hasPrefix(label))
        #expect(binding.button(for: .grenade, slot: .primary) == .key(5))
        #expect(binding.button(for: .smoke, slot: .primary) == .key(9))
        var input = NativeInputState()
        #expect(input.press(.key(11)) == [.classGadget])
        #expect(input.press(.key(11)).isEmpty && input.press(.key(11), isRepeat: true).isEmpty)
        input.clear()
        #expect(input.press(.key(11), isRepeat: true).isEmpty)
    }

    @Test func classChoiceRemainsADraftUntilApplyAndDescribesItsActualInventory() throws {
        let original = NativeBriefingDraft(map: .blacksite, mission: .operation, difficulty: .normal,
            camouflage: .vegetation, operatorClass: .assault)
        let view = NativeBriefingView(draft: original, gadgetLabel: "MAUS 4")
        var applied: NativeBriefingDraft?
        view.onApply = { applied = $0; _ = $1 }
        view.classChoice.selectItem(at: try #require(OperatorClass.allCases.firstIndex(of: .engineer)))
        view.updatePreview()
        #expect(applied == nil && original.operatorClass == .assault)
        #expect(view.draft.operatorClass == .engineer && view.draft.loadout.breachCharges == 1)
        let text = view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        #expect(text.contains("MAUS 4") && text.contains("3 s Zünder") && text.contains("0 Rauchgranaten"))
        view.applyButton.performClick(nil)
        #expect(applied?.loadout == view.draft.loadout)
    }
}
