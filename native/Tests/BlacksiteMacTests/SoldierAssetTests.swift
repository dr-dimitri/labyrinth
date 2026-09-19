import Foundation
import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

@Suite(.serialized)
struct SoldierAssetTests {
    private static var fixture: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/characters/soldier/soldier.glb")
    }
    private static let loaded = Result { try SoldierAsset(url:fixture) }
    private func asset() throws -> SoldierAsset { let value=try Self.loaded.get();value.resetAnimation();return value }
    private func point(_ m:simd_float4x4,_ p:SIMD3<Float>)->SIMD3<Float> { let q=m*SIMD4(p,1);return SIMD3(q.x,q.y,q.z) }
    private func bounds(_ primitive:SoldierPrimitive,_ palette:[simd_float4x4])->(SIMD3<Float>,SIMD3<Float>) {
        var lo=SIMD3<Float>(repeating:.infinity),hi=SIMD3<Float>(repeating:-.infinity)
        for vertex in primitive.vertices { let p=SoldierAsset.skin(vertex,palette:palette);lo=simd_min(lo,p);hi=simd_max(hi,p) }
        return (lo,hi)
    }

    @Test func actualAssetLoadsBothMaterialsDeduplicatesGeometryAndPreservesTopology() throws {
        let model=try asset()
        #expect(MemoryLayout<SoldierVertex>.stride==64)
        #expect(MemoryLayout<SoldierVertex>.offset(of:\.position)==0)
        #expect(MemoryLayout<SoldierVertex>.offset(of:\.normal)==16)
        #expect(MemoryLayout<SoldierVertex>.offset(of:\.uv)==32)
        #expect(MemoryLayout<SoldierVertex>.offset(of:\.joints)==40)
        #expect(MemoryLayout<SoldierVertex>.offset(of:\.weights)==48)
        #expect(model.paletteCount==58)
        #expect(model.primitives.count==3)
        #expect(Set(model.primitives.map(\.material))==Set([0,1,2]))
        #expect(model.primitives.reduce(0) { $0+$1.indices.count }==58_350)
        #expect(model.primitives.reduce(0) { $0+$1.vertices.count }<29_175)
        #expect(model.animationNames.contains("idle") && model.animationNames.contains("walk") && model.animationNames.contains("run"))
        #expect(model.materials[1].name.lowercased().contains("head"))
        #expect(model.materials[2].name.lowercased().contains("body"))
        #expect(model.materials.allSatisfy { $0.baseColorData.count>1000 && ($0.normalData?.count ?? 0)>1000 })
        for primitive in model.primitives {
            #expect(primitive.indices.allSatisfy { Int($0)<primitive.vertices.count })
            #expect(primitive.vertices.allSatisfy { vertex in
                let sum=vertex.weights.x+vertex.weights.y+vertex.weights.z+vertex.weights.w
                return abs(sum-1)<0.00001 && (0..<4).allSatisfy { Int(vertex.joints[$0])<model.paletteCount }
            })
        }
    }

    @Test func headSkinFollowsBodyAcrossCrouchYawAndWorldPlacement() throws {
        let model=try asset()
        let head=try #require(model.primitives.first { model.materials[$0.material].name.lowercased().contains("head") })
        for crouch:Float in [0,0.5,1] {
            var enemy=EnemyState(id:Int(crouch*10)+1,position:SIMD3(11,2,-8));enemy.yaw=1.2;enemy.crouchAmount=crouch
            let p=model.palette(enemy:enemy,time:2,terrain:.flat)
            let (lo,hi)=bounds(head,p),joint=model.jointPositions(enemy:enemy,time:2,terrain:.flat)
            let position=try #require(joint["mixamorigHead"])
            #expect(abs(position.y-(enemy.position.y+1.63-0.65*crouch))<0.025)
            #expect(hi.y-lo.y<0.40 && hi.y-lo.y>0.20)
            #expect(hi.y<enemy.position.y+1.95-0.65*crouch)
            #expect(simd_distance(SIMD2(position.x,position.z),SIMD2(enemy.position.x,enemy.position.z))<0.20)
            #expect((joint["mixamorigNeck"]?.y ?? 0)>enemy.position.y+1.3-0.65*crouch)
        }
    }

    @Test func bothPalmsStayOnAuthoritativeWeaponAcrossAimAndCrouch() throws {
        let model=try asset()
        var id=1
        for yaw:Float in [-2.2,0,1.5] { for pitch:Float in [-0.65,0,0.65] { for crouch:Float in [0,1] {
            var enemy=EnemyState(id:id,position:SIMD3(-4,1,6));id+=1
            enemy.yaw=yaw;enemy.aimPitch=pitch;enemy.crouchAmount=crouch;enemy.aimBlend=1
            let joints=model.jointPositions(enemy:enemy,time:0.4,terrain:.flat)
            for (side,grip) in [("Right",SIMD3<Float>(0.014,-0.075,0.074)),("Left",SIMD3<Float>(-0.016,-0.023,0.305))] {
                let wrist=try #require(joints["mixamorig"+side+"Hand"]),middle=try #require(joints["mixamorig"+side+"HandMiddle1"])
                let palm=wrist+(middle-wrist)*0.55,target=point(EnemyPose(enemy).gunTransform,grip)
                #expect(simd_distance(palm,target)<0.025)
            }
        } } }
    }

    @Test func fingersActuallyCurlAroundTheGrips() throws {
        let model=try asset(),enemy=EnemyState(id:1,position:.zero)
        let joints=model.jointPositions(enemy:enemy,time:0,terrain:.flat)
        for side in ["Left","Right"] {
            let a=try #require(joints["mixamorig"+side+"HandMiddle1"])
            let b=try #require(joints["mixamorig"+side+"HandMiddle2"])
            let c=try #require(joints["mixamorig"+side+"HandMiddle3"])
            let d=try #require(joints["mixamorig"+side+"HandMiddle4"])
            let chain=simd_distance(a,b)+simd_distance(b,c)+simd_distance(c,d)
            #expect(simd_distance(a,d)<chain*0.88)
            #expect(simd_dot(simd_normalize(b-a),simd_normalize(d-c))<0.6)
        }
    }

    @Test func realSkinRemainsFiniteGroundedAndCompactInAllGameplayPoses() throws {
        let model=try asset()
        for style in 0..<7 {
            var enemy=EnemyState(id:style+10,position:.zero)
            var terrain:TerrainProfile = .flat
            switch style {
            case 1:enemy.crouchAmount=1
            case 2:enemy.isMoving=true;enemy.walkCycle=1.7
            case 3:enemy.isMoving=true;enemy.isRunning=true;enemy.walkCycle=3.6
            case 4:enemy.grounded=false;enemy.position.y=1
            case 5:enemy.health=0;enemy.deathTime = -1
            case 6:terrain = .battlefield;enemy.position=SIMD3(12,terrain.height(x:12,z:24),24);enemy.crouchAmount=0.8
            default:break
            }
            let palette=model.palette(enemy:enemy,time:0.4,terrain:terrain)
            #expect(palette.count==model.paletteCount)
            #expect(palette.allSatisfy { m in (0..<4).allSatisfy { c in (0..<4).allSatisfy { m[c][$0].isFinite } } })
            var lowest:Float = .infinity,highest:Float = -.infinity
            for primitive in model.primitives { for vertex in primitive.vertices {
                let p=SoldierAsset.skin(vertex,palette:palette)
                #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
                lowest=min(lowest,p.y-terrain.height(x:p.x,z:p.z))
                highest=max(highest,p.y-enemy.position.y)
                #expect(simd_distance(p,enemy.position)<2.4)
            } }
            if enemy.grounded { #expect(lowest > -0.065) }
            if style==0 || style==1 { #expect(abs(lowest)<0.025) }
            if style==0 { #expect(highest>1.8 && highest<1.96) }
            if style==1 { #expect(highest>1.15 && highest<1.32) }
            if style==4 { #expect(lowest>1.05) }
            if style==5 { #expect(highest<0.65) }
        }
    }

    @Test func clipTransitionsAndResetDoNotLeaveStalePoses() throws {
        let model=try asset()
        var enemy=EnemyState(id:42,position:.zero)
        let standing=model.jointPositions(enemy:enemy,time:1,terrain:.flat)
        enemy.isMoving=true;enemy.isRunning=true;enemy.walkCycle=2.4
        let first=model.jointPositions(enemy:enemy,time:1,terrain:.flat)
        #expect(simd_distance(standing["mixamorigLeftFoot"]!,first["mixamorigLeftFoot"]!)<0.001)
        let running=model.jointPositions(enemy:enemy,time:1.2,terrain:.flat)
        #expect(simd_distance(first["mixamorigLeftFoot"]!,running["mixamorigLeftFoot"]!)>0.05)
        let before=model.palette(enemy:enemy,time:1.2,terrain:.flat)
        model.resetAnimation()
        let after=model.palette(enemy:enemy,time:1.2,terrain:.flat)
        for i in before.indices { for c in 0..<4 { #expect(simd_length(before[i][c]-after[i][c])<0.0001) } }
    }

    @Test func malformedContainersAndAccessorOffsetsThrowRatherThanCrash() throws {
        let original=try Data(contentsOf:Self.fixture)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("soldier-loader-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let group=Self.fixture.deletingLastPathComponent().appendingPathComponent("head-materials.json")
        if FileManager.default.fileExists(atPath:group.path) { try FileManager.default.copyItem(at:group,to:folder.appendingPathComponent("head-materials.json")) }
        let bad=folder.appendingPathComponent("bad.glb")
        try original.prefix(20).write(to:bad)
        #expect(throws:(any Error).self) { _=try SoldierAsset(url:bad) }
        func u32(_ data:Data,_ at:Int)->UInt32 { data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:at,as:UInt32.self)) } }
        let size=Int(u32(original,12))
        var json=try #require(JSONSerialization.jsonObject(with:original.subdata(in:20..<20+size)) as? [String:Any])
        var accessors=try #require(json["accessors"] as? [[String:Any]])
        accessors[0]["byteOffset"]=Int.max;json["accessors"]=accessors
        let binary=original.subdata(in:20+size..<original.count)
        func save(_ object:[String:Any]) throws {
            var encoded=try JSONSerialization.data(withJSONObject:object)
            while encoded.count%4 != 0 { encoded.append(0x20) }
            var rebuilt=Data()
            func append(_ value:UInt32) { var v=value.littleEndian;withUnsafeBytes(of:&v) { rebuilt.append(contentsOf:$0) } }
            append(0x46546c67);append(2);append(UInt32(20+encoded.count+binary.count));append(UInt32(encoded.count));append(0x4e4f534a)
            rebuilt.append(encoded);rebuilt.append(binary);try rebuilt.write(to:bad)
        }
        try save(json)
        #expect(throws:(any Error).self) { _=try SoldierAsset(url:bad) }
        accessors[0].removeValue(forKey:"byteOffset");json["accessors"]=accessors
        var nodes=try #require(json["nodes"] as? [[String:Any]])
        nodes.append(["name":"InvalidUnusedSkin","skin":999]);json["nodes"]=nodes
        try save(json)
        #expect(throws:(any Error).self) { _=try SoldierAsset(url:bad) }
    }
}
