import AppKit
import BlacksiteCore

/// A local draft. Opening or cancelling the sheet cannot alter an active run.
@MainActor
final class NativeLoadoutView: NSView {
    static let size = NSSize(width: 600, height: 380)
    let patternChoice = NSPopUpButton()
    let applyButton = NSButton(title: "Übernehmen", target: nil, action: nil)
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let inventory = NSTextField(wrappingLabelWithString: "")
    var onApply: ((CamouflagePattern) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    var selectedPattern: CamouflagePattern {
        let index = patternChoice.indexOfSelectedItem
        return CamouflagePattern.allCases.indices.contains(index) ? CamouflagePattern.allCases[index] : .none
    }
    var previewLoadout: LoadoutDefinition { LoadoutDefinition(camouflage: selectedPattern) }

    init(pattern: CamouflagePattern) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let title = NSTextField(labelWithString: "Feldausrüstung")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.frame = NSRect(x: 24, y: 22, width: 552, height: 28); addSubview(title)
        let label = NSTextField(labelWithString: "Tarnmuster")
        label.frame = NSRect(x: 24, y: 77, width: 130, height: 22); addSubview(label)
        patternChoice.addItems(withTitles: CamouflagePattern.allCases.map(NativeCamouflagePresentation.name))
        patternChoice.selectItem(at: CamouflagePattern.allCases.firstIndex(of: pattern) ?? 0)
        patternChoice.frame = NSRect(x: 170, y: 70, width: 406, height: 30)
        patternChoice.target = self; patternChoice.action = #selector(choiceChanged)
        patternChoice.setAccessibilityLabel("Tarnmuster für den nächsten Einsatz")
        patternChoice.setAccessibilityHelp("Der Tarnanzug ersetzt eine zusätzliche Splittergranate. Die beiden Waffen bleiben verfügbar.")
        addSubview(patternChoice)
        detail.font = .systemFont(ofSize: 13); detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 24, y: 115, width: 552, height: 62); addSubview(detail)
        let stockTitle = NSTextField(labelWithString: "STARTVORRAT")
        stockTitle.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        stockTitle.frame = NSRect(x: 24, y: 193, width: 552, height: 20); addSubview(stockTitle)
        inventory.font = .systemFont(ofSize: 14)
        inventory.frame = NSRect(x: 24, y: 222, width: 552, height: 57); addSubview(inventory)
        let advice = NSTextField(wrappingLabelWithString: "Tarnung verzögert die Erkennung entfernter Gegner. Auf kurze Distanz und nach bestätigtem Sichtkontakt bleibt Deckung entscheidend.")
        advice.font = .systemFont(ofSize: 12); advice.textColor = .secondaryLabelColor
        advice.frame = NSRect(x: 24, y: 285, width: 552, height: 38); addSubview(advice)
        for button in [cancelButton, applyButton] { button.bezelStyle = .rounded; button.target = self; addSubview(button) }
        cancelButton.frame = NSRect(x: 288, y: 336, width: 138, height: 30)
        applyButton.frame = NSRect(x: 438, y: 336, width: 138, height: 30)
        cancelButton.action = #selector(cancel); cancelButton.keyEquivalent = "\u{1b}"
        applyButton.action = #selector(apply); applyButton.keyEquivalent = "\r"
        patternChoice.nextKeyView = cancelButton; cancelButton.nextKeyView = applyButton; applyButton.nextKeyView = patternChoice
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choiceChanged() { updatePreview() }
    @objc private func apply() { onApply?(selectedPattern) }
    @objc private func cancel() { onCancel?() }
    private func updatePreview() {
        detail.stringValue = NativeCamouflagePresentation.description(selectedPattern)
        inventory.stringValue = "\(previewLoadout.fragmentationGrenades) Splittergranaten\nAR-4: \(WeaponKind.rifle.capacity) + \(WeaponKind.rifle.initialReserve) Schuss  ·  M82: \(WeaponKind.sniper.capacity) + \(WeaponKind.sniper.initialReserve) Schuss"
        inventory.setAccessibilityLabel("Startvorrat: " + inventory.stringValue)
    }
}

@MainActor
final class NativeLoadoutPanel: NSPanel {
    let loadoutView: NativeLoadoutView
    init(pattern: CamouflagePattern) {
        loadoutView = NativeLoadoutView(pattern: pattern)
        super.init(contentRect: NSRect(origin: .zero, size: NativeLoadoutView.size), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Feldausrüstung"; contentView = loadoutView
        initialFirstResponder = loadoutView.patternChoice
    }
}
