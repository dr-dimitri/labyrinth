import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeCoastalGeometryTests {
    @Test func radomeIsAnOutwardFacingHemisphereWithARealFlatBase() {
        let vertices=NativeCoastalGeometry.domeVertices()
        #expect(vertices.count<6000 && !vertices.isEmpty)
        #expect(vertices.contains { abs($0.position.y)<0.00001 })
        #expect(vertices.contains { $0.position.y>0.9999 })
        for vertex in vertices {
            #expect(vertex.position.y >= -0.00001 && vertex.position.y<=1.00001)
            if vertex.normal.y < -0.9 {
                #expect(vertex.position.y==0 && simd_length(vertex.position)<=1.0001)
            } else { #expect(abs(simd_length(vertex.position)-1)<0.0001) }
            #expect(abs(simd_length(vertex.normal)-1)<0.0001)
        }
        for index in stride(from:0,to:vertices.count,by:3) {
            let a=vertices[index].position,b=vertices[index+1].position,c=vertices[index+2].position
            let cross=simd_cross(b-a,c-a)
            #expect(simd_length_squared(cross)>1e-10)
            #expect(simd_dot(cross,vertices[index].normal+vertices[index+1].normal+vertices[index+2].normal)>0)
        }
        let bottom=vertices.filter { $0.normal.y < -0.9 }
        #expect(bottom.count==48*3 && bottom.contains { $0.position == .zero })
    }

    @Test func decorativeSeaKeepsItsBoundedEnvelopeAndNeverCrossesPlayableGround() throws {
        let map=try NebelwachtDefinition.make(),water=map.scenery.boxes.filter { $0.mesh == .water }
        #expect(water.count==2)
        for box in water {
            #expect(!box.castsShadow && box.ownerID==nil && box.material.w==NativeCoastalGeometry.waterMaterial)
            let low=box.position-box.size*0.5,high=box.position+box.size*0.5
            #expect(low.x>=map.maximum.x || high.x<=map.minimum.x || low.z>=map.maximum.z || high.z<=map.minimum.z)
        }
        let vertices=NativeCoastalGeometry.waterVertices()
        #expect(vertices.count==64*64*6)
        #expect(vertices.allSatisfy { $0.position.y==0 && abs($0.position.x)<=0.5 && abs($0.position.z)<=0.5 })
        for time:Float in [0,1.3,5,23.75] { for x:Float in [-150,0,47,128,255] { for z:Float in [-256,-53,1,17,191] {
            #expect(abs(NativeCoastalGeometry.waterHeight(x:x,z:z,time:time))<NativeCoastalGeometry.waterMaximumDisplacement)
        } } }
    }

    @Test func realRadomeSupportAndReplacementBodiesRetainAuthoritativeColliders() throws {
        let map=try NebelwachtDefinition.make()
        let dome=try #require(map.scenery.boxes.first { $0.mesh == .dome })
        let source=try #require(map.obstacles.first { $0.id==dome.ownerID })
        let base=map.grounded(source.position)+dome.position
        #expect(abs(base.y-11.6)<0.0001 && dome.castsShadow)
        #expect(dome.position.y==source.size.y)
        // The platform's highest ordinary jump cannot reach the dome's base.
        #expect(base.y>8+1.36+1.72)
        for body in map.scenery.boxes where body.replacesOwnerBody {
            let owner=try #require(map.obstacles.first { $0.id==body.ownerID })
            #expect(body.mesh == .box && body.size==owner.size && body.position==SIMD3(0,owner.size.y*0.5,0))
            #expect(body.castsShadow)
        }
        #expect(map.scenery.boxes.count<160)
    }

    @Test func materialPacketPreservesLegacyDefaultsAndTheExactMetalHeaderOffsets() {
        var appearance=MapTerrainAppearance()
        #expect(simd_length(appearance.materialScales-SIMD4<Float>(0.76923,0.5,0.42017,0.5))<0.000003)
        #expect(appearance.surfaceWetness==0)
        appearance.materialScales=SIMD4(0.5,1/1.55,0.5,0.5);appearance.surfaceWetness=0.74
        appearance.regions=[MapGroundAppearanceRegion(shape:.ellipse,center:SIMD2(12,14),radii:SIMD2(5,7),inner:SIMD2(0.2,0.3),outer:SIMD2(0.8,0.9))]
        let packet=NativeMapAppearance.fields(appearance)
        #expect(packet.count*MemoryLayout<SIMD4<Float>>.stride==NativeMapAppearance.byteCount)
        #expect(packet[1]==SIMD4(1,0.74,0,0) && packet[2]==appearance.materialScales)
        #expect(packet[3]==SIMD4(12,14,5,7))
        #expect(packet.dropFirst(7).allSatisfy { $0 == .zero })
    }

    @Test func beaconOnlyLightsDuringTheSharedWarningIntervalAndNeverAddsOpaqueSmoke() {
        let position=SIMD3<Float>(4.9,6,6)
        let warning=SmokeWarning(emitterID:2760,kind:.spray,position:SIMD3(0,6,6),startsAt:7,cycle:0,beginsAt:4)
        let housing=NativeWeatherGeometry.housing(position:position)
        #expect(housing.count==NativeWeatherGeometry.housingPartCount && housing.allSatisfy(\.castsShadow))
        for time in [3.99,4,5.4,6.999,7,8] {
            let lenses=NativeWeatherGeometry.lenses(position:position,warning:warning,time:time)
            #expect(lenses.count==NativeWeatherGeometry.lensPartCount && lenses.allSatisfy { !$0.castsShadow })
            #expect(lenses.allSatisfy { ($0.material.z>0)==(time>=4 && time<7) })
        }
        #expect(NativeWeatherGeometry.lenses(position:position,warning:nil,time:5).allSatisfy { $0.material.z==0 })
    }
}
