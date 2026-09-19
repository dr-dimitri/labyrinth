import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

/// Real AppKit views only: no window, coordinator, renderer or event synthesis.
@MainActor
@Suite(.serialized)
struct NativeHUDTests {
    private let modes: [(NativeRenderMode, Set<String>)] = [
        (.menu, ["EINSATZ STARTEN", "EINSTELLUNGEN", "STEUERUNG / ARSENAL", "EINSATZBRIEFING", "WELLEN", "DATEN BERGEN", "FUNK SICHERN", "FELDOPERATION"]),
        (.playing, ["Ⅱ  ESC"]),
        (.paused, ["FORTSETZEN", "EINSTELLUNGEN", "EINSATZ ABBRECHEN"]),
        (.result, ["ERNEUT ANTRETEN", "ZURÜCK ZUM HAUPTMENÜ"]),
    ]

    private func fixture(size: NSSize) -> (NSView, GameHUDView) {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 80, height: size.height + 60))
        let hud = GameHUDView(frame: NSRect(origin: NSPoint(x: 37, y: 29), size: size))
        parent.addSubview(hud)
        return (parent, hud)
    }

    @Test func visibleButtonCentresReceiveHitsAcrossMenuStatesAndWindowSizes() {
        for size in [NSSize(width: 960, height: 618), NSSize(width: 960, height: 640), NSSize(width: 1280, height: 800), NSSize(width: 1920, height: 1080)] {
            let (parent, hud) = fixture(size: size)
            #expect(!parent.isFlipped && hud.isFlipped)
            for (mode, titles) in modes {
                hud.layoutButtons(mode: mode, ready: true)
                let buttons = hud.subviews.compactMap { $0 as? NativeButton }.filter { !$0.isHidden }
                #expect(Set(buttons.map(\.title)) == titles)
                for button in buttons {
                    #expect(hud.bounds.contains(button.frame))
                    #expect(button.accessibilityLabel() == button.title)
                    for other in buttons where other !== button { #expect(!button.frame.intersects(other.frame)) }
                    // The HUD is flipped but its parent is not. Calculate the
                    // displayed centre independently of HUD.hitTest's conversion.
                    let point = NSPoint(x: hud.frame.minX + button.frame.midX,
                                        y: hud.frame.maxY - button.frame.midY)
                    #expect(hud.hitTest(point) === button)
                    #expect(parent.hitTest(point) === button)
                }
            }
        }
    }

    @Test func missionChoicesHaveOnePersistentSelectionAndFitBeforeRulesAtMinimumSize() throws {
        let (parent, hud) = fixture(size: NSSize(width: 960, height: 640))
        hud.layoutButtons(mode: .menu, ready: true)
        let choices = hud.subviews.compactMap { $0 as? NativeButton }.filter(\.selectionStyle)
        #expect(choices.count == MissionKind.allCases.count)
        let start = try #require(hud.subviews.compactMap { $0 as? NativeButton }.first { $0.title == "EINSATZ STARTEN" })
        for mission in MissionKind.allCases {
            hud.updateMissionSelection(mission)
            #expect(choices.filter { $0.state == .on }.map(\.title) == [NativeMissionPresentation.name(mission)])
            for _ in 0..<30 { hud.layoutButtons(mode: .menu, ready: true); hud.updateMissionSelection(mission) }
            #expect(choices.filter { $0.state == .on }.count == 1)
            for choice in choices {
                #expect(choice.frame.maxY < hud.bounds.height * 0.62)
                #expect(choice.frame.maxY < start.frame.minY)
                #expect(!(choice.accessibilityHelp() ?? "").isEmpty)
            }
        }
        withExtendedLifetime(parent) {}
    }

    @Test func repeatedRefreshLayoutDoesNotMutateButtonVisibilityOrFrames() throws {
        let (parent, hud) = fixture(size: NSSize(width: 1280, height: 800))
        let buttons = hud.subviews.compactMap { $0 as? NativeButton }
        let probe = try #require(buttons.first)
        let mutations = HUDMutationCount()
        let observations = buttons.flatMap { button in
            [button.observe(\.isHidden, options: [.old, .new]) { _, _ in mutations.visibility += 1 },
             button.observe(\.frame, options: [.old, .new]) { _, _ in mutations.frames += 1 }]
        }
        defer { observations.forEach { $0.invalidate() } }

        // A zero-event assertion is only useful if AppKit's KVO observation
        // actually works. Calibrate it with deliberate property changes first.
        probe.isHidden.toggle()
        probe.frame = NSRect(x: 4, y: 7, width: 40, height: 30)
        #expect(mutations.visibility > 0)
        #expect(mutations.frames > 0)

        for (mode, _) in modes {
            hud.layoutButtons(mode: mode, ready: true)
            let before = buttons.map { ($0.isHidden, $0.frame) }
            mutations.visibility = 0; mutations.frames = 0
            for _ in 0..<90 {
                hud.refresh()
                hud.layoutButtons(mode: mode, ready: true)
            }
            #expect(mutations.visibility == 0)
            #expect(mutations.frames == 0)
            for (button, state) in zip(buttons, before) {
                #expect(button.isHidden == state.0)
                #expect(button.frame == state.1)
            }
        }
        withExtendedLifetime(parent) {}
    }

    @Test func backgroundAndUnavailableButtonsLetMouseHitsThrough() {
        let (parent, hud) = fixture(size: NSSize(width: 1280, height: 800))
        for (mode, _) in modes {
            hud.layoutButtons(mode: mode, ready: true)
            let background = NSPoint(x: hud.frame.midX, y: hud.frame.midY)
            #expect(hud.hitTest(background) == nil)
            #expect(parent.hitTest(background) === parent)

            // Preserve each former button rectangle while hiding controls;
            // loading must not leave an invisible clickable menu behind.
            let centres = hud.subviews.filter { !$0.isHidden }.map {
                NSPoint(x: hud.frame.minX + $0.frame.midX, y: hud.frame.maxY - $0.frame.midY)
            }
            hud.layoutButtons(mode: mode, ready: false)
            #expect(hud.subviews.allSatisfy { $0.isHidden })
            for point in centres { #expect(hud.hitTest(point) == nil) }
        }
    }

    @Test func remappedControlsReachCompactAndContextualHintsAndRespectModes() throws {
        let suite="blacksite.hud-controls.\(UUID().uuidString)"
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        var settings=NativeSettings(defaults:defaults)
        #expect(settings.bindings.assign(.mouse(4),to:.grenade,slot:.primary) == .assigned)
        #expect(settings.bindings.assign(.modifier(.option),to:.grenade,slot:.secondary) == .assigned)
        #expect(settings.bindings.assign(.key(76),to:.reload,slot:.primary) == .assigned)
        #expect(settings.bindings.assign(.mouse(3),to:.reload,slot:.secondary) == .assigned)
        #expect(settings.bindings.assign(nil,to:.interact,slot:.primary) == .assigned)
        #expect(settings.bindings.assign(.mouse(2),to:.interact,slot:.secondary) == .assigned)
        settings.aimMode = .toggle; settings.sprintMode = .toggle
        let hints=NativeHUDControlHints(settings:settings)
        #expect(hints.footer.first?.binding == "MAUS 5")
        #expect(hints.reloadLabel == "NUM ENTER / MAUS 4")
        #expect(hints.interactionLabel == "MAUS 3" && hints.mantleTitle == "MAUS 3  HOCHKLETTERN")
        #expect(hints.modeLines.count == 2 && hints.modeLines.allSatisfy{$0.contains("UMSCHALTEN")})
        let mission=MissionStatus(kind:.recoverData,phase:.collectData,objectivePosition:.zero,objectiveRadius:1.6,
                                  distance:0,progress:0,requiredProgress:0.8,interruption:.interactionReleased,interactionAvailable:true)
        let presentation=NativeMissionPresentation(mission,interactionLabel:hints.interactionLabel)
        #expect(presentation.interactionTitle == "MAUS 3 HALTEN  ·  DATEN SICHERN")
        #expect(!presentation.reason.contains("UMSCHALTEN"))
    }

    @Test func compactFooterFitsItsFixedColumnsAndUnboundActionsNeverFallBackToDefaults() throws {
        let suite="blacksite.hud-unbound.\(UUID().uuidString)"
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        var settings=NativeSettings(defaults:defaults)
        for action in [NativeInputAction.interact,.grenade,.prone,.jump,.rifle,.sniper] {
            for slot in NativeBindingSlot.allCases { settings.bindings.assign(nil,to:action,slot:slot) }
        }
        let hints=NativeHUDControlHints(settings:settings)
        #expect(hints.interactionLabel == NativeControlLabels.unboundLabel)
        #expect(hints.mantleTitle == "INTERAGIEREN NICHT BELEGT" && hints.mantleDetail.contains("Einstellungen"))
        #expect(hints.footer.count == 4)
        let font=NSFont.monospacedSystemFont(ofSize:8,weight:.regular)
        for hint in hints.footer {
            #expect(hint.binding.contains(NativeControlLabels.unboundLabel))
            #expect((hint.binding as NSString).size(withAttributes:[.font:font]).width <= 139)
        }
        // Two long real alternatives use the first assigned slot in the small
        // footer while contextual help keeps both actual bindings.
        settings.bindings.assign(.key(76),to:.grenade,slot:.primary)
        settings.bindings.assign(.mouse(4),to:.grenade,slot:.secondary)
        let remapped=NativeHUDControlHints(settings:settings)
        #expect(remapped.footer[0].binding == "NUM ENTER")
        #expect(NativeControlLabels.label(for:.grenade,bindings:settings.bindings) == "NUM ENTER / MAUS 5")
    }

    @Test func missionChoiceAccessibilityTracksRebindingAndRemovalImmediately() {
        let (parent,hud)=fixture(size:NSSize(width:960,height:640))
        let choices=hud.subviews.compactMap{$0 as? NativeButton}.filter(\.selectionStyle)
        for label in ["MAUS 5",NativeControlLabels.unboundLabel] {
            hud.updateMissionSelection(.recoverData,interactionLabel:label)
            for button in choices where button.title != "WELLEN" {
                let help=button.accessibilityHelp() ?? ""
                #expect(!help.contains("E halten"))
                #expect(label == NativeControlLabels.unboundLabel ? help.contains("Einstellungen belegen") : help.contains(label+" halten"))
            }
        }
        withExtendedLifetime(parent) {}
    }
}

// KVO callbacks run synchronously on the main thread with the mutations above.
private final class HUDMutationCount: @unchecked Sendable {
    var visibility = 0
    var frames = 0
}
