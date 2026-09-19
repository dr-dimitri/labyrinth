import AppKit
import BlacksiteCore

/// Draw the real minimum-size briefing without opening a window or synthesizing
/// input. This checks static layout; it does not claim a native interaction test.
@MainActor
enum NativeBriefingCheck {
    static func selectedMap(arguments: [String]) throws -> MapDefinition {
        guard let index = arguments.firstIndex(of: "--map") else { return .blacksite }
        guard index + 1 < arguments.count else {
            throw NSError(domain: "Blacksite.BriefingCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "--map benötigt eine Karten-ID."])
        }
        let id = arguments[index + 1]
        if let map = PublishedMapRegistry.map(id: id) { return map }
        // Explicit prepublication layout diagnostic, never a menu entry.
        if id == "nebelwacht" { return .nebelwacht }
        if id == "sundkai" { return .sundkai }
        throw NativeRunConfigurationError.unavailableMap(id)
    }
    static func makePNG(output: URL, loadout: LoadoutDefinition = .init(camouflage: .mineral), map: MapDefinition = .blacksite, seed: UInt64 = 1745) throws -> [String: Any] {
        let view = NativeBriefingView(draft: NativeBriefingDraft(map: map,
            mission: .operation, difficulty: .normal, camouflage: loadout.camouflage, operatorClass: loadout.operatorClass, seed: seed), maps: [map])
        var result = try snapshot(view: view, output: output)
        result.merge(["operatorClass": loadout.operatorClass.rawValue, "mapID": view.draft.map.id, "mission": view.draft.mission.rawValue,
                      "seed": String(seed), "variant": view.draft.resolvedVariant?.id ?? "unavailable",
                      "conditions": view.draft.resolvedVariant?.conditions ?? [],
                      "accessibilitySummary": view.mapView.accessibilitySummary,
                      "scope": "static AppKit briefing layout; no window interaction"]) { _, new in new }
        return result
    }
    static func snapshot(view: NSView, output: URL) throws -> [String: Any] {
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "Blacksite.BriefingCheck", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AppKit konnte das Briefing-Bild nicht anlegen."])
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            context.cgContext.setBlendMode(.destinationOver)
            context.cgContext.fill(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Blacksite.BriefingCheck", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Das Briefing-Bild konnte nicht als PNG gespeichert werden."])
        }
        try png.write(to: output, options: .atomic)
        return ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]
    }
}
