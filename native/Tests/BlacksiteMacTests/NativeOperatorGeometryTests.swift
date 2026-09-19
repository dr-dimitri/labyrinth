import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeOperatorGeometryTests {
    @Test func attachedChargeContactsItsRealSurfaceAndOnlyPhysicalPartsCastShadows() {
        let hit=SIMD3<Float>(110,21,207)
        for normal in [SIMD3<Float>(1,0,0),SIMD3(-1,0,0),SIMD3(0,0,1),SIMD3(0,0,-1)] {
            let charge=BreachChargeState(id:1,ownerObstacleID:902,position:hit+normal*0.05,normal:normal,createdAt:0)
            let parts=NativeOperatorGeometry.charge(charge)
            #expect(parts.count<=NativeOperatorGeometry.maximumChargeParts)
            #expect(parts[0].castsShadow && parts[1].castsShadow && parts[3].castsShadow)
            #expect(parts.filter { $0.material.z>0 }.allSatisfy { !$0.castsShadow })
            let points=parts.flatMap(Self.boxCorners)
            let closest=points.map { simd_dot($0-hit,normal) }.min()!
            #expect(abs(closest)<0.0001)
            #expect(points.allSatisfy { simd_dot($0-hit,normal) >= -0.0001 })
            #expect(points.allSatisfy { simd_distance($0,charge.position)<0.09 })
        }
    }

    @Test func fallenChargeUsesTheCoreRestCentreWithoutAFloatingPadOrHiddenOffset() {
        let floor:Float=18.4
        let charge=BreachChargeState(id:2,ownerObstacleID:903,position:SIMD3(105,floor+0.031,203),normal:SIMD3(0,1,0),createdAt:0,attached:false)
        let parts=NativeOperatorGeometry.charge(charge),points=parts.flatMap(Self.boxCorners)
        #expect(abs(points.map(\.y).min()!-(floor+0.001))<0.0001)
        #expect(parts.filter(\.castsShadow).count==2)
        #expect(points.allSatisfy { $0.y>=floor && simd_distance($0,charge.position)<0.09 })
    }

    @Test func reconMarkersStayOnTheirHistoricalPointAndNeverCastShadows() {
        let mark=ReconMark(id:7,targetID:912,position:SIMD3(110,21,207),createdAt:4)
        for eye in [SIMD3<Float>(100,21,207),SIMD3(115,23,211),SIMD3(110,25,207)] {
            let parts=NativeOperatorGeometry.marker(mark,eye:eye,time:5)
            #expect(parts.count==4 && parts.allSatisfy { !$0.castsShadow })
            let center=parts.reduce(SIMD3<Float>.zero) { sum,part in
                sum+SIMD3(part.transform.columns.3.x,part.transform.columns.3.y,part.transform.columns.3.z)
            }/Float(parts.count)
            #expect(simd_distance(center,mark.position)<0.0001)
        }
        #expect(NativeOperatorGeometry.marker(mark,eye:SIMD3(100,21,207),time:mark.expiresAt).isEmpty)
    }

    @Test func reconMarkerAngularSizeRemainsReadableAndWorldSizeIsBounded() {
        let mark=ReconMark(id:8,targetID:913,position:.zero,createdAt:0)
        var widths:[Float]=[]
        for distance:Float in [1,15,70,140] {
            let parts=NativeOperatorGeometry.marker(mark,eye:SIMD3(0,0,distance),time:1)
            let column=parts[0].transform.columns.0
            let thickness=simd_length(SIMD3(column.x,column.y,column.z))
            #expect(abs(thickness-max(0.012,min(70,distance)*0.002))<0.00001)
            let points=parts.flatMap(Self.boxCorners)
            widths.append(points.map(\.x).max()!-points.map(\.x).min()!)
            #expect(parts.allSatisfy { !$0.castsShadow })
        }
        #expect(abs(widths[1]/15-widths[2]/70)<0.00001)
        #expect(abs(widths[2]-widths[3])<0.00001)
    }

    private static func boxCorners(_ part:SoldierPart)->[SIMD3<Float>] {
        var result:[SIMD3<Float>]=[]
        for x:Float in [-0.5,0.5] { for y:Float in [-0.5,0.5] { for z:Float in [-0.5,0.5] {
            let p=part.transform*SIMD4(x,y,z,1);result.append(SIMD3(p.x,p.y,p.z))
        } } }
        return result
    }
}
