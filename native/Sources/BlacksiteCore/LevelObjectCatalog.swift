import Foundation
import simd

public enum LevelCatalogCategory: String, CaseIterable, Sendable {
    case buildings = "Gebäude", nature = "Natur", infrastructure = "Infrastruktur", props = "Ausstattung"
}
public struct LevelCatalogPart: Sendable {
    public let center: SIMD3<Float>, size: SIMD3<Float>, color: SIMD3<Float>
    public let kind: ObstacleKind
    public let solid: Bool, destructible: Bool
    public init(_ center: SIMD3<Float>,_ size: SIMD3<Float>,_ color: SIMD3<Float>,kind: ObstacleKind = .bunker,solid: Bool = true,destructible: Bool = false) {
        self.center = center; self.size = size; self.color = color; self.kind = kind; self.solid = solid; self.destructible = destructible
    }
}
public struct LevelCatalogItem: Sendable {
    public let id: String, name: String
    public let category: LevelCatalogCategory
    public let kind: ObstacleKind
    public let size: SIMD3<Float>
    public let parts: [LevelCatalogPart]
    public let guidance: String
    public let minimumScale: Float
    public init(id: String,name: String,category: LevelCatalogCategory,size: SIMD3<Float>,parts: [LevelCatalogPart],guidance: String,minimumScale: Float = 0.25) {
        self.id = id; self.name = name; self.category = category; self.size = size; self.parts = parts
        self.kind = parts.first?.kind ?? .bunker; self.guidance = guidance; self.minimumScale = minimumScale
    }
}
public struct LevelPlacedPart: Sendable {
    public let id: Int, objectID: String
    public let center: SIMD3<Float>, size: SIMD3<Float>, color: SIMD3<Float>
    public let kind: ObstacleKind
    public let solid: Bool, destructible: Bool
}
public enum LevelObjectCatalog {
    private static let wood = SIMD3<Float>(0.48,0.32,0.19), stone = SIMD3<Float>(0.52,0.54,0.51)
    private static let metal = SIMD3<Float>(0.29,0.39,0.40), green = SIMD3<Float>(0.25,0.43,0.18)
    private static func part(_ x: Float,_ y: Float,_ z: Float,_ w: Float,_ h: Float,_ d: Float,_ color: SIMD3<Float> = stone,kind: ObstacleKind = .bunker,solid: Bool = true,breakable: Bool = false) -> LevelCatalogPart {
        LevelCatalogPart(SIMD3(x,y,z),SIMD3(w,h,d),color,kind: kind,solid: solid,destructible: breakable)
    }
    private static func room(_ w: Float,_ h: Float,_ d: Float,_ color: SIMD3<Float>,open: Bool = false) -> [LevelCatalogPart] {
        var parts = [part(-w/2+0.2,h/2,0,0.4,h,d,color),part(w/2-0.2,h/2,0,0.4,h,d,color),part(0,h/2,-d/2+0.2,w,h,0.4,color),part(0,h+0.15,0,w,0.3,d,color)]
        if !open {
            parts += [part(-w/4-0.75,h/2,d/2-0.2,w/2-1.5,h,0.4,color),part(w/4+0.75,h/2,d/2-0.2,w/2-1.5,h,0.4,color)]
        }
        return parts
    }
    public static let items: [LevelCatalogItem] = {
        var result: [LevelCatalogItem] = []
        func add(_ id: String,_ name: String,_ category: LevelCatalogCategory,_ parts: [LevelCatalogPart],_ guidance: String = "Feste Kollision; nicht zerstörbar.", minimumScale: Float = 0.25) {
            var extent = SIMD3<Float>(repeating: 0)
            for part in parts { extent = simd_max(extent,SIMD3(abs(part.center.x)+part.size.x/2,part.center.y+part.size.y/2,abs(part.center.z)+part.size.z/2)) }
            result.append(LevelCatalogItem(id: id,name: name,category: category,size: SIMD3(extent.x*2,extent.y,extent.z*2),parts: parts,guidance: guidance,minimumScale: minimumScale))
        }
        // Preserve the four IDs and dimensions already used by format-1 documents.
        add("core.crate","Holzkiste",.props,[part(0,0.6,0,1.2,1.2,1.2,wood,kind: .crate,breakable: true)],"Holzdeckung; zerstörbar.")
        add("core.barrier","Betonbarriere",.infrastructure,[part(0,0.65,0,3,1.3,0.6)],"Betondeckung; fest.")
        add("core.container","Container",.infrastructure,[part(0,1.3,0,6,2.6,2.5,metal,kind: .container,breakable: true)],"Geschlossene Deckung; zerstörbar.")
        add("core.block","Massiver Baublock",.infrastructure,[part(0,1.5,0,3,3,3)])
        add("building.hut","Hütte",.buildings,room(5,2.8,5,wood),"Begehbar: 3 m breiter Eingang, drei feste Wände und Dach.",minimumScale: 1)
        add("building.house","Wohnhaus",.buildings,room(7,3.2,6,stone)+[part(0,3.65,0,4,0.6,6,wood)],"Begehbar: 3 m Eingang. Gestuftes Dach ist fest.",minimumScale: 1)
        add("building.warehouse","Lagerhalle",.buildings,room(10,4,8,metal,open: true),"Begehbar: gesamte Front offen; feste Wände und Dach.",minimumScale: 1)
        add("building.workshop","Werkstatt",.buildings,room(8,3,6,stone,open: true)+[part(-2,0.5,-1,2,1,1,metal)],"Begehbar: offene Werkstatt mit fester Werkbank.",minimumScale: 1)
        add("building.bunker","Bunker",.buildings,room(8,2.5,7,stone)+[part(0,3,0,8,0.7,7)],"Begehbar: 3 m Eingang; dickes festes Dach.",minimumScale: 1)
        add("building.tower","Beobachtungsturm",.buildings,[part(-1.7,2.5,-1.7,0.5,5,0.5,metal),part(1.7,2.5,-1.7,0.5,5,0.5,metal),part(-1.7,2.5,1.7,0.5,5,0.5,metal),part(1.7,2.5,1.7,0.5,5,0.5,metal),part(0,5,0,4,0.4,4),part(0,6.8,0,4.5,0.3,4.5,metal)],"Unterbau durchgehbar. Oberes Deck ohne Zugang: dekorativ.",minimumScale: 1)
        add("building.hangar","Hangar",.buildings,room(12,5,10,metal,open: true)+[part(0,5.7,0,7,1.1,10,metal)],"Begehbar: große offene Front, festes Stufendach.",minimumScale: 1)
        add("building.greenhouse","Pflanzenhaus",.buildings,room(6,2.8,8,green,open: true)+[part(-1.8,0.35,0,1,0.7,5,wood),part(1.8,0.35,0,1,0.7,5,wood)],"Begehbar zwischen festen Pflanzkästen; offene Front.",minimumScale: 1)
        add("building.office","Containerbüro",.buildings,room(7,2.7,4,metal)+[part(-1.8,0.5,-0.8,2,1,1,wood)],"Begehbar: Eingang 3 m, innen fester Tisch.",minimumScale: 1)
        add("building.shelter","Unterstand",.buildings,[part(-2.5,1.5,-1.5,0.3,3,0.3,wood),part(2.5,1.5,-1.5,0.3,3,0.3,wood),part(-2.5,1.5,1.5,0.3,3,0.3,wood),part(2.5,1.5,1.5,0.3,3,0.3,wood),part(0,3.2,0,6,0.4,4,wood)],"Begehbar: vier offene Seiten und festes Dach.",minimumScale: 1)
        add("nature.pine","Kiefer",.nature,[part(0,2.5,0,0.5,5,0.5,wood),part(0,3,0,3.4,1,3.4,green,solid: false),part(0,4,0,2.4,1,2.4,green,solid: false),part(0,5,0,1.2,1.5,1.2,green,solid: false)],"Stamm kollidiert; Krone dekorativ und durchlässig.")
        add("nature.spruce","Fichte",.nature,[part(0,3,0,0.4,6,0.4,wood),part(0,2,0,2.8,1,2.8,green,solid: false),part(0,3.3,0,2.2,1.3,2.2,green,solid: false),part(0,4.6,0,1.5,1.3,1.5,green,solid: false),part(0,5.8,0,0.7,1.2,0.7,green,solid: false)],"Fester Stamm; schmale gestufte Schmuckkrone.")
        add("nature.oak","Eiche",.nature,[part(0,2,0,0.9,4,0.9,wood),part(-1,4,0,3,2,3,green,solid: false),part(1,4.5,0,3,2.4,3,green,solid: false)],"Breite Krone dekorativ; Stamm fest.")
        add("nature.birch","Birke",.nature,[part(0,2.5,0,0.3,5,0.3,SIMD3(0.8,0.8,0.7)),part(0,4,0,1.8,3,1.5,green,solid: false)],"Dünner fester Stamm; Krone durchlässig.")
        add("nature.bush","Breiter Busch",.nature,[part(0,0.5,0,2,1,1.4,green,solid: false),part(0,1,0,1.2,0.6,1,green,solid: false)],"Dekoration ohne Kollision/Sichtschutz; dafür Vegetationswerkzeug nutzen.")
        add("nature.reeds","Schilfbüschel",.nature,(0..<5).map { part(Float($0-2)*0.22,0.8,0,0.08,1.6+Float($0%2)*0.3,0.1,green,solid: false) },"Dekoratives Schilf; keine Kollision.")
        add("nature.boulder","Großer Fels",.nature,[part(0,0.8,0,3.8,1.6,2.8),part(0.2,1.8,0,2.7,0.8,2)],"Feste gestufte Felsdeckung.")
        add("nature.rocks","Felsgruppe",.nature,[part(-1,0.6,0,1.8,1.2,1.6),part(0.8,0.9,0.4,1.5,1.8,1.4),part(0,0.35,-1,1.3,0.7,1.2)],"Drei feste Felsen mit getrennten Trefferflächen.")
        add("nature.log","Baumstamm",.nature,[part(0,0.35,0,4,0.7,0.7,wood),part(0.8,0.65,0.4,0.4,0.5,1,wood)],"Fester liegender Stamm mit Ast; übersteigbar.")
        add("nature.stump","Baumstumpf",.nature,[part(0,0.4,0,1.1,0.8,1.1,wood),part(0,0.15,0,1.8,0.3,1.5,wood)],"Fester Stumpf mit Wurzelansatz.")
        add("infra.wall","Mauersegment",.infrastructure,[part(0,1.2,0,5,2.4,0.4),part(0,2.5,0,5.2,0.2,0.6)])
        add("infra.fence","Holzzaun",.infrastructure,[part(-2,0.9,0,0.2,1.8,0.2,wood),part(2,0.9,0,0.2,1.8,0.2,wood),part(0,0.6,0,4,0.2,0.15,wood),part(0,1.3,0,4,0.2,0.15,wood)],"Feste Pfosten und Querlatten; Zwischenräume bleiben durchlässig.")
        add("infra.gate","Offener Torbogen",.infrastructure,[part(-2.5,2,0,0.5,4,0.7),part(2.5,2,0,0.5,4,0.7),part(0,4,0,5.5,0.5,0.7)],"Offener fester Torbogen, kein schaltbares Tor.",minimumScale: 1)
        add("infra.steps","Treppenrampe",.infrastructure,(0..<6).map { let h = Float($0+1)*0.25; return part(0,h/2,Float($0)*0.7-1.75,3,h,0.7) },"Sechs feste Stufen, insgesamt 1,5 m hoch.",minimumScale: 1)
        add("infra.bridge","Niedrige Brücke",.infrastructure,[part(0,0.2,0,3,0.4,7,wood),part(-1.5,0.8,0,0.2,1.6,7,wood),part(1.5,0.8,0,0.2,1.6,7,wood)],"Festes 40-cm-Deck mit Seitenbrüstungen; Enden offen.",minimumScale: 1)
        add("infra.barricade","Kreuzbarrikade",.infrastructure,[part(0,0.6,0,3.5,1.2,0.5,metal),part(0,0.6,0,0.5,1.2,2,metal)])
        add("infra.sandbags","Sandsackstellung",.infrastructure,[part(0,0.3,0,4,0.6,1),part(0,0.9,0,3.4,0.6,0.9),part(-1.8,0.5,1,0.8,1,2)])
        add("infra.bollards","Pollerreihe",.infrastructure,[-1 as Float,0,1].map { part($0,0.65,0,0.3,1.3,0.3,metal) })
        add("infra.platform","Podest",.infrastructure,[part(0,0.2,0,4,0.4,4),part(0,0.45,-1,3,0.5,2)],"Festes niedriges Stufenpodest.")
        add("infra.pipe","Rohrbogen",.infrastructure,[part(-1.5,1.5,0,0.5,3,0.5,metal),part(1.5,1.5,0,0.5,3,0.5,metal),part(0,3,0,3.5,0.5,0.5,metal)],"Feste Leitungsstützen, freier Durchgang.",minimumScale: 1)
        add("prop.barrel","Fass",.props,[part(0,0.6,0,0.8,1.2,0.8,metal,kind: .barrel,breakable: true)],"Explosives Fass; zerstörbar.")
        add("prop.pallet","Palette",.props,[part(0,0.15,0,1.2,0.3,1,wood,kind: .crate,breakable: true)],"Niedrige Holzdeckung; zerstörbar.")
        add("prop.lamp","Leuchtenmast",.props,[part(0,1.8,0,0.2,3.6,0.2,metal),part(0.45,3.5,0,1.1,0.2,0.2,metal),part(0.8,3.35,0,0.5,0.2,0.4,SIMD3(0.95,0.88,0.55),solid: false)],"Fester Mast; Leuchtkörper dekorativ, keine dynamische Lichtquelle.")
        add("prop.antenna","Antenne",.props,[part(0,2,0,0.2,4,0.2,metal),part(0,3,0,2,0.1,0.1,metal),part(0,3.7,0,1.2,0.1,0.1,metal)])
        add("prop.generator","Generator",.props,[part(0,0.7,0,2,1.4,1.2,metal,kind: .container,breakable: true),part(0.6,1.7,0,0.2,0.6,0.2,metal)],"Dekorative Maschine, Gehäuse zerstörbar; kein schaltbarer Generator.")
        add("prop.tank","Wassertank",.props,[part(0,0.35,0,2.5,0.7,2.5),part(0,1.7,0,2,2,2,metal),part(0,2.9,0,0.6,0.4,0.6,metal)])
        add("prop.bench","Sitzbank",.props,[part(-0.8,0.25,0,0.2,0.5,0.6,metal),part(0.8,0.25,0,0.2,0.5,0.6,metal),part(0,0.55,0,2,0.15,0.7,wood),part(0,1,-0.3,2,0.8,0.15,wood)])
        add("prop.table","Arbeitstisch",.props,[part(-0.8,0.5,0,0.2,1,0.7,metal),part(0.8,0.5,0,0.2,1,0.7,metal),part(0,1,0,2,0.15,1,wood)])
        add("prop.sign","Hinweisschild",.props,[part(0,0.8,0,0.15,1.6,0.15,metal),part(0,1.6,0,1.5,0.8,0.1,SIMD3(0.8,0.65,0.2))],"Festes Schild ohne Missionsfunktion.")
        add("prop.cable","Kabeltrommel",.props,[part(-0.5,0.7,0,0.15,1.4,1.4,wood),part(0.5,0.7,0,0.15,1.4,1.4,wood),part(0,0.7,0,1,0.9,0.9,metal)])
        add("device.generator","Schaltbarer Generator",.props,[part(0,0.7,0,1.6,1.4,1,metal,kind: .container)],"Interaktiv mit E: Versorgung ein-/ausschalten. Tore im Eigenschaftenfeld verknüpfen.",minimumScale: 1)
        add("device.lift-gate","Bedienbares Hubtor",.infrastructure,[part(0,1.3,0,3,2.6,0.25,metal,kind: .container)],"Interaktiv mit E, optional Generatorversorgung. Nur 0°/180°, Maßstab 1–1,5.",minimumScale: 1)
        return result
    }()
    private static let index = Dictionary(uniqueKeysWithValues: items.map { ($0.id,$0) })
    public static func item(id: String) -> LevelCatalogItem? { index[id] }
    public static func placedParts(for object: LevelObject, terrain: TerrainProfile) -> [LevelPlacedPart] {
        guard let item = item(id: object.catalogID) else { return [] }
        let base = object.position.value + SIMD3(0,object.heightMode == .ground ? terrain.height(x: object.position.x,z: object.position.z) : 0,0)
        return item.parts.enumerated().map { index,part in
            var center = part.center*object.scale.value, size = part.size*object.scale.value
            for _ in 0..<object.quarterTurns { center = SIMD3(center.z,center.y,-center.x) }
            if !object.quarterTurns.isMultiple(of: 2) { let x = size.x; size.x = size.z; size.z = x }
            let key = index == 0 ? object.id : "part:\(object.id):\(index)"
            return LevelPlacedPart(id: LevelDocument.obstacleID(key),objectID: object.id,center: base+center,size: size,color: part.color,kind: part.kind,solid: part.solid,destructible: part.destructible)
        }
    }
}
