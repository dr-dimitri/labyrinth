import simd

public struct LevelPlacementWarning: Equatable, Sendable {
    public let id: String
    public let message: String
    public let position: LevelVector
}

extension LevelDocument {
    public func placementWarnings() throws -> [LevelPlacementWarning] {
        let terrain = try terrainProfile()
        var result: [LevelPlacementWarning] = []
        for object in objects {
            guard let item = LevelObjectCatalog.item(id: object.catalogID) else { continue }
            var size = item.size * object.scale.value
            if !object.quarterTurns.isMultiple(of: 2) { let width = size.x; size.x = size.z; size.z = width }
            let x = object.position.x,z = object.position.z
            let base = object.position.y + (object.heightMode == .ground ? terrain.height(x: x,z: z) : 0)
            var messages: [String] = []
            if x-size.x/2 < Float(bounds.x) || x+size.x/2 > Float(bounds.x+bounds.width) || z-size.z/2 < Float(bounds.z) || z+size.z/2 > Float(bounds.z+bounds.depth) { messages.append("ragt über den Kartenrand") }
            let centerHeight = terrain.height(x: x,z: z)
            if base > centerHeight+0.1 { messages.append("schwebt über dem Gelände") }
            if base < centerHeight-0.1 { messages.append("ist teilweise im Gelände versenkt") }
            let cornerHeights = [-1 as Float,1].flatMap { xx in [-1 as Float,1].map { zz in terrain.height(x: x+xx*size.x/2,z: z+zz*size.z/2) } }
            if cornerHeights.contains(where: { abs($0-centerHeight)>0.5 }) { messages.append("steht auf stark unebenem Gelände; Fundament prüfen") }
            for message in messages { result.append(LevelPlacementWarning(id: object.id,message: item.name + " " + message,position: object.position)) }
        }
        return result
    }
}
