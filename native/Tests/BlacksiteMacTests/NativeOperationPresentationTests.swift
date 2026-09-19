import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
struct NativeOperationPresentationTests {
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
