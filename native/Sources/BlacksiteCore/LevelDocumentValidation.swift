import Foundation
import simd

extension LevelDocument {
    /// Checks storage integrity, not whether this unfinished draft can be played.
    public func validateDraft() throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LevelDocumentError(message) }
        }
        try require(formatVersion == Self.currentVersion, "Level-Formatversion \(formatVersion) wird nicht unterstützt.")
        try require(revision > 0 && revision < Int.max, "Die Levelrevision muss eine positive, gültige Zahl sein.")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120 && description.count <= 4_000,
                    "Das Level benötigt einen Namen mit höchstens 120 und eine Beschreibung mit höchstens 4000 Zeichen.")
        try require((-10_000...10_000).contains(bounds.x) && (-10_000...10_000).contains(bounds.z)
                    && (12...128).contains(bounds.width) && (12...128).contains(bounds.depth),
                    "Die Kartengröße muss 12–128 Meter je Achse betragen; der Ursprung muss zwischen −10000 und 10000 Metern liegen.")
        try require(terrain.heights.count == (bounds.width + 1) * (bounds.depth + 1)
                    && terrain.heights.allSatisfy { $0.isFinite && abs($0) <= 1000 },
                    "Das Gelände benötigt ein vollständiges 1-Meter-Höhenraster mit endlichen Höhen zwischen −1000 und 1000 Metern.")
        try require(resourceSet == "blacksite", "Unbekannter Ressourcenkatalog „\(resourceSet)“.")
        try require(objects.count <= 1000 && groups.count <= 256 && markers.count <= 256 && environment.surfaces.count <= 8,
                    "Zulässig sind höchstens 1000 Objekte, 256 Gruppen, 256 Marker und acht Bodenflächen.")
        var ids = Set<String>()
        func register(_ id: String) throws {
            try require(!id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
            }, "Ungültige ID „\(id)“; erlaubt sind bis zu 128 Bytes aus Buchstaben, Zahlen, Bindestrich, Unterstrich und Punkt.")
            try require(ids.insert(id).inserted, "Die ID „\(id)“ ist mehrfach vergeben.")
        }
        try register(id)
        for group in groups {
            try register(group.id)
            try require(!group.name.isEmpty && group.name.count <= 120, "Gruppe „\(group.id)“ benötigt einen Namen mit höchstens 120 Zeichen.")
        }
        let groupIDs = Set(groups.map(\.id))
        for object in objects {
            try register(object.id)
            try require(LevelObjectCatalog.item(id: object.catalogID) != nil, "Objekt „\(object.id)“: unbekannte Vorlage „\(object.catalogID)“.")
            try require(object.position.isFinite && (0..<3).allSatisfy { abs(object.position.value[$0]) <= 20_000 },
                        "Objekt „\(object.id)“ besitzt eine ungültige Position.")
            try require((0...3).contains(object.quarterTurns) && object.scale.isFinite
                        && (0..<3).allSatisfy { ((LevelObjectCatalog.item(id: object.catalogID)?.minimumScale ?? 0.25)...4).contains(object.scale.value[$0]) },
                        "Objekt „\(object.id)“: erlaubt sind Vierteldrehungen (0–3) und Skalierungen bis 4 (Gebäude und Durchgänge mindestens 1, sonst 0,25).")
            try require(object.groupID.map { groupIDs.contains($0) } ?? true,
                        "Objekt „\(object.id)“ verweist auf die fehlende Gruppe „\(object.groupID ?? "")“.")
        }
        for marker in markers {
            try register(marker.id)
            try require(marker.position.isFinite && (0..<3).allSatisfy { abs(marker.position.value[$0]) <= 20_000 }
                        && marker.yaw.isFinite && marker.radius.isFinite && marker.radius > 0 && marker.radius <= 32,
                        "Marker „\(marker.id)“ enthält eine ungültige Position, Blickrichtung oder einen ungültigen Radius.")
        }
        let environment = environment
        try require(environment.sunDirection.isFinite && simd_length_squared(environment.sunDirection.value).isFinite
                    && simd_length_squared(environment.sunDirection.value) > 0.01
                    && environment.sunIntensity.isFinite && (0...1).contains(environment.sunIntensity)
                    && environment.fogColor.isFinite && (0..<3).allSatisfy { (0...1).contains(environment.fogColor.value[$0]) },
                    "Sonnenrichtung, Lichtstärke oder Nebelfarbe sind ungültig.")
        try require(environment.vegetationDensity.isFinite && (0...1).contains(environment.vegetationDensity) && environment.water.count <= 4,
                    "Vegetationsdichte muss 0–1 betragen; höchstens vier Wasserflächen sind erlaubt.")
        for water in environment.water {
            try register(water.id)
            try require((-10_000...10_000).contains(water.x) && (-10_000...10_000).contains(water.z)
                && (1...128).contains(water.width) && (1...128).contains(water.depth)
                && water.width * water.depth <= 500 && water.surfaceHeight.isFinite && abs(water.surfaceHeight) <= 1000,
                "Wasserfläche benötigt begrenzte ganzzahlige Maße, höchstens 500 m² und eine endliche Höhe.")
        }
        for surface in environment.surfaces {
            try register(surface.id)
            try require([surface.x, surface.z, surface.width, surface.depth].allSatisfy(\.isFinite)
                        && surface.width > 0 && surface.depth > 0
                        && abs(surface.x) <= 20_000 && abs(surface.z) <= 20_000 && surface.width <= 128 && surface.depth <= 128,
                        "Bodenfläche „\(surface.id)“ besitzt ungültige Maße.")
        }
    }
}
