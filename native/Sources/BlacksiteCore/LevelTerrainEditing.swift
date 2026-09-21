import Foundation
import simd

public enum LevelLandscape: String, CaseIterable, Sendable { case plain = "Ebene", hills = "Hügelland", forest = "Wald", coast = "Küste", rocks = "Felsgelände" }
public enum LevelTerrainBrush: String, CaseIterable, Sendable { case raise = "Heben", lower = "Senken", smooth = "Glätten", flatten = "Einebnen" }
public enum LevelResizeAnchor: String, CaseIterable, Sendable { case origin = "Nordwest-Ecke", center = "Mitte" }

public struct LevelWater: Codable, Equatable, Sendable {
    public var id: String
    public var x: Int, z: Int, width: Int, depth: Int
    public var surfaceHeight: Float
    public init(id: String = UUID().uuidString, x: Int, z: Int, width: Int, depth: Int, surfaceHeight: Float) {
        self.id = id; self.x = x; self.z = z; self.width = width; self.depth = depth; self.surfaceHeight = surfaceHeight
    }
}

extension LevelDocument {
    public func terrainProfile() throws -> TerrainProfile {
        try validateDraft()
        return .heightField(try TerrainHeightField(origin: SIMD2(Float(bounds.x),Float(bounds.z)), width: bounds.width+1,depth: bounds.depth+1,samples: terrain.heights))
    }
    public mutating func resize(width: Int, depth: Int, anchor: LevelResizeAnchor) throws {
        guard (12...128).contains(width), (12...128).contains(depth) else { throw LevelDocumentError("Breite und Tiefe müssen zwischen 12 und 128 Metern liegen.") }
        let old = try terrainProfile()
        if anchor == .center { bounds.x += (bounds.width-width)/2; bounds.z += (bounds.depth-depth)/2 }
        bounds.width = width; bounds.depth = depth
        terrain.heights = (0...depth).flatMap { z in (0...width).map { x in old.height(x: Float(bounds.x+x),z: Float(bounds.z+z)) } }
        // Objects, markers, surfaces and water remain authored in world coordinates.
    }
    public func outsideContentCount(width: Int, depth: Int, anchor: LevelResizeAnchor) -> Int {
        guard (12...128).contains(width), (12...128).contains(depth) else { return 0 }
        let x = bounds.x + (anchor == .center ? (bounds.width-width)/2 : 0)
        let z = bounds.z + (anchor == .center ? (bounds.depth-depth)/2 : 0)
        func outside(_ xx: Float, _ zz: Float, _ w: Float = 0, _ d: Float = 0) -> Bool {
            xx < Float(x) || zz < Float(z) || xx+w > Float(x+width) || zz+d > Float(z+depth)
        }
        return objects.filter { object in
            var size = (LevelObjectCatalog.item(id: object.catalogID)?.size ?? .zero) * object.scale.value
            if !object.quarterTurns.isMultiple(of: 2) { let a = size.x; size.x = size.z; size.z = a }
            return outside(object.position.x-size.x/2,object.position.z-size.z/2,size.x,size.z)
        }.count + markers.filter { outside($0.position.x,$0.position.z) }.count
            + environment.surfaces.filter { outside($0.x,$0.z,$0.width,$0.depth) }.count
            + environment.water.filter { outside(Float($0.x),Float($0.z),Float($0.width),Float($0.depth)) }.count
    }
    public mutating func generate(_ landscape: LevelLandscape, seed: UInt64) {
        terrain.seed = seed
        let phase = Float(seed % 10_007) * 0.01
        terrain.heights = (0...bounds.depth).flatMap { z in (0...bounds.width).map { x in
            let a = Float(x), b = Float(z)
            switch landscape {
            case .plain, .coast: return Float(0)
            case .hills: return 2 * sin(a*0.12+phase) * cos(b*0.11+phase)
            case .forest: return 0.8 * sin(a*0.14+phase) * cos(b*0.13)
            case .rocks: return 2.5 * abs(sin(a*0.14+phase)*cos(b*0.14))
            }
        } }
        environment.vegetationDensity = landscape == .forest ? 0.8 : 0
        environment.water = []
        environment.surfaces = []
        if landscape == .coast {
            environment.water = [LevelWater(x: bounds.x,z: bounds.z,width: 3,depth: bounds.depth,surfaceHeight: 0.3)]
        }
    }
    public mutating func brush(_ kind: LevelTerrainBrush, at point: SIMD2<Float>, radius: Float, strength: Float, target: Float) throws {
        guard point.x.isFinite,point.y.isFinite,radius.isFinite,(0.5...16).contains(radius),strength.isFinite,(0.01...2).contains(strength),target.isFinite,abs(target)<=1000 else {
            throw LevelDocumentError("Pinsel: Radius 0,5–16 m, Stärke 0,01–2 m und endliche Zielhöhe erforderlich.")
        }
        let original = terrain.heights, stride = bounds.width+1
        for z in 0...bounds.depth { for x in 0...bounds.width {
            let r = simd_distance(SIMD2(Float(bounds.x+x),Float(bounds.z+z)),point)
            guard r < radius else { continue }
            let index = z*stride+x, weight = min(1,(1-r/radius)*strength)
            let value: Float
            switch kind {
            case .raise: value = original[index] + strength*(1-r/radius)
            case .lower: value = original[index] - strength*(1-r/radius)
            case .flatten: value = original[index] + (target-original[index])*weight
            case .smooth:
                var total: Float = 0; var count: Float = 0
                for zz in max(0,z-1)...min(bounds.depth,z+1) { for xx in max(0,x-1)...min(bounds.width,x+1) { total += original[zz*stride+xx]; count += 1 } }
                value = original[index] + (total/count-original[index])*weight
            }
            terrain.heights[index] = min(1000,max(-1000,value))
        } }
    }
    /// Water creates an explicit shallow basin. Subsequent brushes can make it
    /// temporarily invalid; play validation explains this without losing a draft.
    public mutating func addWater(x: Int,z: Int,width: Int,depth: Int,surfaceHeight: Float) throws {
        guard environment.water.count < 4, width > 0, depth > 0, width <= 128, depth <= 128, width*depth <= 500,
              x >= bounds.x, z >= bounds.z, x <= bounds.x+bounds.width, z <= bounds.z+bounds.depth, x+width <= bounds.x+bounds.width,z+depth <= bounds.z+bounds.depth,
              surfaceHeight.isFinite,abs(surfaceHeight) < 999 else { throw LevelDocumentError("Flachwasser: maximal vier Flächen à 500 m² innerhalb der Karte.") }
        guard !environment.water.contains(where: { x < $0.x+$0.width && x+width > $0.x && z < $0.z+$0.depth && z+depth > $0.z }) else { throw LevelDocumentError("Wasserflächen dürfen sich nicht überlappen.") }
        for zz in z...z+depth { for xx in x...x+width { terrain.heights[(zz-bounds.z)*(bounds.width+1)+xx-bounds.x] = surfaceHeight-0.3 } }
        environment.water.append(LevelWater(x: x,z: z,width: width,depth: depth,surfaceHeight: surfaceHeight))
    }
}
