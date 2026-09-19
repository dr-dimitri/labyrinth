import AppKit
import BlacksiteCore

/// The sheet edits a local value; a live run never reads these controls.
struct NativeBriefingDraft {
    var map: MapDefinition
    var mission: MissionKind
    var difficulty: Difficulty
    var camouflage: CamouflagePattern
    var operatorClass: OperatorClass = .assault
    var loadout: LoadoutDefinition { .init(operatorClass: operatorClass, camouflage: camouflage) }
}

@MainActor
final class NativeBriefingView: NSView {
    static let size = NSSize(width: 860, height: 590)
    let mapChoice = NSPopUpButton(), missionChoice = NSPopUpButton()
    let difficultyChoice = NSPopUpButton(), patternChoice = NSPopUpButton(), classChoice = NSPopUpButton()
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    let applyButton = NSButton(title: "Übernehmen", target: nil, action: nil)
    let startButton = NSButton(title: "Einsatz starten", target: nil, action: nil)
    let mapView: NativeBriefingMapView
    private let classAdvice = NSTextField(wrappingLabelWithString: "")
    private let rules = NSTextField(wrappingLabelWithString: "")
    private let inventory = NSTextField(wrappingLabelWithString: "")
    private let terrainAdvice = NSTextField(wrappingLabelWithString: "")
    private let maps: [MapDefinition]
    private var missions: [MissionKind] = []
    private let interactionLabel: String
    private let gadgetLabel: String
    var onApply: ((NativeBriefingDraft, Bool) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    var draft: NativeBriefingDraft {
        NativeBriefingDraft(map: maps[max(0, mapChoice.indexOfSelectedItem)],
            mission: missions[max(0, missionChoice.indexOfSelectedItem)],
            difficulty: Difficulty.allCases[max(0, difficultyChoice.indexOfSelectedItem)],
            camouflage: CamouflagePattern.allCases[max(0, patternChoice.indexOfSelectedItem)],
            operatorClass: OperatorClass.allCases[max(0, classChoice.indexOfSelectedItem)])
    }

    init(draft: NativeBriefingDraft, maps: [MapDefinition] = PublishedMapRegistry.maps,
         interactionLabel: String = "E", gadgetLabel: String = "B") {
        self.maps = maps.isEmpty ? [draft.map] : maps
        self.interactionLabel = interactionLabel; self.gadgetLabel = gadgetLabel
        mapView = NativeBriefingMapView(map: draft.map, mission: draft.mission)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let title = NSTextField(labelWithString: "Einsatzbriefing")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = NSRect(x: 24, y: 18, width: 600, height: 30); addSubview(title)
        popup(mapChoice, label: "Karte", titles: self.maps.map(\.displayName),
              selected: self.maps.firstIndex(where: { $0.id == draft.map.id }) ?? 0, y: 64)
        missions = self.maps[max(0, mapChoice.indexOfSelectedItem)].supportedMissions
        popup(missionChoice, label: "Auftrag", titles: missions.map(NativeMissionPresentation.name),
              selected: missions.firstIndex(of: draft.mission) ?? 0, y: 105)
        popup(difficultyChoice, label: "Schwierigkeit", titles: ["Rekrut", "Operator", "Veteran"],
              selected: Difficulty.allCases.firstIndex(of: draft.difficulty) ?? 1, y: 146)
        popup(classChoice, label: "Klasse", titles: OperatorClass.allCases.map(NativeClassPresentation.name),
              selected: OperatorClass.allCases.firstIndex(of: draft.operatorClass) ?? 0, y: 187)
        popup(patternChoice, label: "Tarnmuster", titles: CamouflagePattern.allCases.map(NativeCamouflagePresentation.name),
              selected: CamouflagePattern.allCases.firstIndex(of: draft.camouflage) ?? 0, y: 228)
        rules.font = .systemFont(ofSize: 12); rules.frame = NSRect(x: 24, y: 274, width: 400, height: 70)
        inventory.font = .systemFont(ofSize: 12, weight: .medium); inventory.frame = NSRect(x: 24, y: 350, width: 400, height: 55)
        terrainAdvice.font = .systemFont(ofSize: 12); terrainAdvice.textColor = .secondaryLabelColor
        terrainAdvice.frame = NSRect(x: 24, y: 417, width: 400, height: 118)
        for label in [rules, inventory, terrainAdvice, classAdvice] { addSubview(label) }
        mapView.frame = NSRect(x: 448, y: 62, width: 388, height: 322); addSubview(mapView)
        classAdvice.font = .systemFont(ofSize: 12); classAdvice.frame = NSRect(x: 448, y: 401, width: 388, height: 128)
        for (index, button) in [cancelButton, applyButton, startButton].enumerated() {
            button.bezelStyle = .rounded; button.target = self
            button.frame = NSRect(x: 384 + index * 152, y: 550, width: 148, height: 30); addSubview(button)
        }
        cancelButton.action = #selector(cancel); cancelButton.keyEquivalent = "\u{1b}"
        applyButton.action = #selector(apply)
        startButton.action = #selector(start); startButton.keyEquivalent = "\r"
        let controls: [NSView] = [mapChoice, missionChoice, difficultyChoice, classChoice, patternChoice, cancelButton, applyButton, startButton]
        for index in controls.indices { controls[index].nextKeyView = controls[(index + 1) % controls.count] }
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func popup(_ popup: NSPopUpButton, label: String, titles: [String], selected: Int, y: CGFloat) {
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 12); text.frame = NSRect(x: 24, y: y + 5, width: 100, height: 22); addSubview(text)
        popup.addItems(withTitles: titles); popup.selectItem(at: selected)
        popup.frame = NSRect(x: 127, y: y, width: 297, height: 30)
        popup.target = self; popup.action = #selector(choiceChanged(_:)); popup.setAccessibilityLabel(label + " für den nächsten Einsatz")
        addSubview(popup)
    }
    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        if sender === mapChoice {
            let previous = missions[max(0, missionChoice.indexOfSelectedItem)]
            missions = maps[max(0, mapChoice.indexOfSelectedItem)].supportedMissions
            missionChoice.removeAllItems(); missionChoice.addItems(withTitles: missions.map(NativeMissionPresentation.name))
            missionChoice.selectItem(at: missions.firstIndex(of: previous) ?? 0)
        }
        updatePreview()
    }
    @objc private func cancel() { onCancel?() }
    @objc private func apply() { onApply?(draft, false) }
    @objc private func start() { onApply?(draft, true) }
    func updatePreview() {
        let choice = draft
        rules.stringValue = NativeMissionPresentation.rules(choice.mission, interactionLabel: interactionLabel)
        inventory.stringValue = NativeClassPresentation.inventory(choice.loadout)
        classAdvice.stringValue = NativeClassPresentation.name(choice.operatorClass).uppercased() + "\n\n" + NativeClassPresentation.description(choice.operatorClass, gadgetKey: gadgetLabel)
        terrainAdvice.stringValue = NativeCamouflagePresentation.description(choice.camouflage) + "\n\n" + Self.terrainHint(choice.map)
        mapView.update(map: choice.map, mission: choice.mission)
    }
    static func terrainHint(_ map: MapDefinition) -> String {
        var facts: [String] = []
        if !map.environment.vegetationZones.isEmpty { facts.append("Bewachsene Zonen dämpfen Sicht, halten keine Kugeln auf.") }
        if map.environment.alarm != nil { facts.append("Eine Funkmeldung kann weitere Wachen alarmieren.") }
        if facts.isEmpty { facts.append("Nutze feste Deckung und prüfe offene Querungen vor dem Vorrücken.") }
        return facts.joined(separator: " ")
    }
}

private extension MapDefinition {
    var supportedMissions: [MissionKind] { MissionKind.allCases.filter(supportsMission) }
}

@MainActor
final class NativeBriefingPanel: NSPanel {
    let briefingView: NativeBriefingView
    init(draft: NativeBriefingDraft, interactionLabel: String, gadgetLabel: String = "B") {
        briefingView = NativeBriefingView(draft: draft, interactionLabel: interactionLabel, gadgetLabel: gadgetLabel)
        super.init(contentRect: NSRect(origin: .zero, size: NativeBriefingView.size), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Einsatzbriefing"; contentView = briefingView; initialFirstResponder = briefingView.mapChoice
    }
}
