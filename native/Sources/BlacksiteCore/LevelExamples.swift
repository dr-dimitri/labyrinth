import Foundation
import simd

/// These recipes use the same authoring operations as the editor. No example
/// depends on manually edited JSON or on an installed asset outside the app.
public enum LevelExample: String, CaseIterable, Sendable {
    case training, outpost, woodland
    public var title: String { switch self { case .training:return "Übungsgelände"; case .outpost:return "Außenposten"; case .woodland:return "Waldgebiet · 500 Objekte" } }
    public func makeDocument() throws -> LevelDocument {
        let size = self == .training ? 32 : self == .outpost ? 64 : 128
        var editor = LevelEditingSession(document: LevelDocument(id:"example."+rawValue,name:title,bounds:.init(x:-size/2,z:-size/2,width:size,depth:size)))
        try editor.edit("Landschaft") { doc in
            doc.generate(self == .woodland ? .forest : .plain,seed:42)
            doc.installGameplayTemplate(self == .training ? .recoverData : .waves)
            for i in doc.markers.indices { doc.markers[i].id = "example.marker."+doc.markers[i].kind.rawValue }
            doc.environment.surfaces = [LevelSurface(id:"ground.grass",x:Float(-size/2),z:Float(-size/2),width:Float(size),depth:Float(size),material:.grass)]
        }
        var number = 0
        func place(_ catalog: String,_ x: Float,_ z: Float,_ turns: Int = 0) throws {
            try Task.checkCancellation(); number += 1
            var object = LevelObject(id:"example.object.\(number)",catalogID:catalog,position:.init(x,0,z)); object.quarterTurns = turns
            try editor.edit("Platzieren") { $0.objects.append(object) }
        }
        if self == .training {
            try place("building.hut",-6,-2)
            try place("core.crate",5,1); try place("core.barrier",5,-3)
            try place("nature.oak",-11,4); try place("prop.barrel",8,3)
        } else if self == .outpost {
            for (id,x,z) in [("building.warehouse",Float(-15),Float(-9)),("building.workshop",Float(15),Float(-9)),("building.hut",Float(-15),Float(12)),("building.office",Float(15),Float(12))] { try place(id,x,z) }
            for x in [-8 as Float,0,8] { try place("core.barrier",x,7); try place("prop.barrel",x,-18) }
            try place("device.generator",-7,-2); let generatorID = editor.document.objects.last!.id
            try place("device.lift-gate",5,-2)
            try editor.edit("Tor verbinden") { $0.objects[$0.objects.count-1].powerSourceID = generatorID }
            try place("prop.lamp",-4,15)
        } else {
            // Reserve the southern band for large buildings and the centre lane
            // plus each gameplay anchor for navigation. The remainder is mixed.
            try place("building.hut",-30,51); try place("building.warehouse",0,51); try place("building.shelter",30,51)
            let mixed = ["nature.pine","nature.spruce","nature.oak","nature.birch","nature.bush","nature.reeds","nature.boulder","nature.rocks","nature.log","nature.stump","prop.barrel","prop.pallet","prop.sign","core.crate","infra.bollards"]
            outer: for row in 0..<23 { for column in 0..<27 {
                let x = -58.5+Float(column)*4.5,z = -58.5+Float(row)*4.5
                if abs(x)<4 { continue }
                if editor.document.markers.contains(where: { simd_distance(SIMD2(x,z),SIMD2($0.position.x,$0.position.z))<6 }) { continue }
                try place(mixed[(row*27+column)%mixed.count],x,z,(row+column)%4)
                if editor.document.objects.count == 500 { break outer }
            } }
        }
        return editor.document
    }
}
