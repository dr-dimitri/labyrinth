import Foundation
import Metal
import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct NativeWorldSmokeTests {
    @Test func sharedVolumeLayoutAndGrowthArePackedWithoutQualityOrLightingOpacityChanges() {
        #expect(MemoryLayout<GPUWorldSmokeVolume>.stride==80)
        #expect(MemoryLayout<GPUWorldSmokeVolume>.offset(of:\.centerDensity)==0)
        #expect(MemoryLayout<GPUWorldSmokeVolume>.offset(of:\.radiiKind)==16)
        #expect(MemoryLayout<GPUWorldSmokeVolume>.offset(of:\.clipMinimum)==32)
        #expect(MemoryLayout<GPUWorldSmokeVolume>.offset(of:\.clipMaximum)==48)
        #expect(MemoryLayout<GPUWorldSmokeVolume>.offset(of:\.scatterColor)==64)
        #expect(MemoryLayout<GPUWorldSmoke>.stride==336)
        #expect(MemoryLayout<GPUWorldSmoke>.offset(of:\.first)==16)
        #expect(MemoryLayout<GPUWorldSmoke>.offset(of:\.second)==96)
        #expect(MemoryLayout<GPUWorldSmoke>.offset(of:\.third)==176)
        #expect(MemoryLayout<GPUWorldSmoke>.offset(of:\.fourth)==256)
        for age:Float in [0,0.3,2,8,10] {
            let volume=SmokeVolumeState(id:1,position:SIMD3(110,22,210),age:age,
                clipMinimum:SIMD3(108,20,207),clipMaximum:SIMD3(112,24,213))
            let day=GPUWorldSmoke(volumes:[volume],lighting:[SIMD2(1,0)])
            let shade=GPUWorldSmoke(volumes:[volume],lighting:[SIMD2(0,0)])
            #expect(day.counts.x==1 && day.counts.y==SmokeVolumeState.opaqueOpticalDepth)
            #expect(day.first.centerDensity==SIMD4(volume.position,volume.density))
            #expect(day.first.radiiKind==SIMD4(volume.radii,0))
            #expect(day.first.clipMinimum==SIMD4(volume.clipMinimum,0))
            #expect(day.first.clipMaximum==SIMD4(volume.clipMaximum,0))
            #expect(day.first.centerDensity==shade.first.centerDensity && day.first.radiiKind==shade.first.radiiKind)
            #expect(day.first.scatterColor.x>shade.first.scatterColor.x)
        }
        let empty=GPUWorldSmoke(volumes:[],lighting:[])
        #expect(empty.counts.x==0 && empty.first.centerDensity.w==0 && empty.fourth.centerDensity.w==0)
    }

    @Test func smokeCanisterFitsItsActualNineCentimetreCollisionAndRestHeight() {
        let center=SIMD3<Float>(110,20.09,210),parts=NativeSmokeGeometry.grenade(position:center)
        #expect(parts.count==NativeSmokeGeometry.grenadePartCount && parts.allSatisfy(\.castsShadow))
        var lowest:Float = .infinity
        for part in parts {
            var samples:[SIMD3<Float>]=[]
            if part.mesh==1 {
                for row in 0...12 { for column in 0..<24 {
                    let latitude=Float(row)/12 * .pi,angle=Float(column)/24 * .pi*2
                    samples.append(SIMD3(sin(latitude)*cos(angle),cos(latitude),sin(latitude)*sin(angle)))
                } }
            } else if part.mesh==2 {
                for y:Float in [-0.5,0.5] { for column in 0..<24 {
                    let angle=Float(column)/24 * .pi*2;samples.append(SIMD3(cos(angle),y,sin(angle)))
                } }
            } else {
                for x:Float in [-0.5,0.5] { for y:Float in [-0.5,0.5] { for z:Float in [-0.5,0.5] { samples.append(SIMD3(x,y,z)) } } }
            }
            for point in samples {
                let p=part.transform*SIMD4(point,1),world=SIMD3(p.x,p.y,p.z)
                #expect(simd_distance(world,center)<=0.0901)
                lowest=min(lowest,world.y)
            }
        }
        #expect(abs(lowest-20)<0.0001)
    }

    /// Compile the actual shared rendering helper and read GPU results back.
    /// This catches uniform offsets, clipping and accidental opacity drift that
    /// a Swift-only copy of the same formula could not detect.
    @Test(.enabled(if:ProcessInfo.processInfo.environment["BLACKSITE_TEST_METAL_SMOKE"]=="1"))
    func metalExtinctionMatchesCoreAtWallsEdgesInsideCloudsAndDistantSky() throws {
        let device=try #require(MTLCreateSystemDefaultDevice()),queue=try #require(device.makeCommandQueue())
        let sourceURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BlacksiteMac/Resources/Shaders.metal")
        var source=try String(contentsOf:sourceURL)
        source += """

        struct SmokeProbeRay { float4 start; float4 end; };
        kernel void smokeOpticsProbe(uint id [[thread_position_in_grid]],constant WorldSmoke &smoke [[buffer(0)]],
          const device SmokeProbeRay *rays [[buffer(1)]],device float2 *results [[buffer(2)]]) {
          float3 from=rays[id].start.xyz,to=rays[id].end.xyz,delta=to-from;float metres=length(delta),depth=0;float3 point;
          if(metres>0.000001) for(uint i=0;i<min(uint(smoke.counts.x),4u);++i) depth+=smokeDepth(smoke.volumes[i],from,delta,metres,point);
          results[id]=float2(min(20.0,depth),smokeTransmission(from,to,smoke));
        }
        """
        let options=MTLCompileOptions();options.fastMathEnabled=true
        let library=try device.makeLibrary(source:source,options:options)
        let pipeline=try device.makeComputePipelineState(function:#require(library.makeFunction(name:"smokeOpticsProbe")))
        struct Ray { var start:SIMD4<Float>;var end:SIMD4<Float> }
        let rayPairs:[(SIMD3<Float>,SIMD3<Float>)] = [
            (SIMD3(-8,2,0),SIMD3(8,2,0)),(SIMD3(0,2,0),SIMD3(8,2,0)),
            (SIMD3(-8,4.01,0),SIMD3(8,4.01,0)),(SIMD3(-8,3.95,0),SIMD3(8,3.95,0)),
            (SIMD3(1.45,2,-8),SIMD3(1.45,2,8)),(SIMD3(1.35,2,-8),SIMD3(1.35,2,8)),
            (SIMD3(0,2,-8),SIMD3(0,2,-4)),(SIMD3(0,2,-8),SIMD3(0,2,450)),
            (SIMD3(0,2,0),SIMD3(0,2,0)),(SIMD3(-8,0.1,2.3),SIMD3(8,3.8,-2.4)),
            (SIMD3(110,22,190),SIMD3(110,22,450))]
        let rays=rayPairs.map { Ray(start:SIMD4($0.0,1),end:SIMD4($0.1,1)) }
        let input=try #require(rays.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) })
        let output=try #require(device.makeBuffer(length:rays.count*MemoryLayout<SIMD2<Float>>.stride,options:.storageModeShared))
        for age:Float in [0,0.35,2,8.4,10] { for count in [0,1,4] {
            let candidates: [SmokeVolumeState] = (0..<4).map { index in
                let x = Float(index) * 1.7
                let position: SIMD3<Float> = index == 3 ? SIMD3(110, 22, 210) : SIMD3(x, 2, 0)
                let minimum: SIMD3<Float>? = index == 3 ? nil : SIMD3(x - 3, 0, -3)
                let maximum: SIMD3<Float>? = index == 3 ? nil : SIMD3(x + 1.4, 4, 3)
                return SmokeVolumeState(id: index, position: position, age: age,
                                        clipMinimum: minimum, clipMaximum: maximum)
            }
            let volumes=Array(candidates.prefix(count));var uniform=GPUWorldSmoke(volumes:volumes,lighting:[])
            let command=try #require(queue.makeCommandBuffer()),encoder=try #require(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&uniform,length:MemoryLayout<GPUWorldSmoke>.stride,index:0)
            encoder.setBuffer(input,offset:0,index:1);encoder.setBuffer(output,offset:0,index:2)
            encoder.dispatchThreads(MTLSize(width:rays.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(pipeline.threadExecutionWidth,rays.count),height:1,depth:1))
            encoder.endEncoding();command.commit();command.waitUntilCompleted()
            if let error=command.error { throw error };#expect(command.status == .completed)
            let values=output.contents().bindMemory(to:SIMD2<Float>.self,capacity:rays.count)
            for (index,ray) in rayPairs.enumerated() {
                let depth: Float = volumes.reduce(0) { $0 + $1.opticalDepth(from: ray.0, to: ray.1) }
                let expected: Float = min(20, depth)
                #expect(values[index].x.isFinite && values[index].y.isFinite)
                #expect(abs(values[index].x-expected)<0.002,"age=\(age) count=\(count) ray=\(index) gpu=\(values[index].x) core=\(expected)")
                let transmission: Float = exp(-expected)
                #expect(abs(values[index].y - transmission) < 0.0005)
            }
        } }
    }
}
