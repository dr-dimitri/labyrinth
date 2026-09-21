import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeBriefingTests {
    // NSControl target/action dispatch needs NSApp even without a test window.
    // Do not rely on another suite creating it first on hosted Intel runners.
    init() { _ = NSApplication.shared }

    @Test func briefingPreservesSeedAndShowsTheResolvedWorldBeforeStarting() throws {
        for map in PublishedMapRegistry.maps {
            for seed: UInt64 in 0..<3 {
                let draft = NativeBriefingDraft(map: map, mission: .operation, difficulty: .normal,
                                               camouflage: .mineral, seed: seed)
                let view = NativeBriefingView(draft: draft, maps: [map])
                let expected = try RunVariantCatalog.resolve(map: map, seed: seed)
                var started: NativeBriefingDraft?
                view.onApply = { if $1 { started = $0 } }
                view.patternChoice.selectItem(at: 1); view.updatePreview()
                view.startButton.performClick(nil)
                #expect(started?.seed == seed && started?.resolvedVariant?.id == expected.id)
                let labels = view.subviews.compactMap { $0 as? NSTextField }
                let text = labels.map(\.stringValue).joined(separator: " ")
                for condition in expected.conditions { #expect(text.contains(condition)) }
                for label in labels where label.stringValue.count > 60 {
                    let height = (label.stringValue as NSString).boundingRect(with: NSSize(width: label.bounds.width, height: 1000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!]).height
                    #expect(height <= label.bounds.height, "Variant clipped: \(label.stringValue)")
                }
            }
        }
    }
    @Test func harborBriefingExplainsMandatoryRelayOrderAndShowsKnownWater() throws {
        let map = MapDefinition.sundkai
        let game = CombatSimulation(map: map, mission: .operation)
        let initial = NativeMissionPresentation(game.missionStatus, operation: game.operationStatus, map: map)
        #expect(initial.detail.contains("Reihenfolge frei") && !initial.detail.contains("DATENSTATION"))
        #expect(NativeMissionPresentation.banner(for: game.missionStatus.phase, operation: game.operationStatus, map: map)?.title == "RELAIS VERBINDEN")
        let operation = NativeBriefingMapView(map: map, mission: .operation)
        #expect(operation.accessibilitySummary.contains("R1: Relais Lagerweg"))
        #expect(operation.accessibilitySummary.contains("R2: Relais Ostdamm"))
        #expect(operation.accessibilitySummary.contains("Watbecken"))
        #expect(operation.accessibilitySummary.contains("Serviceausgang Nord"))
        let rules = NativeMissionPresentation.rules(.operation, interactionLabel: "MAUS 3", map: map)
        #expect(rules.contains("MAUS 3 halten") && rules.contains("2 Relais in beliebiger Reihenfolge"))
        let relays = try #require(rules.range(of: "Relais")), data = try #require(rules.range(of: "Daten sichern"))
        #expect(relays.lowerBound < data.lowerBound)
        #expect(!rules.contains("Vorbereitung optional"))
        let dataOnly = NativeBriefingMapView(map: map, mission: .recoverData)
        #expect(!dataOnly.accessibilitySummary.contains("R1:") && !dataOnly.accessibilitySummary.contains("R2:"))
        #expect(NativeBriefingView.terrainHint(map).contains("Landungen"))
    }

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
        for map in [MapDefinition.blacksite, .nebelwacht, .sundkai, .kessel9, .sirocco] {
        for mission in MissionKind.allCases {
            for pattern in CamouflagePattern.allCases {
              for role in OperatorClass.allCases {
                let view = NativeBriefingView(draft: NativeBriefingDraft(map: map, mission: mission,
                    difficulty: .normal, camouflage: pattern, operatorClass: role), maps: [map])
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
}
