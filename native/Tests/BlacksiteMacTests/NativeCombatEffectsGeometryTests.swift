import Foundation
import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeCombatEffectsGeometryTests {
    @Test func surfaceProjectionUsesTheOutermostVisibleStrip() throws {
        let body = CombatSurfaceBox(minimum: SIMD3(-1,0,-1), maximum: SIMD3(1,2,1))
        let strip = CombatSurfaceBox(minimum: SIMD3(-0.15,0.25,1), maximum: SIMD3(0.15,1.75,1.08))
        let point = SIMD3<Float>(0,1,1)
        for boxes in [[body,strip],[strip,body]] {
            let hit = try #require(NativeCombatEffects.projectSurface(at: point, normal: SIMD3(0,0,1), radius: 0.05, boxes: boxes))
            #expect(simd_distance(hit.position, SIMD3(0,1,1.08)) < 0.000001)
            #expect(abs(hit.radius - 0.05) < 0.000001)
        }
    }

    @Test func negativeFaceProjectionIgnoresLaterallyUnrelatedGeometry() throws {
        let body = CombatSurfaceBox(minimum: SIMD3(-1,0,-1), maximum: SIMD3(1,2,1))
        let strip = CombatSurfaceBox(minimum: SIMD3(-1.1,0.5,-0.2), maximum: SIMD3(-1,1.5,0.2))
        // This projects farther toward -X, but is not under the hit in Z.
        let unrelated = CombatSurfaceBox(minimum: SIMD3(-2,0.5,0.5), maximum: SIMD3(-1.5,1.5,0.8))
        let hit = try #require(NativeCombatEffects.projectSurface(at: SIMD3(-1,1,0), normal: SIMD3(-1,0,0), radius: 0.04, boxes: [unrelated,body,strip]))
        #expect(simd_distance(hit.position, SIMD3(-1.1,1,0)) < 0.000001)
        #expect(abs(hit.radius - 0.04) < 0.000001)
    }

    @Test func edgeProjectionKeepsRotatedDecalsInsideTheLargestCoplanarFace() throws {
        let roof = CombatSurfaceBox(minimum: SIMD3(-1,0,-1), maximum: SIMD3(1,2,1))
        let small = CombatSurfaceBox(minimum: SIMD3(0.97,1.95,-0.1), maximum: SIMD3(1,2,0.1))
        let point = SIMD3<Float>(0.98,2,0)
        for boxes in [[small,roof],[roof,small]] {
            let hit = try #require(NativeCombatEffects.projectSurface(at: point, normal: SIMD3(0,1,0), radius: 0.1, boxes: boxes))
            #expect(hit.position == point)
            #expect(abs(hit.radius - 0.02 * 0.68) < 0.000001)
            for angle: Float in [0, .pi/8, .pi/4, .pi/2] {
                let u = SIMD3<Float>(cos(angle),0,sin(angle)) * hit.radius
                let v = SIMD3<Float>(-sin(angle),0,cos(angle)) * hit.radius
                for a: Float in [-1,1] { for b: Float in [-1,1] {
                    let corner = hit.position + u*a + v*b
                    #expect(corner.x >= roof.minimum.x && corner.x <= roof.maximum.x)
                    #expect(corner.z >= roof.minimum.z && corner.z <= roof.maximum.z)
                } }
            }
        }
        let edge = try #require(NativeCombatEffects.projectSurface(at: SIMD3(1,2,0), normal: SIMD3(0,1,0), radius: 0.1, boxes: [roof]))
        #expect(edge.radius == 0)
    }

    @Test func missingOutwardFacesAndInvalidQueriesDoNotCreateAProjection() {
        let behind = CombatSurfaceBox(minimum: SIMD3(-1,0,-1), maximum: SIMD3(1,2,0.9))
        let point = SIMD3<Float>(0,1,1), normal = SIMD3<Float>(0,0,1)
        #expect(NativeCombatEffects.projectSurface(at: point, normal: normal, radius: 0.05, boxes: []) == nil)
        #expect(NativeCombatEffects.projectSurface(at: point, normal: normal, radius: 0.05, boxes: [behind]) == nil)
        let front = CombatSurfaceBox(minimum: SIMD3(-1,0,-1), maximum: SIMD3(1,2,1.1))
        #expect(NativeCombatEffects.projectSurface(at: SIMD3(.nan,1,1), normal: normal, radius: 0.05, boxes: [front]) == nil)
        #expect(NativeCombatEffects.projectSurface(at: point, normal: .zero, radius: 0.05, boxes: [front]) == nil)
        #expect(NativeCombatEffects.projectSurface(at: point, normal: simd_normalize(SIMD3(1,1,0)), radius: 0.05, boxes: [front]) == nil)
        for radius: Float in [0, -1, .nan, .infinity] {
            #expect(NativeCombatEffects.projectSurface(at: point, normal: normal, radius: radius, boxes: [front]) == nil)
        }
    }

    @Test func particleSupportPlaneMatchesTheActualTerrainTriangle() {
        let terrain = TerrainProfile.battlefield
        let surface = SIMD3<Float>(13.24,terrain.height(x:13.24,z:27.22),27.22)
        let point = surface + SIMD3(0,0.4,0)
        let plane = NativeCombatEffects.supportPlane(at: point, terrain: terrain, obstacles: [])
        let normal = SIMD3(plane.x,plane.y,plane.z)
        #expect(simd_distance(normal, terrain.normal(x:point.x,z:point.z)) < 0.000001)
        #expect(abs(simd_dot(plane, SIMD4(surface,1))) < 0.00001)
        #expect(abs(simd_dot(plane, SIMD4(point,1)) - 0.4*normal.y) < 0.00001)
        let neighbour = SIMD3<Float>(13.29,terrain.height(x:13.29,z:27.27),27.27)
        #expect(abs(simd_dot(plane, SIMD4(neighbour,1))) < 0.00001)
    }

    @Test func particleSupportUsesTheHighestIntactRoofBelowIt() {
        let roof = Obstacle(id: 3, kind: .container, position: SIMD3(15,0.825,-5), size: SIMD3(11,3.1,3.6))
        let lower = Obstacle(id: 91, kind: .crate, position: SIMD3(15,0.825,-5), size: SIMD3(2,1.5,2))
        let point = SIMD3<Float>(15,4.2,-5)
        for boxes in [[roof,lower],[lower,roof]] {
            let plane = NativeCombatEffects.supportPlane(at: point, terrain: .battlefield, obstacles: boxes)
            #expect(simd_distance(plane, SIMD4(0,1,0,-3.925)) < 0.000001)
            #expect(abs(simd_dot(plane, SIMD4(point,1)) - 0.275) < 0.000001)
        }
    }

    @Test func aRoofAboveOrBesideTheParticleCannotBecomeItsSupport() {
        let terrain = TerrainProfile.battlefield
        let roof = Obstacle(id: 3, kind: .container, position: SIMD3(15,0.825,-5), size: SIMD3(11,3.1,3.6))
        for point in [SIMD3<Float>(15,2,-5),SIMD3<Float>(22,8,-5)] {
            let withRoof = NativeCombatEffects.supportPlane(at: point, terrain: terrain, obstacles: [roof])
            let ground = NativeCombatEffects.supportPlane(at: point, terrain: terrain, obstacles: [])
            #expect(withRoof == ground)
        }
    }

    @Test func destroyedCoverImmediatelyRevealsTheTerrainSupportPlane() {
        var roof = Obstacle(id: 3, kind: .container, position: SIMD3(15,0.825,-5), size: SIMD3(11,3.1,3.6))
        let point = SIMD3<Float>(15,4.2,-5), terrain = TerrainProfile.battlefield
        let intact = NativeCombatEffects.supportPlane(at: point, terrain: terrain, obstacles: [roof])
        roof.destroyed = true
        let destroyed = NativeCombatEffects.supportPlane(at: point, terrain: terrain, obstacles: [roof])
        let ground = NativeCombatEffects.supportPlane(at: point, terrain: terrain, obstacles: [])
        #expect(destroyed == ground)
        #expect(abs(intact.w - destroyed.w) > 3)
    }
}
