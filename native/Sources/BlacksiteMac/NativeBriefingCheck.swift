import AppKit
import BlacksiteCore

/// Draw the real minimum-size briefing without opening a window or synthesizing
/// input. This checks static layout; it does not claim a native interaction test.
@MainActor
enum NativeBriefingCheck {
    static func makePNG(output: URL) throws -> [String: Any] {
        let view = NativeBriefingView(draft: NativeBriefingDraft(map: .blacksite,
            mission: .operation, difficulty: .normal, camouflage: .mineral))
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
        return ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
                "mapID": view.draft.map.id, "mission": view.draft.mission.rawValue,
                "accessibilitySummary": view.mapView.accessibilitySummary,
                "scope": "static AppKit briefing layout; no window interaction"]
    }
}
