import Foundation
import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeMapGeometryTests {
    @Test func originalTerrainRasterRetainsItsExactRowsAndCollisionDiagonal() {
        let expected = Array(stride(from: Float(-220), to: -48, by: 4))
            + Array(stride(from: Float(-48), through: 48, by: 1))
            + Array(stride(from: Float(52), through: 220, by: 4))
        let axis = NativeMapGeometry.axis(minimum:-220,maximum:220,denseMinimum:-48,denseMaximum:48)
        #expect(axis == expected)
        let vertices = NativeMapGeometry.vertices(map:.blacksite)
        #expect(vertices.count == (expected.count-1)*(expected.count-1)*6)
        // This nonplanar arena cell distinguishes the collision's B-C diagonal
        // from the visually similar but physically incorrect A-D diagonal.
        let triangles = vertices.filter { $0.position.x >= 13 && $0.position.x <= 14 && $0.position.z >= 24 && $0.position.z <= 25 }
        #expect(!triangles.isEmpty)
        for vertex in triangles {
            #expect(abs(vertex.position.y-TerrainProfile.battlefield.height(x:vertex.position.x,z:vertex.position.z)) < 0.00001)
        }
        let row = expected.firstIndex(of:24)!, column = expected.firstIndex(of:13)!
        let start = (row*(expected.count-1)+column)*6
        #expect(Array(vertices[start..<(start+6)]).map { SIMD2($0.position.x,$0.position.z) } == [SIMD2(13,24),SIMD2(13,25),SIMD2(14,24),SIMD2(14,24),SIMD2(13,25),SIMD2(14,25)])
    }

    @Test func translatedElevatedMapHasOnlyItsOwnGroundAndIntegerFineCells() {
        let map = MapDefinition.testRange
        let vertices = NativeMapGeometry.vertices(map:map)
        #expect(vertices.allSatisfy { $0.position.x >= 90 && $0.position.x <= 130 && $0.position.z >= 190 && $0.position.z <= 242 && $0.position.y > 17 })
        #expect(vertices.allSatisfy { abs($0.position.y-map.terrain.height(x:$0.position.x,z:$0.position.z)) < 0.00001 })
        let fine = NativeMapGeometry.axis(minimum:90,maximum:130,denseMinimum:96,denseMaximum:124).filter { $0 >= 98 && $0 <= 122 }
        #expect(fine == Array(stride(from:Float(98),through:122,by:1)))
        #expect(map.scenery.trees.isEmpty && map.scenery.fences.isEmpty && map.scenery.signs.isEmpty)
        #expect(map.scenery.terrainAppearance.regions.isEmpty)
        #expect(map.groundedSupportSurfaces.allSatisfy { $0.position.x > 90 && $0.position.z > 190 && $0.position.y > 17 })
    }

    @Test func activeResourcesDoNotRequestAnotherMapsForestOrSky() {
        let original = MapDefinition.blacksite.resources, foreign = MapDefinition.testRange.resources
        #expect(original.texturePaths.count == 29)
        #expect(foreign.texturePaths.count < original.texturePaths.count)
        #expect(!foreign.texturePaths.values.contains { $0.contains("pine/") || $0.contains("forest-bark/") || $0.contains("asphalt/") || $0.contains("environment/") })
        // A foreign playable map must still render actual soldiers, not just guns.
        #expect(foreign.soldierAsset != nil)
        #expect(foreign.textureCrops.isEmpty)
        #expect(original.textureCrops.keys.sorted() == [9,20,21,22])
        #expect(original.textureCrops.values.allSatisfy { $0 == SIMD4(0,0,0.25,0.5) })
        #expect(foreign.texturePaths.keys.allSatisfy { (0..<31).contains($0) && $0 != 10 && $0 != 24 })
    }

    @Test func authoredSignsStayAttachedToTheMatchingMapOwner() {
        let map = MapDefinition.blacksite
        #expect(map.scenery.signs.filter { $0.ownerID != nil }.count == 6)
        for sign in map.scenery.signs {
            if let owner=sign.ownerID { #expect(map.obstacles.contains { $0.id==owner }) }
        }
        #expect(MapDefinition.testRange.scenery.boxes.allSatisfy { $0.ownerID == nil })
        #expect(map.environment.shadowExtent == 65)
        #expect(map.environment.shadowTarget == .zero)
    }
}
