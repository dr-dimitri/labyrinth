import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeAlarmGeometryTests {
    @Test func onlyRealReportingStateLightsTheSamePhysicalAttachment() {
        let enemy=EnemyState(id:1,position:SIMD3(110,19,212))
        let idle=NativeAlarmGeometry.reporter(enemy:enemy,progress:nil,radio:false,transmitted:false)
        let local=NativeAlarmGeometry.reporter(enemy:enemy,progress:0.5,radio:false,transmitted:false)
        let radio=NativeAlarmGeometry.reporter(enemy:enemy,progress:0.5,radio:true,transmitted:false)
        #expect(idle.count==NativeAlarmGeometry.reporterPartCount && local.count==idle.count)
        #expect(idle.allSatisfy { $0.material.z==0 })
        #expect(local.last!.material.z>0 && radio.last!.color != local.last!.color)
        for i in idle.indices { #expect(idle[i].transform==local[i].transform && local[i].transform==radio[i].transform) }
        #expect(local.filter(\.castsShadow).count==2 && !local.last!.castsShadow)
        var dead=enemy;dead.health=0
        #expect(NativeAlarmGeometry.reporter(enemy:dead,progress:0.5,radio:true,transmitted:false).isEmpty)
    }
    @Test func radioAttachmentFollowsCrouchHeightAndYawWithoutMovingTheWeapon() {
        var enemy=EnemyState(id:1,position:SIMD3(110,19,212))
        let upright=NativeAlarmGeometry.reporter(enemy:enemy,progress:0.5,radio:true,transmitted:false)[0].transform.columns.3
        enemy.crouchAmount=1
        let crouched=NativeAlarmGeometry.reporter(enemy:enemy,progress:0.5,radio:true,transmitted:false)[0].transform.columns.3
        #expect(abs(upright.y-crouched.y-0.5)<0.0001)
        let muzzle=EnemyPose(enemy).muzzlePosition
        enemy.yaw = .pi
        let turned=NativeAlarmGeometry.reporter(enemy:enemy,progress:nil,radio:false,transmitted:false)[0].transform.columns.3
        #expect(abs(turned.x+crouched.x-2*enemy.position.x)<0.0001)
        #expect(abs(turned.z+crouched.z-2*enemy.position.z)<0.0001)
        enemy.yaw=0
        #expect(EnemyPose(enemy).muzzlePosition==muzzle)
    }
    @Test func relayFitsOnAuthoredOwnerAndItsLensNeverCastsAnOpaqueShadow() throws {
        let map=MapDefinition.blacksite,alarm=BlacksiteAlarm.definition
        let device=try #require(map.environment.devices.first { $0.id==alarm.radioDeviceID })
        let owner=try #require(map.obstacles.first { $0.id==device.ownerObstacleID })
        let position=map.grounded(alarm.radioPosition)
        let parts=NativeAlarmGeometry.module(position:position)
        #expect(parts.count==3 && parts[0].mesh==0)
        #expect(abs(position.z-0.045/2-(owner.position.z+owner.size.z/2))<0.005)
        #expect(position.y<map.grounded(owner.position).y+owner.size.y)
        let on=NativeAlarmGeometry.moduleIndicator(position:position,powered:true)
        let off=NativeAlarmGeometry.moduleIndicator(position:position,powered:false)
        #expect(on.transform==off.transform && !on.castsShadow && !off.castsShadow)
        #expect(on.material.z>0 && off.material.z==0)
    }
}
