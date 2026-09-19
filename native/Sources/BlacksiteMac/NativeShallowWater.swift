import Foundation
import Metal
import simd
import BlacksiteCore

/// Buffer 7. Rectangles and levels are the same authoritative surface records
/// used by movement/hearing. The second header component selects transparency
/// layers; -1 preserves the one-pass path on maps without shallow water.
struct GPUShallowWaterZone {
    var bounds=SIMD4<Float>(repeating:0)
    var parameters=SIMD4<Float>(repeating:0)
}
struct GPUShallowWater {
    var counts=SIMD4<Float>(0,-1,0,0)
    var first=GPUShallowWaterZone(),second=GPUShallowWaterZone()
    var third=GPUShallowWaterZone(),fourth=GPUShallowWaterZone()
    init(zones:[MapShallowWaterZone],layer:Int = -1) {
        counts=SIMD4(Float(zones.count),Float(layer),0,0)
        for (index,zone) in zones.prefix(4).enumerated() {
            let field=GPUShallowWaterZone(bounds:SIMD4(zone.minimum.x,zone.minimum.y,zone.maximum.x,zone.maximum.y),
                parameters:SIMD4(zone.surfaceHeight,0,0,0))
            switch index { case 0:first=field;case 1:second=field;case 2:third=field;default:fourth=field }
        }
    }
}

enum NativeShallowWaterGeometry {
    /// Clipping retains the exact terrain triangle diagonal, even for a zone
    /// whose edge falls between integer grid lines. UV.x is physical depth.
    static func vertices(zones:[MapShallowWaterZone],terrain:TerrainProfile)->[GPUVertex] {
        var result:[GPUVertex]=[]
        func clip(_ polygon:[SIMD3<Float>],distance:(SIMD3<Float>)->Float)->[SIMD3<Float>] {
            guard let last=polygon.last else { return [] }
            var output:[SIMD3<Float>]=[],a=last,da=distance(a)
            for b in polygon {
                let db=distance(b)
                if (da>=0) != (db>=0) { output.append(a+(b-a)*(da/(da-db))) }
                if db>=0 { output.append(b) }
                a=b;da=db
            }
            return output
        }
        for (index,zone) in zones.enumerated() {
            for z in Int(floor(zone.minimum.y))..<Int(ceil(zone.maximum.y)) {
                for x in Int(floor(zone.minimum.x))..<Int(ceil(zone.maximum.x)) {
                    func point(_ xx:Int,_ zz:Int)->SIMD3<Float> {
                        SIMD3(Float(xx),terrain.height(x:Float(xx),z:Float(zz)),Float(zz))
                    }
                    let a=point(x,z),b=point(x+1,z),c=point(x,z+1),d=point(x+1,z+1)
                    for triangle in [[a,c,b],[b,c,d]] {
                        var polygon=clip(triangle) { $0.x-zone.minimum.x }
                        polygon=clip(polygon) { zone.maximum.x-$0.x }
                        polygon=clip(polygon) { $0.z-zone.minimum.y }
                        polygon=clip(polygon) { zone.maximum.y-$0.z }
                        polygon=clip(polygon) { zone.surfaceHeight-$0.y }
                        guard polygon.count>=3 else { continue }
                        for i in 1..<(polygon.count-1) {
                            let points=[polygon[0],polygon[i],polygon[i+1]]
                            guard simd_length_squared(simd_cross(points[1]-points[0],points[2]-points[0]))>1e-10,
                                  points.contains(where:{ zone.surfaceHeight-$0.y>0.0001 }) else { continue }
                            result.append(contentsOf:points.map {
                                GPUVertex(position:SIMD3($0.x,zone.surfaceHeight,$0.z),normal:SIMD3(0,1,0),
                                    uv:SIMD2(max(0,zone.surfaceHeight-$0.y),Float(index)))
                            })
                        }
                    }
                }
            }
        }
        return result
    }
    static func layerCount(zones:[MapShallowWaterZone])->Int {
        Set(zones.map(\.surfaceHeight)).count
    }
    /// CPU mirror of the fragment partition. Uses the eye segment, not the
    /// fragment's own footprint: a pane behind a pool still blends correctly.
    static func crossings(from:SIMD3<Float>,to:SIMD3<Float>,zones:[MapShallowWaterZone])->Int {
        let delta=to-from
        guard abs(delta.y)>0.00001 else { return 0 }
        var crossed=Set<Float>()
        for zone in zones {
            let t=(zone.surfaceHeight-from.y)/delta.y
            let p=from+delta*t
            if t>0.00001 && t<0.99999 && zone.contains(x:p.x,z:p.z) { crossed.insert(zone.surfaceHeight) }
        }
        return crossed.count
    }
}

