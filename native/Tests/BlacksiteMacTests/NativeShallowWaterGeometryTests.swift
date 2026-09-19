import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeShallowWaterGeometryTests {
    @Test func shoreMeshPreservesRealTriangleDepthAndClipsFractionalBounds() throws {
        let terrain=TerrainProfile.heightField(try TerrainHeightField(origin:.zero,width:3,depth:3,
            samples:[0,0.2,0.4,0,0.2,0.4,0,0.2,0.4]))
        let zone=MapShallowWaterZone(id:1,minimum:SIMD2(0.25,0.25),maximum:SIMD2(1.75,1.75),surfaceHeight:0.25)
        let vertices=NativeShallowWaterGeometry.vertices(zones:[zone],terrain:terrain)
        #expect(!vertices.isEmpty)
        for vertex in vertices {
            #expect(vertex.position.y==0.25 && vertex.normal==SIMD3(0,1,0))
            #expect(vertex.position.x>=0.24999 && vertex.position.x<=1.25001)
            #expect(vertex.position.z>=0.24999 && vertex.position.z<=1.75001)
            #expect(abs(vertex.uv.x-(0.25-terrain.height(x:vertex.position.x,z:vertex.position.z)))<0.00001)
        }
        for index in stride(from:0,to:vertices.count,by:3) {
            let a=vertices[index].position,b=vertices[index+1].position,c=vertices[index+2].position
            #expect(simd_cross(b-a,c-a).y>0.000001)
        }
        let dry=MapShallowWaterZone(id:2,minimum:.zero,maximum:SIMD2(1,1),surfaceHeight:0)
        #expect(NativeShallowWaterGeometry.vertices(zones:[dry],terrain:.flat).isEmpty)
    }

    @Test func transparencyUsesActualRayCrossingsAndExcludesTheSurfaceItself() {
        let zones=[MapShallowWaterZone(id:1,minimum:SIMD2(-2,-2),maximum:SIMD2(2,2),surfaceHeight:1),
                   MapShallowWaterZone(id:2,minimum:SIMD2(-2,3),maximum:SIMD2(2,5),surfaceHeight:1)]
        #expect(NativeShallowWaterGeometry.layerCount(zones:zones)==1)
        // Target is outside the pool, but the eye ray crosses its real surface.
        #expect(NativeShallowWaterGeometry.crossings(from:SIMD3(0,3,-3),to:SIMD3(0,-1,4),zones:zones)==1)
        #expect(NativeShallowWaterGeometry.crossings(from:SIMD3(0,3,-3),to:SIMD3(0,1,0),zones:zones)==0)
        #expect(NativeShallowWaterGeometry.crossings(from:SIMD3(0,3,-3),to:SIMD3(0,2,0),zones:zones)==0)
        #expect(NativeShallowWaterGeometry.crossings(from:SIMD3(4,3,-3),to:SIMD3(4,-1,4),zones:zones)==0)
        #expect(MemoryLayout<GPUShallowWater>.stride==144 && MemoryLayout<GPUShallowWaterZone>.stride==32)
        #expect(MemoryLayout<GPUShallowWater>.offset(of:\.fourth)==112)
        let adjacent=MapShallowWaterZone(id:3,minimum:SIMD2(2,-2),maximum:SIMD2(4,2),surfaceHeight:1)
        #expect(NativeShallowWaterGeometry.crossings(from:SIMD3(2,3,0),to:SIMD3(2,0,0),zones:zones+[adjacent])==1)
    }

    @Test func broadleafMeshUsesItsOwnIslandAndFiniteCurvedOutwardGeometry() {
        let vertices=NativeMangroveGeometry.leafVertices()
        #expect(vertices.count==36)
        for vertex in vertices {
            #expect(vertex.uv.x>=NativeMangroveGeometry.atlasMinimum.x && vertex.uv.x<=NativeMangroveGeometry.atlasMaximum.x)
            #expect(vertex.uv.y>=NativeMangroveGeometry.atlasMinimum.y-0.00001 && vertex.uv.y<=NativeMangroveGeometry.atlasMaximum.y)
            #expect(abs(simd_length(vertex.normal)-1)<0.00001)
        }
        for index in stride(from:0,to:vertices.count,by:3) {
            let a=vertices[index],b=vertices[index+1],c=vertices[index+2]
            #expect(simd_dot(simd_cross(b.position-a.position,c.position-a.position),a.normal+b.normal+c.normal)>0)
        }
        #expect(NativeMangroveGeometry.clusterVertices().count==8*vertices.count)
    }

    @Test func relayPanelTouchesTheActualOwnerAndCompletionDoesNotChangeSolidShape() {
        let owner=Obstacle(id:2830,kind:.container,position:SIMD3(-24.8,1,17.2),size:SIMD3(0.7,1.1,0.45))
        func target(_ completed:Bool)->OperationTargetSnapshot {
            OperationTargetSnapshot(id:"relay",title:"Relais",stageID:"relays",kind:.relayGroup,position:SIMD3(-26,1,18),
                ownerObstacleID:owner.id,completed:completed,available:!completed)
        }
        let ready=NativeRelayVisual.parts(target:target(false),owner:owner),done=NativeRelayVisual.parts(target:target(true),owner:owner)
        #expect(ready.count==4 && done.count==4)
        #expect(ready.filter(\.castsShadow).count==1 && done.filter(\.castsShadow).count==1)
        #expect(ready[0].transform==done[0].transform)
        #expect(abs(ready[0].transform.columns.3.x-(owner.position.x-owner.size.x*0.5-0.01))<0.0001)
        #expect(ready[1].color != done[1].color)
    }

    @Test func harborArtKeepsAuditedSolidsAndExactDrySupportTops() throws {
        let map=try SundkaiDefinition.make()
        for body in map.scenery.boxes where body.replacesOwnerBody {
            let owner=try #require(map.obstacles.first { $0.id==body.ownerID })
            #expect(body.size==owner.size && body.position==SIMD3(0,owner.size.y*0.5,0))
            #expect(body.castsShadow)
        }
        let decks=map.scenery.boxes.filter { $0.material.w==38 }
        #expect(decks.count==3)
        for deck in decks {
            let support=try #require(map.groundedSupportSurfaces.first { $0.position.z==deck.position.z })
            let top=map.grounded(deck.position).y+deck.size.y*0.5
            #expect(abs(top-support.position.y-support.size.y)<0.00001)
            #expect(deck.size.x==support.size.x && deck.size.z==support.size.z)
        }
        #expect(map.scenery.trees.count==19 && map.scenery.trees.allSatisfy { $0.kind == .mangrove })
        #expect(map.environment.vegetationZones.allSatisfy { $0.kind == .tallGrass })
        #expect(NativeShallowWaterGeometry.vertices(zones:map.environment.shallowWaterZones,terrain:map.terrain).count<=2*20*20*6)
        #expect(map.resources.texturePaths[0]==map.resources.texturePaths[14])
        #expect(map.resources.texturePaths[1]==map.resources.texturePaths[15])
        #expect(map.resources.textureCrops[9]==nil && map.resources.textureCrops[21]==nil)
        #expect(!map.scenery.fences.isEmpty)
        for fence in map.scenery.fences {
            let alongSide=abs(fence.start.x)==36 && fence.end.x==fence.start.x
            let alongEnd=abs(fence.start.z)==40 && fence.end.z==fence.start.z
            #expect(alongSide || alongEnd)
            if fence.start.z == -40 && alongEnd { #expect(fence.end.x <= -4 || fence.start.x>=4) }
            if fence.start.z == 40 && alongEnd { #expect(fence.end.x<=27 || fence.start.x>=35) }
        }
    }
}
