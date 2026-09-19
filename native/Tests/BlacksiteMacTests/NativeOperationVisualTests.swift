import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeOperationVisualTests {
    @Test func bothAuthoredExitsUseRealGroundAndOnlyPhysicalMarkerShadows() {
        let map=MapDefinition.blacksite
        var props=0,segments=0,shadowCasters=0
        for exit in BlacksiteOperation.definition.extractions {
            let position=map.grounded(exit.position)
            let geometry=NativeOperationVisual.geometry(position:position,radius:exit.radius,routeKind:exit.routeKind,
                terrain:map.terrain,supportSurfaces:map.groundedSupportSurfaces)
            #expect(geometry.props.count==6 && geometry.ring.count==32)
            #expect(geometry.ring.allSatisfy { !$0.castsShadow })
            props+=geometry.props.count;segments+=geometry.ring.count
            shadowCasters+=geometry.props.filter(\.castsShadow).count
            for part in geometry.ring {
                let center=SIMD3(part.transform.columns.3.x,part.transform.columns.3.y,part.transform.columns.3.z)
                let radial=simd_length(SIMD2(center.x-position.x,center.z-position.z))
                #expect(abs(radial-exit.radius)<0.02)
                #expect(center.y>=map.terrain.height(x:center.x,z:center.z))
                if exit.id=="north" { #expect(center.y>0.015 && center.y<0.04) } // Actual asphalt surface.
                #expect(simd_determinant(simd_float3x3(columns:(
                    SIMD3(part.transform.columns.0.x,part.transform.columns.0.y,part.transform.columns.0.z),
                    SIMD3(part.transform.columns.1.x,part.transform.columns.1.y,part.transform.columns.1.z),
                    SIMD3(part.transform.columns.2.x,part.transform.columns.2.y,part.transform.columns.2.z))))>0)
            }
        }
        #expect(props==12 && segments==64 && shadowCasters==8)
    }

    @Test func markersFollowElevatedForeignTerrainAndAnActualSupportSurface() {
        let map=MapDefinition.testRange,position=map.grounded(map.extraction)
        let geometry=NativeOperationVisual.geometry(position:position,radius:2.5,routeKind:.sheltered,
            terrain:map.terrain,supportSurfaces:map.groundedSupportSurfaces)
        #expect(!geometry.props.isEmpty && !geometry.ring.isEmpty)
        for part in geometry.props+geometry.ring {
            let p=part.transform.columns.3
            #expect(p.x>90 && p.z>190 && p.y>17)
        }
        let support=Obstacle(id:902,kind:.barrier,position:SIMD3(110,22,202),size:SIMD3(8,0.2,8))
        let raised=NativeOperationVisual.geometry(position:position,radius:2.5,routeKind:.sheltered,
            terrain:map.terrain,supportSurfaces:[support])
        #expect(raised.ring.allSatisfy { abs($0.transform.columns.3.y-22.216)<0.0001 })
        #expect(raised.props.allSatisfy { $0.transform.columns.3.y>22.2 })
        #expect(raised.props[0].transform.columns.1.x==0 && raised.props[0].transform.columns.1.z==0)
    }

    @Test func onlyTheQualifyingExitDisplaysItsHoldProgress() {
        func exit(_ kind:OperationRouteKind,active:Bool,blocked:Bool=false,unlocked:Bool=true)->ExtractionSnapshot {
            ExtractionSnapshot(id:"test",title:"Ausgang",detail:"",position:.zero,radius:2.5,requiredProgress:3,
                progress:1.5,routeKind:kind,unlocked:unlocked,blocked:blocked,active:active)
        }
        let current=exit(.exposed,active:true),other=exit(.sheltered,active:false)
        let filled=NativeOperationVisual.ringAppearance(exit:current,segment:0)
        let remaining=NativeOperationVisual.ringAppearance(exit:current,segment:31)
        #expect(filled.emission>remaining.emission && filled.color.y>filled.color.x)
        #expect(NativeOperationVisual.ringAppearance(exit:other,segment:0).color ==
                NativeOperationVisual.ringAppearance(exit:other,segment:31).color)
        #expect(NativeOperationVisual.ringAppearance(exit:exit(.exposed,active:false),segment:0).color !=
                NativeOperationVisual.ringAppearance(exit:other,segment:0).color)
        #expect(NativeOperationVisual.ringAppearance(exit:exit(.exposed,active:true,blocked:true),segment:0).emission<filled.emission)
        #expect(NativeOperationVisual.ringAppearance(exit:exit(.exposed,active:false,unlocked:false),segment:0).emission==0)
    }

    @Test func timerAndPresentationStateNeverMoveOrChangeTheExtractionBoundary() {
        let map=MapDefinition.blacksite,position=map.grounded(SIMD3(33,0,-37))
        let exposed=NativeOperationVisual.geometry(position:position,radius:2.5,routeKind:.exposed,
            terrain:map.terrain,supportSurfaces:map.groundedSupportSurfaces)
        let sheltered=NativeOperationVisual.geometry(position:position,radius:2.5,routeKind:.sheltered,
            terrain:map.terrain,supportSurfaces:map.groundedSupportSurfaces)
        for (a,b) in zip(exposed.props+exposed.ring,sheltered.props+sheltered.ring) {
            #expect(a.transform==b.transform && a.castsShadow==b.castsShadow)
        }
    }
}
