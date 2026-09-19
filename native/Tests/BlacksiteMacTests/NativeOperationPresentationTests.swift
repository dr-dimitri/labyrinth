import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
struct NativeOperationPresentationTests {
    @Test func relayCompletionAndLockedExitsUseTheAuthoritativeStageSnapshot() {
        let targets = [
            OperationTargetSnapshot(id: "west", title: "Relais West", stageID: "relays", kind: .relayGroup,
                position: .zero, completed: true),
            OperationTargetSnapshot(id: "east", title: "Relais Ost", stageID: "relays", kind: .relayGroup,
                position: SIMD3(20, 0, 0), available: true, progress: 0.25, requiredProgress: 1)
        ]
        let stage = OperationStageSnapshot(id: "relays", title: "Relais verbinden", kind: .relayGroup,
            completed: false, active: true, targets: targets)
        let locked = ExtractionSnapshot(id: "exit", title: "Serviceausgang", detail: "Trockener Rückweg",
            position: SIMD3(0, 0, -20), radius: 2.5, requiredProgress: 3, routeKind: .sheltered)
        let operation = OperationStatus(preparations: [], extractions: [locked], selectedExtractionID: nil,
            stages: [stage], activeStageID: stage.id)
        let status = MissionStatus(kind: .operation, phase: .activateRelays, objectivePosition: targets[1].position,
            objectiveRadius: 1.6, distance: 0.8, progress: 0.25, requiredProgress: 1,
            interruption: nil, interactionAvailable: true, objectiveID: "east", objectiveTitle: "Relais Ost")
        let mission = NativeMissionPresentation(status, interactionLabel: "MAUS 3", operation: operation)
        #expect(mission.title == "Relais Ost" && mission.detail.contains("1/2 aktiv"))
        #expect(mission.detail.contains("Reihenfolge frei") && mission.fraction == 0.25)
        #expect(mission.interactionTitle?.hasPrefix("MAUS 3 HALTEN") == true)
        let panel = NativeOperationPresentation(operation)
        #expect(panel.objectiveLines.count == 2 && panel.objectiveLines[0].contains("erledigt"))
        #expect(panel.extractionLines[0].contains("nach allen Auftragszielen"))
        #expect(!panel.accessibilityText.contains("nach Datenaufnahme"))
        let unbound = NativeMissionPresentation(status, interactionLabel: NativeControlLabels.unboundLabel, operation: operation)
        #expect(unbound.interactionTitle == "INTERAGIEREN NICHT BELEGT" && unbound.reason.contains("Einstellungen"))
    }

    private func exits(active: String? = nil, blocked: String? = nil) -> [ExtractionSnapshot] {
        BlacksiteOperation.definition.extractions.map {
            ExtractionSnapshot(id: $0.id, title: $0.title, detail: $0.detail, position: $0.position,
                radius: $0.radius, requiredProgress: $0.holdDuration, progress: active == $0.id ? 0.75 : 0,
                distance: $0.id == "north" ? 3 : 70, routeKind: $0.routeKind,
                unlocked: true, blocked: blocked == $0.id, active: active == $0.id,
                interruption: blocked == $0.id ? .blocked : active == $0.id ? nil : .outOfRange)
        }
    }

    @Test func selectedExtractionComesFromTheCoreIdentifierRatherThanTheNearestTitle() {
        let operation = OperationStatus(preparations: [], extractions: exits(active: "service"), selectedExtractionID: "service")
        let status = MissionStatus(kind: .operation, phase: .extract, objectivePosition: nil,
            objectiveRadius: 2.5, distance: 70, progress: 0.75, requiredProgress: 3,
            interruption: nil, interactionAvailable: false, extractionID: "service")
        let presentation = NativeMissionPresentation(status, operation: operation)
        #expect(presentation.title.contains("Wartungsausgang") && !presentation.title.contains("Nordtor"))
        #expect(presentation.fraction == 0.25 && presentation.interactionTitle == nil)
        #expect(presentation.detail.contains("Deckung") && presentation.reason.contains("Im Ring bleiben"))
        let notice = NativeMissionPresentation.banner(for: .extract, operation: operation)
        #expect(notice?.detail.contains("Nordtor") == true && notice?.detail.contains("Wartungsausgang") == true)
    }

    @Test func preparationUsesOneRealBindingAndUnboundControlsRemainHonest() {
        let status = MissionStatus(kind: .operation, phase: .prepareOperation, objectivePosition: .zero,
            objectiveRadius: 1.6, distance: 0.5, progress: 0, requiredProgress: 0.8,
            interruption: .interactionReleased, interactionAvailable: true)
        let bound = NativeMissionPresentation(status, interactionLabel: "MAUS 3")
        #expect(bound.interactionTitle?.hasPrefix("MAUS 3 HALTEN") == true)
        #expect(bound.detail.contains("optional") && bound.reason.contains("MAUS 3 halten"))
        let unbound = NativeMissionPresentation(status, interactionLabel: NativeControlLabels.unboundLabel)
        #expect(unbound.interactionTitle == "INTERAGIEREN NICHT BELEGT")
        #expect(unbound.reason.contains("Einstellungen") && !unbound.reason.contains("E halten"))
    }

    @Test func blockedExitAndFailedPreparationNameTheFallbackAndFitTheCompactPanel() {
        let operation = OperationStatus(preparations: [
            OperationPreparationStatus(kind: .disableRadio, deviceID: 1, completed: true, unavailable: false),
            OperationPreparationStatus(kind: .openGate, deviceID: 2, completed: false, unavailable: true)
        ], extractions: exits(blocked: "service"), selectedExtractionID: nil)
        let presentation = NativeOperationPresentation(operation)
        #expect(presentation.preparationLines[0].contains("aus"))
        #expect(presentation.preparationLines[1].contains("Hauptweg"))
        #expect(presentation.extractionLines[1].contains("anderen Ausgang"))
        #expect(presentation.accessibilityText.contains("nicht von allen Seiten"))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        for line in presentation.preparationLines + presentation.extractionLines {
            let size = (line as NSString).boundingRect(with: NSSize(width: 354, height: 100),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 10), .paragraphStyle: paragraph]).size
            #expect(size.height <= 34)
        }
    }
}
