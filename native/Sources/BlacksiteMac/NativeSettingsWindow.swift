import AppKit
import BlacksiteCore

/// A local edit session. Neither capture nor an explicit conflict swap writes
/// UserDefaults; only the coordinator's successful Save commits the draft.
@MainActor
struct NativeBindingDraft {
    struct Target: Equatable { let action: NativeInputAction; let slot: NativeBindingSlot }
    struct Pending { let target: Target; let button: NativeInputButton; let conflict: NativeBindingConflict }
    var bindings: NativeBindings
    private(set) var target: Target?
    private(set) var pending: Pending?
    private(set) var message = "Taste wählen. Esc bricht die Erfassung ab. Zwei Belegungen je Aktion."

    mutating func begin(_ action: NativeInputAction, slot: NativeBindingSlot) {
        target = Target(action: action, slot: slot); pending = nil
        message = "\(NativeControlLabels.actionName(action)): Taste, Maustaste oder Mausrad eingeben. Esc: abbrechen."
    }
    mutating func cancelCapture() {
        target = nil; pending = nil; message = "Zuweisung verworfen. Die bisherige Belegung bleibt erhalten."
    }
    mutating func receive(_ button: NativeInputButton) {
        guard let target else { return }
        apply(button, target: target, swap: false)
    }
    mutating func receiveKey(_ code: UInt16, command: Bool, isRepeat: Bool) {
        guard target != nil, !isRepeat else { return }
        if command { message = "Cmd-Kombinationen bleiben macOS vorbehalten."; return }
        if code == 53 { cancelCapture(); return }
        receive(.key(code))
    }
    mutating func confirmSwap() {
        guard let pending else { return }
        apply(pending.button, target: pending.target, swap: true)
    }
    mutating func clear(_ action: NativeInputAction, slot: NativeBindingSlot) {
        _ = bindings.assign(nil, to: action, slot: slot)
        target = nil; pending = nil; message = "Belegung entfernt. Leere Aktionen sind im Spiel nicht bedienbar."
    }
    mutating func reset() {
        bindings = .defaults; target = nil; pending = nil
        message = "Standardsteuerung im Entwurf wiederhergestellt. Zum Übernehmen speichern."
    }
    private mutating func apply(_ button: NativeInputButton, target: Target, swap: Bool) {
        switch bindings.assign(button, to: target.action, slot: target.slot, swappingConflict: swap) {
        case .assigned:
            self.target = nil; pending = nil
            message = "\(NativeControlLabels.actionName(target.action)): \(NativeControlLabels.label(for: button)). Zum Übernehmen speichern."
        case .conflict(let conflict):
            self.target = nil; pending = Pending(target: target, button: button, conflict: conflict)
            message = "\(NativeControlLabels.label(for: button)) ist bereits „\(NativeControlLabels.actionName(conflict.action))“ zugewiesen. Tauschen oder eine andere Taste wählen."
        case .rejected(let error):
            pending = nil
            switch error {
            case .reservedInput: message = "Diese Taste ist reserviert. Esc: abbrechen; F5, Cmd, Fn und Feststelltaste bleiben frei."
            case .unsupportedInput: message = "Diese Eingabe wird nicht unterstützt. Eine andere Taste wählen."
            case .wheelRequiresDiscreteAction: message = "Mausrad ist hier nicht möglich: Diese Aktion benötigt eine gehaltene Taste."
            }
        }
    }
}

@MainActor
private final class SettingsActionButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; font = .systemFont(ofSize: 12)
        target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

private final class SettingsRowsView: NSView { override var isFlipped: Bool { true } }

/// Plain views are independently testable without a renderer or a game window.
@MainActor
final class NativeSettingsView: NSView {
    static let size = NSSize(width: 680, height: 540)
    let tabs = NSTabView()
    private(set) var editor: NativeBindingDraft
    private let original: NativeSettings
    private let difficulty = NSPopUpButton(), quality = NSPopUpButton(), frameRate = NSPopUpButton()
    private let music = NSSlider(), effects = NSSlider()
    private let soundCaptions = NSButton(checkboxWithTitle: "Geräusche mit Richtung als Text anzeigen", target: nil, action: nil)
    private let sensitivity = NSSlider(), ads = NSSlider(), scope = NSSlider()
    private let aimMode = NSPopUpButton(), sprintMode = NSPopUpButton()
    private let invert = NSButton(checkboxWithTitle: "Y-Achse der Maus invertieren", target: nil, action: nil)
    private var sensitivityValues: [NSTextField] = []
    private var bindingButtons: [(NativeInputAction, NativeBindingSlot, NSButton)] = []
    private var modifierBridge = NativeModifierBridge()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var swapButton: NSButton!
    private(set) var saveButton: NSButton!
    private(set) var cancelButton: NSButton!
    private(set) var resetButton: NSButton!
    var onSave: ((NativeSettings) -> Void)?
    var onCancel: (() -> Void)?
    var capturing: Bool { editor.target != nil }