/// No target textures and no quality-specific surface. Per-map geometry is
/// replaced atomically by the parent; completed command buffers own old data.
@MainActor
final class NativeShallowWaterRenderer {
    struct Resources {
        let zones:[MapShallowWaterZone]
        let vertices:MTLBuffer?
        let vertexCount:Int
        let layers:Int
    }
    private struct Ripple { var position:SIMD3<Float>;var age:Float;let lifetime:Float;let strength:Float;let zone:Int }
    private struct GPURipple { var positionAge:SIMD4<Float>;var parameters:SIMD4<Float> }
    private enum Failure:LocalizedError {
        case resource(String)
        var errorDescription:String? { if case .resource(let text)=self { return text };return nil }
    }
    private let surfacePipelines:[Int:MTLRenderPipelineState]
    private let depth:MTLDepthStencilState
    private let rippleBuffers:[MTLBuffer]
    private var ripples:[Ripple]=[]
    private var rippleCounts=[0,0,0]
    private(set) var resources:Resources
    private(set) var drawCallCount=0
    var diagnostics:[String:Any] {
        ["shallowWaterZones":resources.zones.count,"shallowWaterTriangles":resources.vertexCount/3,
         "shallowWaterTransparencyLayers":resources.layers,"waterRipples":ripples.count,
         "waterRippleLimit":32,"shallowWaterDrawCalls":drawCallCount,"shallowWaterRenderTargets":0,
         "shallowWaterUniformBytes":MemoryLayout<GPUShallowWater>.stride]
    }
    init(device:MTLDevice,library:MTLLibrary,map:MapDefinition)throws {
        guard MemoryLayout<GPUShallowWater>.stride==144,MemoryLayout<GPURipple>.stride==32 else {
            throw Failure.resource("CPU- und Metal-Flachwasserlayout stimmen nicht überein.")
        }
        var surfaces:[Int:MTLRenderPipelineState]=[:]
        for samples in [1,4] where device.supportsTextureSampleCount(samples) {
            do {
                let p=MTLRenderPipelineDescriptor();p.label="Shared shallow water and bounded contact rings"
                p.vertexFunction=library.makeFunction(name:"shallowWaterVertex")
                p.fragmentFunction=library.makeFunction(name:"shallowWaterFragment")
                p.depthAttachmentPixelFormat = .depth32Float;p.rasterSampleCount=samples
                let color=p.colorAttachments[0]!;color.pixelFormat = .bgra8Unorm_srgb;color.isBlendingEnabled=true
                color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .zero;color.destinationAlphaBlendFactor = .one
                let state=try device.makeRenderPipelineState(descriptor:p)
                surfaces[samples]=state
            }
        }
        surfacePipelines=surfaces
        let d=MTLDepthStencilDescriptor();d.depthCompareFunction = .lessEqual;d.isDepthWriteEnabled=false
        guard let state=device.makeDepthStencilState(descriptor:d) else { throw Failure.resource("Flachwasser-Tiefentest fehlt.") }
        depth=state
        rippleBuffers=try (0..<3).map { index in
            guard let buffer=device.makeBuffer(length:16+32*MemoryLayout<GPURipple>.stride,options:.storageModeShared) else { throw Failure.resource("Wellenringpuffer fehlt.") }
            buffer.label="Bounded water ripples \(index)";return buffer
        }
        resources=try Self.makeResources(device:device,map:map)
        ripples.reserveCapacity(32)
    }
    static func makeResources(device:MTLDevice,map:MapDefinition)throws->Resources {
        let zones=map.environment.shallowWaterZones
        guard zones.count<=4 else { throw Failure.resource("Höchstens vier Flachwasserflächen sind erlaubt.") }
        let vertices=NativeShallowWaterGeometry.vertices(zones:zones,terrain:map.terrain)
        var buffer:MTLBuffer?
        if !vertices.isEmpty {
            buffer=device.makeBuffer(bytes:vertices,length:vertices.count*MemoryLayout<GPUVertex>.stride,options:.storageModeShared)
            guard buffer != nil else { throw Failure.resource("Flachwassergeometrie konnte nicht angelegt werden.") }
            buffer?.label="\(map.id) physical shallow surfaces"
        }
        return Resources(zones:zones,vertices:buffer,vertexCount:vertices.count,layers:NativeShallowWaterGeometry.layerCount(zones:zones))
    }
    func replace(_ resources:Resources) { self.resources=resources;reset() }
    func reset() { ripples.removeAll(keepingCapacity:true);rippleCounts=[0,0,0];drawCallCount=0 }
    func handle(events:[GameEvent],simulation:CombatSimulation) {
        for event in events {
            var point:SIMD3<Float>?,strength:Float=0.5
            if let hit=event.waterImpact { point=hit.position;strength=event.kind == .explosion ? 1:0.4 }
            else if let hearing=event.hearing,hearing.surface == .water,
                    hearing.kind == .footstep || hearing.kind == .landing {
                point=hearing.position;strength=hearing.kind == .landing ? 0.9:0.4
            }
            guard var p=point,let zone=simulation.map.waterSurface(at:p),
                  let index=resources.zones.firstIndex(where:{$0.id==zone.id}) else { continue }
            p.y=zone.surfaceHeight+0.001
            if ripples.count==32 { ripples.removeFirst() }
            ripples.append(Ripple(position:p,age:0,lifetime:0.85+strength*0.4,strength:strength,zone:index))
        }
    }
    func step(deltaTime:Float) {
        let dt=min(0.1,max(0,deltaTime));guard dt>0 else { return }
        for index in ripples.indices { ripples[index].age+=dt }
        ripples.removeAll { $0.age >= $0.lifetime }
    }
    func prepare(slot:Int) {
        drawCallCount=0
        let memory=rippleBuffers[slot].contents()
        memory.storeBytes(of:SIMD4<Float>(Float(ripples.count),0,0,0),as:SIMD4<Float>.self)
        let target=memory.advanced(by:16).bindMemory(to:GPURipple.self,capacity:32)
        for (index,ring) in ripples.enumerated() {
            target[index]=GPURipple(positionAge:SIMD4(ring.position,ring.age/ring.lifetime),
                parameters:SIMD4(0.10+ring.age*(0.5+ring.strength*0.5),ring.strength,Float(ring.zone),0))
        }
        rippleCounts[slot]=ripples.count
    }
    func encode(encoder:MTLRenderCommandEncoder,samples:Int,slot:Int) {
        guard let vertices=resources.vertices,let pipeline=surfacePipelines[samples] else { return }
        encoder.pushDebugGroup("Depth-tested shared shallow water; no depth or shadow write")
        encoder.setDepthStencilState(depth);encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline);encoder.setVertexBuffer(vertices,offset:0,index:0)
        encoder.setFragmentBuffer(rippleBuffers[slot],offset:0,index:8)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:resources.vertexCount);drawCallCount+=1
        encoder.popDebugGroup()
    }
}
