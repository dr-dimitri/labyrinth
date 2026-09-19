import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeVegetationGeometryTests {
    private func map(zones:[EnvironmentZone]) throws -> MapDefinition {
        var environment=MapEnvironmentDefinition();environment.vegetationZones=zones
        return try MapDefinition(id:"vegetation-geometry",displayName:"Vegetation geometry",
            minimum:SIMD3(-40,0,-40),maximum:SIMD3(40,0,40),terrain:.flat,
            playerStart:PlayerState(position:.zero),reinforcementEntries:[SIMD3(0,0,-30)],
            waveStaging:[SIMD3(0,0,-20)],extraction:SIMD3(0,0,-30),
            dataSite:SIMD3(-10,0,0),radioSite:SIMD3(10,0,0),environment:environment)
    }

    @Test func gameplayFoliageIsBoundedDeterministicAndHasNoQualityParameter() {
        let map=MapDefinition.blacksite
        let first=NativeVegetationGeometry.meshes(map:map),second=NativeVegetationGeometry.meshes(map:map)
        #expect(first.count == 5)
        #expect(first.map(\.id) == map.environment.vegetationZones.map(\.id))
        #expect(first.reduce(0) { $0+$1.plantCount } <= NativeVegetationGeometry.maximumPlants)
        #expect(first.reduce(0) { $0+$1.vertices.count } <= NativeVegetationGeometry.maximumVertices)
        for (a,b) in zip(first,second) {
            #expect(a.plantCount>0 && a.plantCount <= NativeVegetationGeometry.maximumPlantsPerZone)
            #expect(a.plantCount == map.environment.vegetationZones.first { $0.id==a.id }?.requiredPlantCount)
            #expect(a.vertices.count == b.vertices.count)
            #expect(zip(a.vertices,b.vertices).allSatisfy { $0.position == $1.position && $0.normal == $1.normal && $0.uv == $1.uv })
        }
    }

    @Test func addingZonesNeverRedistributesAnExistingZonesPlants() throws {
        let original=BlacksiteVegetation.zones[0]
        let extra=(1..<16).map { index in
            EnvironmentZone(id:"extra-\(index)",center:SIMD2(Float(index%4)*7-10,Float(index/4)*7-10),
                radii:SIMD2(1.7,2.7),height:1.2,density:0.7,kind:.brush)
        }
        let single=try #require(NativeVegetationGeometry.meshes(map:map(zones:[original])).first)
        let all=NativeVegetationGeometry.meshes(map:try map(zones:[original]+extra))
        let unchanged=try #require(all.first)
        #expect(all.reduce(0) { $0+$1.plantCount } == EnvironmentZone.maximumTotalPlantCount)
        #expect(single.plantCount == 32 && unchanged.plantCount == single.plantCount)
        #expect(single.vertices.count == unchanged.vertices.count)
        #expect(zip(single.vertices,unchanged.vertices).allSatisfy {
            $0.position == $1.position && $0.normal == $1.normal && $0.uv == $1.uv
        })
    }

    @Test func minimumLargeAndNarrowValidPatchesReceiveTheirFullAreaCount() throws {
        let zones=[
            EnvironmentZone(id:"minimum",center:.zero,radii:SIMD2(0.3,0.3),height:0.25,density:0.6,kind:.tallGrass),
            EnvironmentZone(id:"large",center:SIMD2(10,0),radii:SIMD2(3,4),height:1.2,density:0.7,kind:.brush),
            EnvironmentZone(id:"narrow",center:SIMD2(-10,0),radii:SIMD2(0.3,16),height:0.95,density:0.6,kind:.tallGrass)
        ]
        let meshes=NativeVegetationGeometry.meshes(map:try map(zones:zones))
        for (zone,mesh) in zip(zones,meshes) {
            #expect(mesh.plantCount == zone.requiredPlantCount)
            #expect(!mesh.vertices.isEmpty)
            #expect(mesh.vertices.allSatisfy { zone.footprintWeight(x:$0.position.x,z:$0.position.z)>0 })
        }
    }

    @Test func everyVisiblePlantStaysInItsSharedFootprintAndVerticalLayer() throws {
        let map=MapDefinition.blacksite
        for mesh in NativeVegetationGeometry.meshes(map:map) {
            let zone=try #require(map.environment.vegetationZones.first { $0.id==mesh.id })
            var roots=0,highTips=0,outside=0,invalidHeight=0,invalidNormal=0,windOutside=0
            for vertex in mesh.vertices {
                let p=vertex.position
                let bottom=zone.bottomHeight(x:p.x,z:p.z,terrain:map.terrain)
                let top=zone.topHeight(x:p.x,z:p.z,terrain:map.terrain)
                if zone.footprintWeight(x:p.x,z:p.z)<=0 { outside+=1 }
                if p.y<bottom-0.00001 || p.y>top+0.00001 { invalidHeight+=1 }
                if !vertex.normal.x.isFinite || abs(simd_length(vertex.normal)-1)>=0.0001 { invalidNormal+=1 }
                // The shader's bounded sway also remains inside the simplified
                // footprint. It can never reveal an invisible outside bonus.
                for x:Float in [-0.012,0.012] { for z:Float in [-0.009,0.009] {
                    if zone.footprintWeight(x:p.x+x,z:p.z+z)<=0 { windOutside+=1 }
                } }
                if p.y-bottom < 0.005 { roots+=1 }
                if p.y-bottom > (top-bottom)*0.90 { highTips+=1 }
            }
            #expect(roots>=4)
            #expect(highTips>=4)
            #expect(outside==0 && invalidHeight==0 && invalidNormal==0 && windOutside==0)
        }
    }

    @Test func authoredPatchesDoNotIntersectExistingCoverOrTheCentralRoad() {
        let map=MapDefinition.blacksite
        for zone in map.environment.vegetationZones {
            #expect(zone.minimum.x>6 || zone.maximum.x < -6)
            for cover in map.obstacles {
                let overlapsX=zone.minimum.x < cover.position.x+cover.size.x*0.5 && zone.maximum.x>cover.position.x-cover.size.x*0.5
                let overlapsZ=zone.minimum.z < cover.position.z+cover.size.z*0.5 && zone.maximum.z>cover.position.z-cover.size.z*0.5
                #expect(!(overlapsX && overlapsZ))
            }
        }
    }

    @Test func aMapWithoutGameplayZonesHasNoHiddenPlantGeometry() {
        #expect(NativeVegetationGeometry.meshes(map:.testRange).isEmpty)
    }
}