    init(settings: NativeSettings) {
        original = settings; editor = NativeBindingDraft(bindings: settings.bindings)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        tabs.frame = NSRect(x: 20, y: 78, width: 640, height: 440)
        addSubview(tabs)
        makeGeneralTab(settings); makeMouseTab(settings); makeBindingsTab()
        resetButton = SettingsActionButton("Steuerung zurücksetzen") { [weak self] in self?.resetControls() }
        resetButton.frame = NSRect(x: 24, y: 22, width: 220, height: 32); addSubview(resetButton)
        cancelButton = SettingsActionButton("Abbrechen") { [weak self] in self?.onCancel?() }
        cancelButton.frame = NSRect(x: 410, y: 22, width: 110, height: 32); cancelButton.keyEquivalent = "\u{1b}"; addSubview(cancelButton)
        saveButton = SettingsActionButton("Speichern") { [weak self] in
            guard let self, !self.capturing else { return }; self.onSave?(self.editedSettings())
        }
        saveButton.frame = NSRect(x: 530, y: 22, width: 126, height: 32); saveButton.keyEquivalent = "\r"; addSubview(saveButton)
        refreshBindings()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func editedSettings() -> NativeSettings {
        var value = original
        value.difficulty = [Difficulty.easy, .normal, .hard][max(0, difficulty.indexOfSelectedItem)]
        value.highQuality = quality.indexOfSelectedItem == 1
        value.fps = frameRate.indexOfSelectedItem == 1 ? 120 : 60
        value.musicVolume = music.floatValue; value.effectsVolume = effects.floatValue
        value.soundCaptions = soundCaptions.state == .on
        value.sensitivity = sensitivity.floatValue; value.adsSensitivity = ads.floatValue; value.scopeSensitivity = scope.floatValue
        value.aimMode = aimMode.indexOfSelectedItem == 1 ? .toggle : .hold
        value.sprintMode = sprintMode.indexOfSelectedItem == 1 ? .toggle : .hold
        value.invertY = invert.state == .on; value.bindings = editor.bindings
        return value
    }

    func beginCapture(_ action: NativeInputAction, slot: NativeBindingSlot) {
        modifierBridge.synchronize(flags: NSEvent.modifierFlags)
        editor.begin(action, slot: slot); refreshBindings()
    }
    func capture(_ button: NativeInputButton) { editor.receive(button); refreshBindings() }
    func captureKey(_ code: UInt16, command: Bool = false, isRepeat: Bool = false) {
        editor.receiveKey(code, command: command, isRepeat: isRepeat); refreshBindings()
    }
    func captureModifier(_ code: UInt16, flags: NSEvent.ModifierFlags) {
        if NativeModifierInput.change(keyCode: code, flags: flags) != nil {
            if let (button, down) = modifierBridge.change(keyCode: code, flags: flags), down { capture(button) }
        } else { captureKey(code) }
    }
    func synchronizeCaptureModifiers(_ flags: NSEvent.ModifierFlags) { modifierBridge.synchronize(flags: flags) }
    func cancelCapture() { editor.cancelCapture(); refreshBindings() }
    func resetControls() {
        var value = original; value.resetControls()
        sensitivity.floatValue = value.sensitivity; ads.floatValue = value.adsSensitivity; scope.floatValue = value.scopeSensitivity
        invert.state = .off; aimMode.selectItem(at: 0); sprintMode.selectItem(at: 0)
        editor.reset(); refreshSensitivityValues(); refreshBindings()
    }

    private func addTab(_ title: String) -> NSView {
        let item = NSTabViewItem(identifier: title); item.label = title
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 610, height: 390)); item.view = view
        tabs.addTabViewItem(item); return view
    }
    @discardableResult private func label(_ title: String, x: CGFloat = 20, y: CGFloat, width: CGFloat = 240, in parent: NSView, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: title); field.frame = NSRect(x: x, y: y, width: width, height: 22)
        field.font = .systemFont(ofSize: secondary ? 11 : 13); field.textColor = secondary ? .secondaryLabelColor : .labelColor
        parent.addSubview(field); return field
    }
    private func popup(_ control: NSPopUpButton, titles: [String], selected: Int, y: CGFloat, in parent: NSView) {
        control.addItems(withTitles: titles); control.selectItem(at: selected)
        control.frame = NSRect(x: 288, y: y - 3, width: 284, height: 28); parent.addSubview(control)
    }
    private func slider(_ control: NSSlider, value: Float, range: ClosedRange<Float>, y: CGFloat, title: String, in parent: NSView, readout: Bool = false) {
        control.minValue = Double(range.lowerBound); control.maxValue = Double(range.upperBound); control.floatValue = value
        control.frame = NSRect(x: 288, y: y - 3, width: readout ? 220 : 284, height: 26)
        control.setAccessibilityLabel(title); parent.addSubview(control)
        if readout {
            control.target = self; control.action = #selector(sensitivityChanged)
            let number = label("", x: 518, y: y, width: 66, in: parent, secondary: true)
            number.alignment = .right; sensitivityValues.append(number)
        }
    }
    private func makeGeneralTab(_ settings: NativeSettings) {
        let content = addTab("Spiel & Grafik")
        label("Schwierigkeit", y: 332, in: content)
        popup(difficulty, titles: ["Rekrut", "Operator", "Veteran"], selected: settings.difficulty == .easy ? 0 : settings.difficulty == .hard ? 2 : 1, y: 332, in: content)
        label("Gilt ab dem nächsten Einsatz.", y: 308, width: 400, in: content, secondary: true)
        label("Grafikqualität", y: 263, in: content)
        popup(quality, titles: ["Ausgewogen", "Hoch"], selected: settings.highQuality ? 1 : 0, y: 263, in: content)
        label("Bildratenlimit", y: 211, in: content)
        popup(frameRate, titles: ["60 FPS – sparsam", "120 FPS – flüssig"], selected: settings.fps == 120 ? 1 : 0, y: 211, in: content)
        label("Musik", y: 143, in: content)
        slider(music, value: settings.musicVolume, range: 0...1, y: 143, title: "Musiklautstärke", in: content)
        label("Effekte und Warnungen", y: 91, in: content)
        soundCaptions.state = settings.soundCaptions ? .on : .off
        soundCaptions.frame = NSRect(x: 20, y: 48, width: 550, height: 24)
        soundCaptions.setAccessibilityHelp("Zeigt nur tatsächlich hörbare Geräusche, auch bei stummgeschalteter Ausgabe.")
        content.addSubview(soundCaptions)
        slider(effects, value: settings.effectsVolume, range: 0...1, y: 91, title: "Effektlautstärke", in: content)
        label("Änderungen werden erst mit Speichern übernommen.", y: 18, width: 560, in: content, secondary: true)
    }
    private func makeMouseTab(_ settings: NativeSettings) {
        let content = addTab("Maus")
        for (title, control, value, y) in [("Umsehen", sensitivity, settings.sensitivity, CGFloat(333)),
                                         ("Zielen · Sturmgewehr", ads, settings.adsSensitivity, CGFloat(280)),
                                         ("Zielfernrohr · Scharfschütze", scope, settings.scopeSensitivity, CGFloat(227))] {
            label(title, y: y, in: content)
            slider(control, value: value, range: NativeSettings.sensitivityRange, y: y, title: title, in: content, readout: true)
        }
        label("Die drei Mauswerte sind unabhängig. 100 % = Standard beim Umsehen.", y: 194, width: 565, in: content, secondary: true)
        label("Zielen", y: 151, in: content)
        popup(aimMode, titles: ["Halten", "Umschalten"], selected: settings.aimMode == .toggle ? 1 : 0, y: 151, in: content)
        label("Sprinten", y: 103, in: content)
        popup(sprintMode, titles: ["Halten", "Umschalten"], selected: settings.sprintMode == .toggle ? 1 : 0, y: 103, in: content)
        invert.frame = NSRect(x: 20, y: 54, width: 540, height: 25); invert.state = settings.invertY ? .on : .off; content.addSubview(invert)
        label("Pause und Fokusverlust beenden auch umgeschaltetes Zielen und Sprinten.", y: 18, width: 575, in: content, secondary: true)
        refreshSensitivityValues()
    }
    private func makeBindingsTab() {
        let content = addTab("Tasten")
        label("Esc: Pause · F5: Leistung · Cmd-Kürzel bleiben macOS vorbehalten.", y: 364, width: 570, in: content, secondary: true)
        label("Aktion", x: 20, y: 337, width: 175, in: content, secondary: true)
        label("Belegung 1", x: 215, y: 337, width: 160, in: content, secondary: true)
        label("Belegung 2", x: 410, y: 337, width: 160, in: content, secondary: true)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 70, width: 588, height: 262))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false; scroll.drawsBackground = false
        let rows = SettingsRowsView(frame: NSRect(x: 0, y: 0, width: 568, height: CGFloat(NativeInputAction.allCases.count) * 34))
        for (index, action) in NativeInputAction.allCases.enumerated() {
            let y = CGFloat(index) * 34
            let title = NSTextField(labelWithString: NativeControlLabels.actionName(action))
            title.font = .systemFont(ofSize: 12); title.frame = NSRect(x: 0, y: y + 8, width: 184, height: 20); rows.addSubview(title)
            for (slot, x) in [(NativeBindingSlot.primary, CGFloat(192)), (.secondary, CGFloat(385))] {
                let button = SettingsActionButton("") { [weak self] in self?.beginCapture(action, slot: slot) }
                button.frame = NSRect(x: x, y: y + 3, width: 150, height: 28)
                button.setAccessibilityLabel("\(NativeControlLabels.actionName(action)), \(slot == .primary ? "Belegung 1" : "Belegung 2")")
                rows.addSubview(button); bindingButtons.append((action, slot, button))
                let clear = SettingsActionButton("×") { [weak self] in self?.editor.clear(action, slot: slot); self?.refreshBindings() }
                clear.frame = NSRect(x: x + 150, y: y + 3, width: 27, height: 28)
                clear.setAccessibilityLabel("\(NativeControlLabels.actionName(action)), \(slot == .primary ? "Belegung 1" : "Belegung 2") entfernen")
                rows.addSubview(clear)
            }
        }
        scroll.documentView = rows; content.addSubview(scroll)
        status.frame = NSRect(x: 20, y: 13, width: 458, height: 48); status.font = .systemFont(ofSize: 11)
        status.setAccessibilityLabel("Tastenzuweisung"); content.addSubview(status)
        swapButton = SettingsActionButton("Tauschen") { [weak self] in self?.editor.confirmSwap(); self?.refreshBindings() }
        swapButton.frame = NSRect(x: 492, y: 22, width: 100, height: 30); content.addSubview(swapButton)
    }
    private func refreshBindings() {
        for (action, slot, button) in bindingButtons {
            let selected = editor.target == NativeBindingDraft.Target(action: action, slot: slot)
            button.title = selected ? "EINGABE …" : editor.bindings.button(for: action, slot: slot).map { NativeControlLabels.label(for: $0) } ?? "—"
            button.setAccessibilityValue(button.title)
        }
        status.stringValue = editor.message; status.setAccessibilityValue(editor.message)
        swapButton?.isHidden = editor.pending == nil
        saveButton?.isEnabled = !capturing; resetButton?.isEnabled = !capturing
    }
    @objc private func sensitivityChanged() { refreshSensitivityValues() }
    private func refreshSensitivityValues() {
        for (field, control) in zip(sensitivityValues, [sensitivity, ads, scope]) {
            field.stringValue = "\(Int((control.floatValue / NativeSettings.defaultSensitivity * 100).rounded())) %"
        }
    }
}

