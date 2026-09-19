import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeBriefingTests {
    @Test func draftMapChangeFiltersUnsupportedOperationsAndOnlyAppliesOnAction() throws {
        let original = NativeBriefingDraft(map: .blacksite, mission: .operation, difficulty: .hard, camouflage: .mineral)
        let view = NativeBriefingView(draft: original, maps: [.blacksite, .testRange], interactionLabel: "RETURN")
        var applied: NativeBriefingDraft?, started = false, cancels = 0
        view.onApply = { applied = $0; started = $1 }
        view.onCancel = { cancels += 1 }
        view.mapChoice.selectItem(at: 1)
        let action = try #require(view.mapChoice.action)
        _ = view.mapChoice.sendAction(action, to: view.mapChoice.target)
        #expect(view.draft.map.id == MapDefinition.testRange.id)
        #expect(view.draft.mission != .operation)
        #expect(applied == nil)
        view.cancelButton.performClick(nil)
        #expect(cancels == 1 && applied == nil)
        #expect(original.map.id == MapDefinition.blacksite.id && original.mission == .operation)
        view.applyButton.performClick(nil)
        #expect(applied?.map.id == MapDefinition.testRange.id && !started)
        view.startButton.performClick(nil)
        #expect(started)
    }

    @Test func minimumWindowHasCompleteKeyboardChainReadableInventoryAndKnownMap() {
        for mission in MissionKind.allCases {
            for pattern in CamouflagePattern.allCases {
              for role in OperatorClass.allCases {
                let view = NativeBriefingView(draft: NativeBriefingDraft(map: .blacksite, mission: mission,
                    difficulty: .normal, camouflage: pattern, operatorClass: role))
                #expect(view.bounds.width <= 960 && view.bounds.height + 22 <= 618)
                #expect(view.subviews.allSatisfy { view.bounds.contains($0.frame) })
                #expect(view.mapChoice.nextKeyView === view.missionChoice)
                #expect(view.missionChoice.nextKeyView === view.difficultyChoice)
                #expect(view.difficultyChoice.nextKeyView === view.classChoice)
                #expect(view.classChoice.nextKeyView === view.patternChoice)
                #expect(view.patternChoice.nextKeyView === view.cancelButton)
                #expect(view.cancelButton.nextKeyView === view.applyButton)
                #expect(view.applyButton.nextKeyView === view.startButton)
                #expect(view.startButton.nextKeyView === view.mapChoice)
                #expect(view.startButton.keyEquivalent == "\r" && view.cancelButton.keyEquivalent == "\u{1b}")
                #expect(!(view.mapChoice.accessibilityLabel() ?? "").isEmpty)
                let game = CombatSimulation(map: view.draft.map, mission: mission, loadout: view.draft.loadout)
                let labels = view.subviews.compactMap { $0 as? NSTextField }
                let text = labels.map(\.stringValue).joined(separator: " ")
                #expect(text.contains("\(game.grenadeCount) Splittergranaten"))
                #expect(text.contains("\(game.noiseDecoyCount) Köder"))
                #expect(text.contains("+ \(game.loadout.rifleReserve)"))
                #expect(game.loadout.operatorClass == role)
                #expect(!view.mapView.accessibilitySummary.isEmpty)
                for label in labels where label.stringValue.count > 60 {
                    let height = (label.stringValue as NSString).boundingRect(with: NSSize(width: label.bounds.width, height: 1000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!]).height
                    #expect(height <= label.bounds.height, "Briefing text clipped: \(label.stringValue)")
                }
              }
            }
        }
    }
}
