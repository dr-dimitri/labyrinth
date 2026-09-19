import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

/// Real AppKit views only: no window, coordinator, renderer or event synthesis.
@MainActor
@Suite(.serialized)
struct NativeHUDTests {
    private let modes: [(NativeRenderMode, Set<String>)] = [
        (.menu, ["EINSATZ STARTEN", "EINSTELLUNGEN", "STEUERUNG / ARSENAL", "WELLEN", "DATEN BERGEN", "FUNK SICHERN"]),
        (.playing, ["Ⅱ  ESC"]),
        (.paused, ["FORTSETZEN", "EINSTELLUNGEN", "ZURÜCK ZUM HAUPTMENÜ"]),
        (.result, ["ERNEUT ANTRETEN", "ZURÜCK ZUM HAUPTMENÜ"]),
    ]

    private func fixture(size: NSSize) -> (NSView, GameHUDView) {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 80, height: size.height + 60))
        let hud = GameHUDView(frame: NSRect(origin: NSPoint(x: 37, y: 29), size: size))
        parent.addSubview(hud)
        return (parent, hud)
    }

    @Test func visibleButtonCentresReceiveHitsAcrossMenuStatesAndWindowSizes() {
        for size in [NSSize(width: 960, height: 640), NSSize(width: 1280, height: 800), NSSize(width: 1920, height: 1080)] {
            let (parent, hud) = fixture(size: size)
            #expect(!parent.isFlipped && hud.isFlipped)
            for (mode, titles) in modes {
                hud.layoutButtons(mode: mode, ready: true)
                let buttons = hud.subviews.compactMap { $0 as? NativeButton }.filter { !$0.isHidden }
                #expect(Set(buttons.map(\.title)) == titles)
                for button in buttons {
                    #expect(hud.bounds.contains(button.frame))
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
}

// KVO callbacks run synchronously on the main thread with the mutations above.
private final class HUDMutationCount: @unchecked Sendable {
    var visibility = 0
    var frames = 0
}
