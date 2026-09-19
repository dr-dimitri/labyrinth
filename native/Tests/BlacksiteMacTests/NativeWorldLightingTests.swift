import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeWorldLightingTests {
    @Test func uniformOffsetsAgreeWithTheMetalBlockAndTwoMapBudget() {
        #expect(MemoryLayout<GPUWorldLight>.stride == 128)
        #expect(MemoryLayout<GPUWorldLight>.offset(of: \.matrix) == 0)
        #expect(MemoryLayout<GPUWorldLight>.offset(of: \.positionRange) == 64)
        #expect(MemoryLayout<GPUWorldLight>.offset(of: \.directionOuter) == 80)
        #expect(MemoryLayout<GPUWorldLight>.offset(of: \.colorPower) == 96)
        #expect(MemoryLayout<GPUWorldLight>.offset(of: \.parameters) == 112)
        #expect(MemoryLayout<GPUWorldLighting>.stride == 272)
        #expect(MemoryLayout<GPUWorldLighting>.offset(of: \.first) == 16)
        #expect(MemoryLayout<GPUWorldLighting>.offset(of: \.second) == 144)
        #expect(2 * SpotShadowVolume.resolution * SpotShadowVolume.resolution * 4 == 2 * 1024 * 1024)
    }

    @Test func lampVolumeRetainsCastersBehindTheCameraAndRejectsOutsideItsReach() {
        let light=WorldSpotlightState(id: 1, position: SIMD3(0,5,0), direction: SIMD3(0,0,-1))
        let volume=SpotShadowVolume(light: light)
        // A camera at z=-8 facing -Z cannot see this caster; the lamp still must.
        #expect(volume.intersects(center: SIMD3(0,5,-2), radius: 0.2))
        #expect(!volume.intersects(center: SIMD3(0,5,1), radius: 0.1))
        #expect(!volume.intersects(center: SIMD3(0,5,-18), radius: 0.1))
        #expect(!volume.intersects(center: SIMD3(8,5,-2), radius: 0.1))
        let edge=tan(acos(light.outerCos))*5
        #expect(volume.intersects(center: SIMD3(edge+0.05,5,-5), radius: 0.2))
        #expect(!volume.intersects(center: SIMD3(edge+0.05,5,-5), radius: 0))
    }

    @Test func verticalAndObliqueLampsHaveFiniteMatricesAndCorrectDepthEndpoints() {
        let position=SIMD3<Float>(110,25,214)
        for direction in [SIMD3<Float>(0,-1,0), SIMD3(0,1,0), SIMD3(0.00001,-1,0.00001), SIMD3(1,-0.9,-0.25)] {
            let unit=simd_normalize(direction)
            let light=WorldSpotlightState(id: 1, position: position, direction: unit)
            let volume=SpotShadowVolume(light: light)
            for column in [volume.matrix.columns.0,volume.matrix.columns.1,volume.matrix.columns.2,volume.matrix.columns.3] {
                #expect(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite)
            }
            for (distance,expected) in [(SpotShadowVolume.nearPlane,Float(0)),(light.range,Float(1))] {
                let clip=volume.matrix*SIMD4(position+unit*distance,1)
                #expect(abs(clip.x/clip.w)<0.0005 && abs(clip.y/clip.w)<0.0005)
                #expect(abs(clip.z/clip.w-expected)<0.0005)
            }
            #expect(volume.intersects(center: position+unit*5, radius: 0.01))
        }
    }

    @Test func disabledLampKeepsItsConeButContributesNoRadiance() {
        let a=WorldSpotlightState(id: 8001, position: SIMD3(2,5,7), direction: simd_normalize(SIMD3(1,-1,0)), power: 0.8)
        var b=a;b.enabled=false
        let gpu=GPUWorldLighting(lights:[a,b])
        #expect(gpu.counts.x==2)
        #expect(gpu.first.positionRange==SIMD4(a.position,a.range))
        #expect(gpu.first.directionOuter==SIMD4(a.direction,a.outerCos))
        #expect(gpu.first.parameters.x==a.innerCos)
        #expect(gpu.first.colorPower.w==0.8 && gpu.second.colorPower.w==0)
        #expect(gpu.first.matrix==gpu.second.matrix)
        let empty=GPUWorldLighting(lights:[])
        #expect(empty.counts.x==0 && empty.first.colorPower.w==0 && empty.second.colorPower.w==0)
    }

    @Test func lampTerrainIsAnExactLocalSubsetOfTheVisibleTriangles() {
        let map=MapDefinition.blacksite,full=NativeMapGeometry.vertices(map:map)
        // One fine-grid patch and one crossing the coarse/fine border.
        for center in [SIMD3<Float>(-7.68,5.2,25),SIMD3(47,12,48)] {
            let patch=NativeMapGeometry.shadowPatch(map:map,center:center,range:16)
            #expect(!patch.isEmpty && patch.count<full.count/5 && patch.count%6==0)
            var selected=[SIMD3<Float>]()
            for offset in stride(from:0,to:full.count,by:6) {
                let cell=full[offset..<(offset+6)]
                let xs=cell.map(\.position.x),zs=cell.map(\.position.z)
                if xs.max()!>=center.x-16 && xs.min()!<=center.x+16 && zs.max()!>=center.z-16 && zs.min()!<=center.z+16 {
                    selected.append(contentsOf:cell.map(\.position))
                }
            }
            #expect(patch.map(\.position)==selected)
            #expect(patch.allSatisfy { abs($0.position.y-map.terrain.height(x:$0.position.x,z:$0.position.z))<0.00001 })
        }
    }
}
