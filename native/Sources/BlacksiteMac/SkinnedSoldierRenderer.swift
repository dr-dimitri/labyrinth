import Foundation
import Metal
import MetalKit
import simd
import BlacksiteCore

/// One shared indexed character mesh, with only joint matrices changing each
/// frame. World-space palettes are prepared after the owner's inflight wait.
@MainActor
final class SkinnedSoldierRenderer {
    private struct Primitive {
        let vertices:MTLBuffer
        let indices:MTLBuffer
        let indexCount:Int
        let material:Int
    }
    private struct Material {
        let color:MTLTexture
        let normal:MTLTexture
        let roughness:MTLTexture
        let kind:UInt32 // 0 cloth/armour, 1 exposed skin, 2 explicit visor
    }
    private enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? { if case .invalid(let message)=self { return message }; return nil }
    }
    private let asset:SoldierAsset
    private let primitives:[Primitive]
    private let palettes:[MTLBuffer]
    private let pipelines:[Int:MTLRenderPipelineState]
    private let shadowPipeline:MTLRenderPipelineState
    private let materials:[Material]
    private var counts=[Int](repeating:0,count:3)
    private let capacity=64
    private(set) var soldierCount=0
    private(set) var invalidPoseCount=0
    private(set) var capacityDropCount=0
    var drawCallCount:Int { soldierCount>0 ? primitives.count*2:0 }
    var triangleCount:Int { soldierCount*primitives.reduce(0) { $0+$1.indexCount/3 } }
    var baseColorSize:SIMD2<Int> { materials.reduce(SIMD2(0,0)) { SIMD2(max($0.x,$1.color.width),max($0.y,$1.color.height)) } }

    init(device:MTLDevice,library:MTLLibrary,assetURL:URL) throws {
        guard MemoryLayout<SoldierVertex>.stride==64 else {
            throw Failure.invalid("Soldaten-Vertexlayout stimmt nicht mit dem Metal-Shader überein.")
        }
        let loaded=try SoldierAsset(url:assetURL)
        guard loaded.paletteCount>0,loaded.paletteCount<=512,!loaded.primitives.isEmpty,!loaded.materials.isEmpty else {
            throw Failure.invalid("Soldatenmodell enthält kein unterstütztes Skelett oder Mesh.")
        }
        asset=loaded
        primitives=try loaded.primitives.enumerated().map { index,p in
            guard !p.vertices.isEmpty,!p.indices.isEmpty,p.indices.count%3==0,
                  loaded.materials.indices.contains(p.material),
                  p.indices.allSatisfy({ Int($0)<p.vertices.count }),
                  let vertex=device.makeBuffer(bytes:p.vertices,length:p.vertices.count*MemoryLayout<SoldierVertex>.stride,options:.storageModeShared),
                  let indices=device.makeBuffer(bytes:p.indices,length:p.indices.count*MemoryLayout<UInt32>.stride,options:.storageModeShared) else {
                throw Failure.invalid("Soldaten-Mesh \(index) enthält ungültige Indices oder konnte nicht auf die GPU geladen werden.")
            }
            vertex.label="Soldier shared vertices \(index)";indices.label="Soldier shared indices \(index)"
            return Primitive(vertices:vertex,indices:indices,indexCount:p.indices.count,material:p.material)
        }
        palettes=try (0..<3).map { slot in
            guard let buffer=device.makeBuffer(length:64*loaded.paletteCount*MemoryLayout<simd_float4x4>.stride,options:.storageModeShared) else {
                throw Failure.invalid("Gelenkpuffer für die Soldaten konnte nicht angelegt werden.")
            }
            buffer.label="Soldier world joint palettes frame \(slot)";return buffer
        }
        let loader=MTKTextureLoader(device:device),directory=assetURL.deletingLastPathComponent()
        var textureCache:[String:MTLTexture]=[:]
        func texture(_ stem:String,embedded:Data?,srgb:Bool,materialIndex:Int) throws -> MTLTexture? {
            let external=["png","jpg"].map { directory.appendingPathComponent("\(stem).\($0)") }
                .first { FileManager.default.fileExists(atPath:$0.path) }
            let key=external?.path ?? "embedded:\(materialIndex):\(stem)"
            if let cached=textureCache[key] { return cached }
            let options:[MTKTextureLoader.Option:Any]=[.SRGB:srgb,.generateMipmaps:true,
                // Original 2K source PNGs have the opposite vertical convention
                // to the JPEGs embedded by the GLB exporter. Flip only at upload.
                .origin:external == nil ? MTKTextureLoader.Origin.topLeft:MTKTextureLoader.Origin.bottomLeft,
                .textureStorageMode:MTLStorageMode.private.rawValue,
                .textureUsage:MTLTextureUsage.shaderRead.rawValue]
            do {
                let result:MTLTexture
                if let external { result=try loader.newTexture(URL:external,options:options) }
                else if let embedded { result=try loader.newTexture(data:embedded,options:options) }
                else { return nil }
                result.label="Soldier \(stem)";textureCache[key]=result;return result
            } catch { throw Failure.invalid("Soldatentextur \(stem) konnte nicht geladen werden: \(error.localizedDescription)") }
        }
        func solid(_ bytes:[UInt8],format:MTLPixelFormat,label:String)throws->MTLTexture {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:1,height:1,mipmapped:false)
            descriptor.usage = .shaderRead;descriptor.storageMode = .shared
            guard let result=device.makeTexture(descriptor:descriptor) else { throw Failure.invalid("Soldatenmaterial konnte nicht angelegt werden.") }
            bytes.withUnsafeBytes { result.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:bytes.count) }
            result.label=label;return result
        }
        let flatNormal=try solid([128,128,255,255],format:.rgba8Unorm,label:"Soldier flat normal fallback")
        let matteRoughness=try solid([224],format:.r8Unorm,label:"Soldier matte cloth roughness")
        materials=try loaded.materials.enumerated().map { index,material in
            let name=material.name.lowercased()
            let kind:UInt32=name.contains("visor") ? 2:name.contains("head") ? 1:0
            let stem=kind==1 ? "head":kind==2 ? "visor":"body"
            guard let color=try texture("\(stem)-color",embedded:material.baseColorData,srgb:true,materialIndex:index) else {
                throw Failure.invalid("Farbtextur des Soldatenmaterials \(material.name) fehlt.")
            }
            let normal=try texture("\(stem)-normal",embedded:material.normalData,srgb:false,materialIndex:index) ?? flatNormal
            let roughness=try texture("\(stem)-roughness",embedded:nil,srgb:false,materialIndex:index) ?? matteRoughness
            return Material(color:color,normal:normal,roughness:roughness,kind:kind)
        }
        guard let vertex=library.makeFunction(name:"soldierVertex"),let fragment=library.makeFunction(name:"soldierFragment"),
              let shadowVertex=library.makeFunction(name:"soldierShadowVertex"),let shadowFragment=library.makeFunction(name:"soldierShadowFragment") else {
            throw Failure.invalid("Metal-Shader für animierte Soldaten fehlen im Programmpaket.")
        }
        var compiled:[Int:MTLRenderPipelineState]=[:]
        for samples in [1,4] where device.supportsTextureSampleCount(samples) {
            let descriptor=MTLRenderPipelineDescriptor();descriptor.label="Textured skinned soldier \(samples)x"
            descriptor.vertexFunction=vertex;descriptor.fragmentFunction=fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb;descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount=samples;descriptor.isAlphaToCoverageEnabled=samples>1
            compiled[samples]=try device.makeRenderPipelineState(descriptor:descriptor)
        }
        pipelines=compiled
        let shadow=MTLRenderPipelineDescriptor();shadow.label="Skinned soldier directional shadows"
        shadow.vertexFunction=shadowVertex;shadow.fragmentFunction=shadowFragment;shadow.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline=try device.makeRenderPipelineState(descriptor:shadow)
    }

    func reset() { counts=[0,0,0];soldierCount=0;invalidPoseCount=0;capacityDropCount=0;asset.resetAnimation() }

    func prepare(enemies:[EnemyState],time:Double,terrain:TerrainProfile,slot:Int) {
        guard counts.indices.contains(slot) else { return }
        let target=palettes[slot].contents().bindMemory(to:simd_float4x4.self,capacity:capacity*asset.paletteCount)
        var count=0;invalidPoseCount=0;capacityDropCount=0
        for enemy in enemies {
            if let death=enemy.deathTime,time-death>8 { continue }
            guard count<capacity else { capacityDropCount+=1;continue }
            let pose=asset.palette(enemy:enemy,time:time,terrain:terrain)
            guard pose.count==asset.paletteCount,pose.allSatisfy(Self.finite) else { invalidPoseCount+=1;continue }
            pose.withUnsafeBufferPointer { source in
                target.advanced(by:count*asset.paletteCount).update(from:source.baseAddress!,count:source.count)
            }
            count+=1
        }
        counts[slot]=count;soldierCount=count
    }

    func encodeShadow(encoder:MTLRenderCommandEncoder,slot:Int) {
        guard counts.indices.contains(slot),counts[slot]>0 else { return }
        encoder.pushDebugGroup("Instanced skinned soldier shadows")
        encoder.setRenderPipelineState(shadowPipeline)
        draw(encoder:encoder,slot:slot)
        encoder.popDebugGroup()
    }

    func encodeMain(encoder:MTLRenderCommandEncoder,samples:Int,slot:Int) {
        guard counts.indices.contains(slot),counts[slot]>0,let pipeline=pipelines[samples] else { return }
        encoder.pushDebugGroup("Instanced textured soldier body and face materials")
        encoder.setRenderPipelineState(pipeline)
        draw(encoder:encoder,slot:slot)
        encoder.popDebugGroup()
    }

    private func draw(encoder:MTLRenderCommandEncoder,slot:Int) {
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(palettes[slot],offset:0,index:1)
        var paletteSize=UInt32(asset.paletteCount)
        encoder.setVertexBytes(&paletteSize,length:MemoryLayout<UInt32>.stride,index:3)
        for primitive in primitives {
            encoder.setVertexBuffer(primitive.vertices,offset:0,index:0)
            let material=materials[primitive.material]
            encoder.setFragmentTexture(material.color,index:0);encoder.setFragmentTexture(material.normal,index:1)
            encoder.setFragmentTexture(material.roughness,index:2)
            var kind=material.kind
            encoder.setFragmentBytes(&kind,length:MemoryLayout<UInt32>.stride,index:3)
            encoder.drawIndexedPrimitives(type:.triangle,indexCount:primitive.indexCount,indexType:.uint32,
                indexBuffer:primitive.indices,indexBufferOffset:0,instanceCount:counts[slot])
        }
    }
    private static func finite(_ m:simd_float4x4)->Bool {
        for i in 0..<4 { let v=m[i];if !v.x.isFinite || !v.y.isFinite || !v.z.isFinite || !v.w.isFinite { return false } }
        return true
    }
}
