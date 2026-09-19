import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeBreachGeometryTests {
    @Test func clearGlassIsOneClosedTwoSidedSurfaceWithoutAnOpaqueShadow() {
        for size in [SIMD3<Float>(0.18,2.8,2.2),SIMD3(2.2,2.8,0.18)] {
            var obstacle=Obstacle(id:902,kind:.glass,position:SIMD3(110,18.4,207),size:size)
            let definition=MapBreachDefinition(ownerObstacleID:902,kind:.glass,visibility:.clear)
            let intact=NativeBreachGeometry.parts(obstacle:obstacle,definition:definition)
            #expect(intact.count==1 && intact[0].mesh==3 && !intact[0].castsShadow)
            #expect(intact[0].material.w==NativeBreachGeometry.clearGlassMaterial && intact[0].material.z==0)
            let bounds=Self.bounds(intact[0],plane:true)
            #expect(abs(bounds.0.y-obstacle.position.y)<0.0001)
            #expect(abs(bounds.1.y-(obstacle.position.y+size.y))<0.0001)
            #expect(abs(max(bounds.1.x-bounds.0.x,bounds.1.z-bounds.0.z)-2.2)<0.0001)
            obstacle.health=17
            let damaged=NativeBreachGeometry.parts(obstacle:obstacle,definition:definition)
            #expect(damaged[0].transform==intact[0].transform && damaged[0].material.z==1 && !damaged[0].castsShadow)
            obstacle.destroyed=true
            #expect(NativeBreachGeometry.parts(obstacle:obstacle,definition:definition).isEmpty)
        }
    }

    @Test func opaqueGlassAndRemovablePanelsMatchTheirColliderThroughDamage() {
        for kind:ObstacleKind in [.glass,.accessPanel] {
            var obstacle=Obstacle(id:91,kind:kind,position:SIMD3(-15.8,1.7,1.5),size:SIMD3(0.18,2.8,2.2))
            let definition=MapBreachDefinition(ownerObstacleID:91,kind:kind == .glass ? .glass:.lightPanel,visibility:.opaque)
            let intact=NativeBreachGeometry.parts(obstacle:obstacle,definition:definition)
            let box=Self.bounds(intact[0],plane:false)
            #expect(simd_distance(box.0,obstacle.position-SIMD3(obstacle.size.x*0.5,0,obstacle.size.z*0.5))<0.0001)
            #expect(simd_distance(box.1,obstacle.position+SIMD3(obstacle.size.x*0.5,obstacle.size.y,obstacle.size.z*0.5))<0.0001)
            #expect(intact[0].castsShadow && intact[0].mesh==0)
            obstacle.health=obstacle.maximumHealth*0.4
            let damaged=NativeBreachGeometry.parts(obstacle:obstacle,definition:definition)
            #expect(intact.count==damaged.count && intact[0].transform==damaged[0].transform)
            #expect(intact[0].material != damaged[0].material)
            obstacle.destroyed=true
            #expect(NativeBreachGeometry.parts(obstacle:obstacle,definition:definition).isEmpty)
        }
    }

    @Test func permanentFrameIsExactlyOneRealCollidableBodyWithoutAFalseOverhang() {
        let map=MapDefinition.blacksite
        let frames=map.breaches.flatMap(\.frameObstacleIDs)
        #expect(frames.count==6)
        for id in frames {
            let authored=map.obstacles.first { $0.id==id }!
            let obstacle=Obstacle(id:id,kind:authored.kind,position:map.grounded(authored.position),size:authored.size)
            let parts=NativeBreachGeometry.frame(obstacle:obstacle)
            #expect(parts.count==1 && parts[0].castsShadow)
            let bounds=Self.bounds(parts[0],plane:false)
            #expect(simd_distance(bounds.0,obstacle.position-SIMD3(obstacle.size.x*0.5,0,obstacle.size.z*0.5))<0.0001)
            #expect(simd_distance(bounds.1,obstacle.position+SIMD3(obstacle.size.x*0.5,obstacle.size.y,obstacle.size.z*0.5))<0.0001)
        }
    }

    @Test func transparentEffectsRemainOnTheCorrectSideOfEveryPane() {
        let depths:[Float]=[15,12,10,10,8,3,-1]
        let cuts:[Float]=[13,10,4]
        let ranges=NativeTransparencyOrder.ranges(sortedDepths:depths,surfaces:cuts)
        #expect(ranges == [0..<1,1..<2,2..<5,5..<7])
        #expect(ranges.flatMap { Array($0) } == Array(depths.indices))
        #expect(NativeTransparencyOrder.ranges(sortedDepths:depths,surfaces:[]) == [0..<7])
        #expect(NativeTransparencyOrder.ranges(sortedDepths:[],surfaces:cuts) == [0..<0,0..<0,0..<0,0..<0])
        #expect(NativeTransparencyOrder.ranges(sortedDepths:[5,4],surfaces:[8,7]) == [0..<0,0..<0,0..<2])
    }

    @Test func unauthoredGlassStaysOpaqueLikeTheCoreVisibilityFallback() {
        let obstacle=Obstacle(id:720,kind:.glass,position:SIMD3(0,0,4),size:SIMD3(2.2,2.8,0.18))
        let parts=NativeBreachGeometry.fallbackParts(obstacle:obstacle)
        #expect(parts.count==1 && parts[0].mesh==0 && parts[0].castsShadow)
        #expect(parts[0].material.w==NativeBreachGeometry.opaqueGlassMaterial)
    }

    private static func bounds(_ part:SoldierPart,plane:Bool)->(SIMD3<Float>,SIMD3<Float>) {
        var low=SIMD3<Float>(repeating:.infinity),high=SIMD3<Float>(repeating:-.infinity)
        for x:Float in [-0.5,0.5] { for y:Float in [-0.5,0.5] { for z:Float in plane ? [0]:[-0.5,0.5] {
            let p=part.transform*SIMD4(x,y,z,1),point=SIMD3(p.x,p.y,p.z)
            low=simd_min(low,point);high=simd_max(high,point)
        } } }
        return(low,high)
    }
}
