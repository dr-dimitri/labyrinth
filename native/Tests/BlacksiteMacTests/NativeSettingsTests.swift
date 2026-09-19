import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "Blacksite.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func legacyMouseFeelMigratesAndIndependentSettingsRoundTrip() throws {
        try withDefaults { defaults in
            defaults.set(0.003, forKey: "native.sensitivity")
            var settings = NativeSettings(defaults: defaults)
            #expect(abs(settings.sensitivity - 0.003) < 0.000001)
            #expect(abs(settings.adsSensitivity - 0.00195) < 0.000001)
            #expect(abs(settings.scopeSensitivity - 0.00057) < 0.000001)
            #expect(settings.bindings == .defaults && settings.aimMode == .hold && settings.sprintMode == .hold)
            settings.sensitivity = 0.004; settings.adsSensitivity = 0.0012; settings.scopeSensitivity = 0.0002
            settings.aimMode = .toggle; settings.sprintMode = .toggle; settings.invertY = true
            #expect(settings.bindings.assign(.key(17), to: .jump, slot: .primary) == .assigned)
            settings.musicVolume = 0.17; settings.effectsVolume = 0.83; settings.selectedMission = .secureRadio
            settings.save(defaults: defaults)
            let loaded = NativeSettings(defaults: defaults)
            #expect(loaded.bindings == settings.bindings)
            #expect(loaded.aimMode == .toggle && loaded.sprintMode == .toggle && loaded.invertY)
            #expect(loaded.sensitivity == settings.sensitivity && loaded.adsSensitivity == settings.adsSensitivity && loaded.scopeSensitivity == settings.scopeSensitivity)
            #expect(loaded.musicVolume == settings.musicVolume && loaded.effectsVolume == settings.effectsVolume && loaded.selectedMission == .secureRadio)
        }
    }

    @Test func corruptedInputPreferencesFallBackWithoutNaNMouseMotion() {
        withDefaults { defaults in
            defaults.set(Float.nan, forKey: "native.sensitivity")
            defaults.set(Float.infinity, forKey: "native.adsSensitivity")
            defaults.set(-2, forKey: "native.scopeSensitivity")
            defaults.set("unknown", forKey: "native.aimMode")
            defaults.set(Data("broken".utf8), forKey: "native.bindings.v1")
            let settings = NativeSettings(defaults: defaults)
            #expect(settings.sensitivity == NativeSettings.defaultSensitivity)
            #expect(settings.adsSensitivity.isFinite && NativeSettings.sensitivityRange.contains(settings.adsSensitivity))
            #expect(settings.scopeSensitivity == NativeSettings.sensitivityRange.lowerBound)
            #expect(settings.bindings == .defaults && settings.aimMode == .hold)
            let delta = settings.mouseLookDelta(dx: .infinity, dy: .nan, aiming: true, weapon: .sniper)
            #expect(delta == .zero)
        }
    }

    @Test func separateSensitivitiesAndInvertAffectOnlySelectedModeAndYAxis() {
        withDefaults { defaults in
            var settings = NativeSettings(defaults: defaults)
            settings.sensitivity = 0.004; settings.adsSensitivity = 0.002; settings.scopeSensitivity = 0.0005
            let hip = settings.mouseLookDelta(dx: 10, dy: -4, aiming: false, weapon: .sniper)
            let ads = settings.mouseLookDelta(dx: 10, dy: -4, aiming: true, weapon: .rifle)
            #expect(abs(hip.x + 0.04) < 0.000001 && abs(hip.y - 0.016) < 0.000001)
            #expect(abs(ads.x + 0.02) < 0.000001 && abs(ads.y - 0.008) < 0.000001)
            let scope = settings.mouseLookDelta(dx: 10, dy: -4, aiming: true, weapon: .sniper)
            #expect(abs(scope.x + 0.005) < 0.000001 && abs(scope.y - 0.002) < 0.000001)
            settings.invertY = true
            let inverted = settings.mouseLookDelta(dx: 10, dy: -4, aiming: true, weapon: .sniper)
            #expect(inverted.x == scope.x && inverted.y == -scope.y)
        }
    }

    @Test func defaultsResetOnlyControlsAndTheSheetKeepsChangesLocal() {
        withDefaults { defaults in
            var saved = NativeSettings(defaults: defaults)
            saved.difficulty = .hard; saved.selectedMission = .recoverData; saved.highQuality = false; saved.fps = 120
            saved.musicVolume = 0.12; saved.effectsVolume = 0.78; saved.aimMode = .toggle; saved.invertY = true
            saved.save(defaults: defaults)
            let view = NativeSettingsView(settings: saved)
            view.beginCapture(.jump, slot: .primary); view.capture(.key(17))
            #expect(view.editedSettings().bindings.button(for: .jump, slot: .primary) == .key(17))
            #expect(NativeSettings(defaults: defaults).bindings == .defaults)
            view.resetControls()
            let reset = view.editedSettings()
            #expect(reset.bindings == .defaults && reset.aimMode == .hold && reset.sprintMode == .hold && !reset.invertY)
            #expect(reset.sensitivity == NativeSettings.defaultSensitivity)
            #expect(reset.difficulty == .hard && reset.selectedMission == .recoverData && !reset.highQuality && reset.fps == 120)
            #expect(reset.musicVolume == saved.musicVolume && reset.effectsVolume == saved.effectsVolume)
            #expect(NativeSettings(defaults: defaults).aimMode == .toggle)
        }
    }

    @Test func captureCancelRepeatReservedKeysAndExplicitConflictSwap() {
        var draft = NativeBindingDraft(bindings: .defaults)
        draft.begin(.jump, slot: .primary)
        draft.receiveKey(17, command: false, isRepeat: true)
        #expect(draft.target != nil && draft.bindings == .defaults)
        draft.receiveKey(96, command: false, isRepeat: false)
        #expect(draft.target != nil && draft.message.contains("reserviert") && draft.bindings == .defaults)
        draft.receiveKey(17, command: true, isRepeat: false)
        #expect(draft.target != nil && draft.bindings == .defaults)
        draft.receiveKey(53, command: false, isRepeat: false)
        #expect(draft.target == nil && draft.bindings == .defaults)
        draft.begin(.jump, slot: .primary); draft.receive(.key(14))
        #expect(draft.pending?.conflict.action == .interact && draft.bindings == .defaults)
        draft.cancelCapture()
        #expect(draft.pending == nil && draft.bindings == .defaults)
        draft.begin(.jump, slot: .primary); draft.receive(.key(14)); draft.confirmSwap()
        #expect(draft.bindings.button(for: .jump, slot: .primary) == .key(14))
        #expect(draft.bindings.button(for: .interact, slot: .primary) == .key(49))
        #expect(draft.pending == nil && draft.target == nil)
    }

    @Test func bothShiftKeysAcrossPauseCannotRelatchUntilFullyReleased() throws {
        var bridge = NativeModifierBridge(), state = NativeInputState(sprintMode: .toggle)
        func deliver(_ change: (NativeInputButton, Bool)?) {
            guard let (button, down) = change else { return }
            if down { state.press(button) } else { state.release(button) }
        }
        deliver(bridge.change(keyCode: 56, flags: [.shift]))
        #expect(state.snapshot().sprint)
        #expect(bridge.change(keyCode: 60, flags: [.shift]) == nil)
        state.clear(); bridge.synchronize(flags: [.shift])
        // Releasing the left side while the right side is still held is not
        // another press, even though flagsChanged still contains .shift.
        deliver(bridge.change(keyCode: 56, flags: [.shift]))
        #expect(!state.snapshot().sprint)
        deliver(bridge.change(keyCode: 60, flags: []))
        #expect(!state.snapshot().sprint)
        deliver(bridge.change(keyCode: 56, flags: [.shift]))
        #expect(state.snapshot().sprint)
        // The release can happen outside our window: focus/resume resyncs it.
        state.clear(); bridge.synchronize(flags: [])
        deliver(bridge.change(keyCode: 60, flags: [.shift]))
        #expect(state.snapshot().sprint)
        let controlChange = bridge.change(keyCode: 62, flags: [.shift, .control])
        let control = try #require(controlChange)
        #expect(control.0 == .modifier(.control) && control.1)
    }

    @Test func settingsTabsAndFooterFitInsideMinimumWindowContent() throws {
        withDefaults { defaults in
            let view = NativeSettingsView(settings: NativeSettings(defaults: defaults))
            #expect(view.bounds.width < 960 && view.bounds.height + 28 < 618)
            #expect(view.tabs.tabViewItems.map(\.label) == ["Spiel & Grafik", "Maus", "Tasten"])
            for button in [view.saveButton!, view.cancelButton!, view.resetButton!] {
                #expect(view.bounds.contains(button.frame))
                #expect(button.frame.maxY < view.tabs.frame.minY)
                #expect(button.isEnabled && !button.isHidden)
            }
            for item in view.tabs.tabViewItems {
                view.tabs.selectTabViewItem(item)
                guard let content = item.view else { Issue.record("Missing tab content"); continue }
                for child in content.subviews { #expect(content.bounds.contains(child.frame)) }
            }
            view.beginCapture(.jump, slot: .primary)
            #expect(!view.saveButton.isEnabled)
            view.captureKey(53)
            #expect(view.saveButton.isEnabled)
            // Command-modified flags must not become a binding when just one
            // Shift side is subsequently released with the other still held.
            view.beginCapture(.jump, slot: .primary)
            view.synchronizeCaptureModifiers([.command, .shift])
            view.captureModifier(56, flags: [.shift])
            #expect(view.capturing && view.editedSettings().bindings == .defaults)
            view.captureModifier(60, flags: [])
            view.captureModifier(56, flags: [.shift])
            #expect(!view.capturing && view.editor.pending?.conflict.action == .sprint)
        }
    }

    @Test func centralLabelsAndHelpReflectRebindingAndUnboundActions() {
        withDefaults { defaults in
            var settings = NativeSettings(defaults: defaults)
            settings.aimMode = .toggle
            settings.bindings.assign(.key(49), to: .interact, slot: .primary, swappingConflict: true)
            settings.bindings.assign(nil, to: .reload, slot: .primary)
            #expect(NativeControlLabels.label(for: .interact, bindings: settings.bindings) == "LEER")
            #expect(NativeControlLabels.label(for: .reload, bindings: settings.bindings) == NativeControlLabels.unboundLabel)
            #expect(NativeControlLabels.label(for: .mouse(4)) == "MAUS 5")
            #expect(NativeControlLabels.label(for: .modifier(.control)) == "STRG")
            #expect(NativeControlLabels.label(for: .wheel(.up)) == "RAD ↑")
            let help = NativeControlLabels.help(settings: settings)
            #expect(help.contains("Interagieren: LEER") && help.contains("UMSCHALTEN"))
            #expect(help.contains("Nachladen: NICHT BELEGT") && help.contains("ESC: Pause"))
            for action in NativeInputAction.allCases { #expect(!NativeControlLabels.label(for: action, bindings: settings.bindings).isEmpty) }
        }
    }
}
