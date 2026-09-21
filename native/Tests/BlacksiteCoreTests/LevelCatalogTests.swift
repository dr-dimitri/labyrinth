import Foundation
import Testing
import simd
@testable import BlacksiteCore

struct LevelCatalogTests {
    @Test func catalogHasDistinctGeometryAndValidStableReferencesInEveryCategory() throws {
        #expect(Set(LevelObjectCatalog.items.map(\.id)).count == LevelObjectCatalog.items.count)
        for category in LevelCatalogCategory.allCases {
            let items = LevelObjectCatalog.items.filter { $0.category == category }
            #expect(items.count >= 10)
            let geometries = items.map { item in item.parts.map { "\($0.center)/\($0.size)/\($0.solid)" }.joined(separator: ";") }
            #expect(Set(geometries).count == items.count)
        }
        for item in LevelObjectCatalog.items {
            var doc = LevelDocument(); doc.objects = [LevelObject(id: "instance",catalogID: item.id)]
            let roundTrip = try LevelDocument.decode(doc.encoded())
            let map = try roundTrip.makeMap(purpose: .preview)
            #expect(map.obstacles.count == item.parts.filter(\.solid).count)
            #expect(map.scenery.boxes.count == item.parts.count)
            for part in LevelObjectCatalog.placedParts(for: doc.objects[0],terrain: map.terrain) where part.solid {
                let collider = try #require(map.obstacles.first { $0.id == part.id })
                #expect(collider.size == part.size)
                #expect(map.grounded(collider.position)+SIMD3(0,collider.size.y/2,0) == part.center)
            }
        }
    }
    @Test func buildingsKeepRealEntrancesAfterRotationAndGrounding() throws {
        for item in LevelObjectCatalog.items where item.category == .buildings {
            var doc = LevelDocument(bounds: .init(x: -32,z: -32,width: 64,depth: 64))
            var building = LevelObject(id: "building",catalogID: item.id); building.quarterTurns = 1
            doc.objects = [building]
            let map = try doc.makeMap(purpose: .preview)
            let simulation = CombatSimulation(map: map)
            // +Z door rotated +90° faces +X. Footprints are exact colliders,
            // so a visible entrance must connect an outside point to the room.
            #expect(simulation.hasReachableRoute(from: SIMD3(12,0,0),to: SIMD3(0,0,0)),"\(item.name) has blocked entrance")
            doc.objects[0].scale = LevelVector(0.25,0.25,0.25)
            #expect(throws: LevelDocumentError.self) { try doc.encoded() }
        }
    }
    @Test func authoredIDsCannotAliasCompositePartKeys() throws {
        var doc = LevelDocument()
        doc.objects = [LevelObject(id: "tower",catalogID: "building.tower"),LevelObject(id: "tower.part.1",catalogID: "core.crate",position: .init(8,0,0))]
        let map = try doc.makeMap(purpose: .preview)
        #expect(Set(map.obstacles.map(\.id)).count == map.obstacles.count)
    }
    @Test func compositePartsRetainBaseHeightAndIdentityOnUnevenTerrain() throws {
        var doc = LevelDocument(); doc.generate(.hills,seed: 42)
        var object = LevelObject(id: "tower",catalogID: "building.tower",position: .init(0,1,0))
        object.heightMode = .absolute; object.quarterTurns = 3; object.scale = .init(1.5,1,2)
        doc.objects = [object]
        let map = try doc.makeMap(purpose: .preview), terrain = try doc.terrainProfile()
        for part in LevelObjectCatalog.placedParts(for: object,terrain: terrain) where part.solid {
            let collider = try #require(map.obstacles.first { $0.id == part.id })
            #expect(simd_distance(map.grounded(collider.position)+SIMD3(0,collider.size.y/2,0),part.center)<0.00001)
        }
    }
}
