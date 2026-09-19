import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct FootContactMathTests {
    private func sole(x: Float = 0, y: Float = 0.001, z: Float = 0) -> SoldierSolePoints {
        SoldierSolePoints(heelLeft: SIMD3(x-0.06,y,z-0.12), heelRight: SIMD3(x+0.06,y,z-0.12),
                          toeLeft: SIMD3(x-0.06,y,z+0.12), toeRight: SIMD3(x+0.06,y,z+0.12))
    }

    @Test func contactsUseTheVisibleAsphaltSurfaceAndMatchedGPUSize() throws {
        let road = Obstacle(id: 1, kind: .bunker, position: .zero, size: SIMD3(12,0.015,91))
        let patch = try #require(FootContactMath.patch(sole: sole(), grounded: true, terrain: .flat, obstacles: [road]))
        #expect(abs(patch.centerOpacity.y-0.0175)<0.00001)
        #expect(patch.centerOpacity.w>0.4 && patch.centerOpacity.w<=0.42)
        #expect(MemoryLayout<FootContactPatch>.stride==48)
    }

    @Test func jumpingAndLiftedSwingFeetHaveNoGroundBlob() {
        #expect(FootContactMath.patch(sole: sole(), grounded: false, terrain: .flat, obstacles: []) == nil)
        #expect(FootContactMath.patch(sole: sole(y: 0.16), grounded: true, terrain: .flat, obstacles: []) == nil)
    }

    @Test func roofContactsDisappearWhenTheirSupportIsDestroyed() throws {
        var roof = Obstacle(id: 2, kind: .container, position: .zero, size: SIMD3(2,2,2))
        let patch = try #require(FootContactMath.patch(sole: sole(y: 2.001), grounded: true, terrain: .flat, obstacles: [roof]))
        #expect(abs(patch.centerOpacity.y-2.0025)<0.00001)
        roof.destroyed = true
        #expect(FootContactMath.patch(sole: sole(y: 2.001), grounded: true, terrain: .flat, obstacles: [roof]) == nil)
    }

    @Test func paddedContactExtentCannotHangOverARoofEdge() {
        let roof = Obstacle(id: 3, kind: .container, position: .zero, size: SIMD3(2,2,2))
        // All sole samples lie on the roof, but the soft outer footprint would
        // extend past x=1. A patch here would incorrectly darken the distance.
        #expect(FootContactMath.patch(sole: sole(x: 0.9,y: 2.001), grounded: true, terrain: .flat, obstacles: [roof]) == nil)
    }

    @Test func contactPlaneFollowsTheActualHillTriangle() throws {
        let terrain = TerrainProfile.battlefield, x: Float = 13.25, z: Float = 26.25
        func point(_ dx: Float,_ dz: Float) -> SIMD3<Float> {
            SIMD3(x+dx,terrain.height(x: x+dx,z: z+dz)+0.001,z+dz)
        }
        let foot = SoldierSolePoints(heelLeft: point(-0.06,-0.12),heelRight: point(0.06,-0.12),
                                    toeLeft: point(-0.06,0.12),toeRight: point(0.06,0.12))
        let patch = try #require(FootContactMath.patch(sole: foot,grounded: true,terrain: terrain,obstacles: []))
        let normal = terrain.normal(x: x,z: z)
        let u = SIMD3(patch.axisU.x,patch.axisU.y,patch.axisU.z), v = SIMD3(patch.axisV.x,patch.axisV.y,patch.axisV.z)
        #expect(abs(simd_dot(normal,u))<0.00001)
        #expect(abs(simd_dot(normal,v))<0.00001)
        let position = SIMD3(patch.centerOpacity.x,patch.centerOpacity.y,patch.centerOpacity.z)
        #expect(abs(simd_dot(position-SIMD3(x,terrain.height(x: x,z: z),z),normal)-0.0025)<0.00001)
    }
}