/// Capture is confined to this sheet. Normal Command shortcuts still go through
/// AppKit; a captured Enter/Space/Tab cannot click Save or move focus instead.
@MainActor
final class NativeSettingsPanel: NSPanel {
    let settingsView: NativeSettingsView
    init(settings: NativeSettings) {
        settingsView = NativeSettingsView(settings: settings)
        super.init(contentRect: NSRect(origin: .zero, size: NativeSettingsView.size), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Blacksite – Einstellungen"; appearance = NSAppearance(named: .darkAqua)
        contentView = settingsView
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if settingsView.capturing && event.type == .keyDown && !event.modifierFlags.contains(.command) {
            settingsView.captureKey(event.keyCode, isRepeat: event.isARepeat); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        guard settingsView.capturing else { super.sendEvent(event); return }
        if event.modifierFlags.contains(.command) {
            settingsView.synchronizeCaptureModifiers(event.modifierFlags)
            if event.type == .keyDown { settingsView.captureKey(event.keyCode, command: true, isRepeat: event.isARepeat) }
            super.sendEvent(event); return
        }
        switch event.type {
        case .keyDown: settingsView.captureKey(event.keyCode, isRepeat: event.isARepeat)
        case .keyUp: break
        case .flagsChanged: settingsView.captureModifier(event.keyCode, flags: event.modifierFlags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: settingsView.capture(.mouse(event.buttonNumber))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: break
        case .scrollWheel:
            if abs(event.scrollingDeltaY) > 0.5 { settingsView.capture(.wheel(event.scrollingDeltaY > 0 ? .up : .down)) }
        default: super.sendEvent(event)
        }
    }
}
