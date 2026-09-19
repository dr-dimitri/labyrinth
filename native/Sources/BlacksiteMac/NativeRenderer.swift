import AppKit
import Metal
import MetalKit
import simd
import ImageIO
import BlacksiteCore

enum NativeRenderMode { case menu, playing, paused, result }

struct GPUVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
}
private struct GPUInstance {
    var model: simd_float4x4
    var normal0: SIMD4<Float>
    var normal1: SIMD4<Float>
    var normal2: SIMD4<Float>
    var tint: SIMD4<Float>
    var material: SIMD4<Float>
}
private struct GPUUniforms {
    var viewProjection: simd_float4x4
    var inverseViewProjection: simd_float4x4
    var lightViewProjection: simd_float4x4
    var eyeTime: SIMD4<Float>
    var sunDirection: SIMD4<Float>
    var fogColor: SIMD4<Float>
    var viewport: SIMD4<Float>
    var nearLightViewProjection: simd_float4x4
    // Inverse map size, world width, depth range, contact occlusion strength.
    var shadowParameters: SIMD4<Float>
}
private struct RenderItem {
    var mesh: Int
    var instance: GPUInstance
    var center: SIMD3<Float>
    var radius: Float
    var shadow: Bool
}
private struct ForestTree {
    var center: SIMD3<Float>
    var radius: Float
    var levels: [[RenderItem]]
}
private struct Mesh {
    let vertices: MTLBuffer
    let count: Int
    let boundsCenter: SIMD3<Float>
    let halfExtents: SIMD3<Float>
}
private struct RenderBatch { let mesh: Int; let offset: Int; let count: Int }
private struct Particle {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var life: Float
    var duration: Float
    var scale: Float
    var tint: SIMD3<Float>
    var luminous: Float
    var gravity: Float
}
private struct Tracer { var start: SIMD3<Float>; var end: SIMD3<Float>; var life: Float; var hostile: Bool }
private struct SeededRandom {
    var seed: UInt64 = 1745
    mutating func next() -> Float { seed = 2862933555777941757 &* seed &+ 3037000493; return Float((seed >> 32) & 0xffffff) / Float(0xffffff) }
}
private enum RenderError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case let .unavailable(message) = self { return message }; return nil }
}

/// Native Metal rendering. All draw resources are retained and reused; the only
/// per-frame uploads use triple-buffered instance, uniform and joint palettes.
@MainActor
final class NativeRenderer {
    let deviceName: String
    private(set) var statistics = "Metal initialisiert"
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [Int: MTLRenderPipelineState]
    private let skyPipelines: [Int: MTLRenderPipelineState]
    private let shadowPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let skyDepthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let shadowSampler: MTLSamplerState
    private let textures: [MTLTexture]
    private let shadowTexture: MTLTexture
    private let nearShadowTextures: [Int: MTLTexture]
    private let weaponShadowTexture: MTLTexture
    private let meshes: [Mesh]
    private let skinnedSoldiers: SkinnedSoldierRenderer
    private let inflight = DispatchSemaphore(value: 3)
    private var buffers: [MTLBuffer]
    private let uniformBuffers: [MTLBuffer]
    private var frame = 0
    private var highQuality = true
    private let instanceCapacity = 48_000
    private var scenery: [RenderItem] = []
    private var forest: [ForestTree] = []
    private var coverCache: [Int: [RenderItem]] = [:]
    private var particles: [Particle] = []
    private var tracers: [Tracer] = []
    private var recoil: Float = 0
    private var shake: Float = 0
    private var flash: Float = 0
    private var visualTime: Float = 0
    private var random = SeededRandom(seed: 98217)
    private var smoothFOV: Float = 76
    private var weaponAimBlend: Float = 0
    private var weaponWallBlend: Float = 0
    private var weaponParts: [WeaponKind: WeaponParts] = [:]
    private var shells = ShellSimulation()
    private var shellImpacts: [ShellImpact] = []
    var characterDiagnostics: [String: Any] {
        ["skinnedSoldiers": skinnedSoldiers.soldierCount,
         "soldierTriangles": skinnedSoldiers.triangleCount,
         "soldierDrawCallsIncludingShadows": skinnedSoldiers.drawCallCount,
         "soldierTextureWidth": skinnedSoldiers.baseColorSize.x,
         "invalidSoldierPoses": skinnedSoldiers.invalidPoseCount,
         "droppedSoldiers": skinnedSoldiers.capacityDropCount,
         "footContactPatches": skinnedSoldiers.footContactCount,
         "farShadowInstances": farShadowInstanceCount, "nearShadowInstances": nearShadowInstanceCount]
    }
    // These shallow surfaces only affect visual shell physics. Append them
    // after gameplay cover so ShellSimulation's support indices remain stable.
    private let shellGroundColliders: [Obstacle] = [
        Obstacle(id: -10001, kind: .bunker, position: .zero, size: SIMD3(12,0.015,91)),
        Obstacle(id: -10002, kind: .bunker, position: SIMD3(-6.2,0,0), size: SIMD3(0.3,0.08,85)),
        Obstacle(id: -10003, kind: .bunker, position: SIMD3(6.2,0,0), size: SIMD3(0.3,0.08,85))
    ]
    private var shellCollisionCache: [Obstacle] = []
    private var farShadowInstanceCount = 0
    private var nearShadowInstanceCount = 0
    private var shotAge: Float = 10
    var shellCount: Int { shells.casings.count }
    var weaponAimObstructed: Bool { weaponWallBlend>=0.05 }
    var weaponDiagnostics: [String: Any] {
        ["weaponAimBlend":weaponAimBlend,"weaponWallBlend":weaponWallBlend,"weaponSelfShadowResolution":512]
    }
    private var frameAverage: Float = 1 / 60
    private var lastSize: CGSize = .zero
    private var currentScale: CGFloat = 1
    private weak var metalView: MTKView?
    private var cameraEye = SIMD3<Float>(0, 1.62, 32)
    private var cameraForward = SIMD3<Float>(0, 0, -1)
    private let sun = simd_normalize(SIMD3<Float>(-0.68, 0.24, -0.69))
    private let fog = SIMD3<Float>(0.40, 0.49, 0.54)
    private var lightMatrix = matrix_identity_float4x4

    init(view: MTKView, assetRoot: URL?) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.unavailable("Metal wird auf diesem Mac nicht unterstützt.") }
        self.device = device; self.queue = queue; deviceName = device.name
        guard MemoryLayout<GPUUniforms>.stride == 336,
              MemoryLayout<GPUUniforms>.offset(of: \.nearLightViewProjection) == 256,
              MemoryLayout<GPUUniforms>.offset(of: \.shadowParameters) == 320 else {
            throw RenderError.unavailable("CPU- und Metal-Schattenlayout stimmen nicht überein.")
        }
        // The packaged .app intentionally carries a direct resource rather than
        // SwiftPM's generated bundle. Access Bundle.module only for swift run.
        var shaderURL = Bundle.main.resourceURL?.appendingPathComponent("Shaders.metal")
        if shaderURL == nil || !FileManager.default.fileExists(atPath: shaderURL!.path) {
            shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: "Resources") ?? Bundle.module.url(forResource: "Shaders", withExtension: "metal")
        }
        guard let shaderURL, FileManager.default.fileExists(atPath: shaderURL.path) else { throw RenderError.unavailable("Metal-Shader fehlen im Programmpaket.") }
        let options = MTLCompileOptions(); options.fastMathEnabled = true
        let library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: options)
        var main: [Int: MTLRenderPipelineState] = [:], skies: [Int: MTLRenderPipelineState] = [:]
        for samples in [1, 4] where device.supportsTextureSampleCount(samples) {
            let p = MTLRenderPipelineDescriptor(); p.label = "Blacksite physically based opaque \(samples)x"
            p.vertexFunction = library.makeFunction(name: "worldVertex"); p.fragmentFunction = library.makeFunction(name: "worldFragment")
            p.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb; p.depthAttachmentPixelFormat = .depth32Float; p.rasterSampleCount = samples; p.isAlphaToCoverageEnabled = samples > 1
            main[samples] = try device.makeRenderPipelineState(descriptor: p)
            let s = MTLRenderPipelineDescriptor(); s.label = "Atmospheric sky \(samples)x"
            s.vertexFunction = library.makeFunction(name: "skyVertex"); s.fragmentFunction = library.makeFunction(name: "skyFragment")
            s.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb; s.depthAttachmentPixelFormat = .depth32Float; s.rasterSampleCount = samples
            skies[samples] = try device.makeRenderPipelineState(descriptor: s)
        }
        pipelines = main; skyPipelines = skies
        let sd = MTLRenderPipelineDescriptor(); sd.label = "Directional shadow depth"
        sd.vertexFunction = library.makeFunction(name: "shadowVertex"); sd.fragmentFunction = library.makeFunction(name: "shadowFragment"); sd.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: sd)
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .lessEqual; dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { throw RenderError.unavailable("Tiefenpuffer konnte nicht angelegt werden.") }; depthState = ds
        dd.isDepthWriteEnabled = false; dd.depthCompareFunction = .always; skyDepthState = device.makeDepthStencilState(descriptor: dd)!
        let sm = MTLSamplerDescriptor(); sm.minFilter = .linear; sm.magFilter = .linear; sm.mipFilter = .linear; sm.maxAnisotropy = 8; sm.sAddressMode = .repeat; sm.tAddressMode = .repeat
        sampler = device.makeSamplerState(descriptor: sm)!
        let ss = MTLSamplerDescriptor(); ss.minFilter = .nearest; ss.magFilter = .nearest; ss.compareFunction = .lessEqual; ss.sAddressMode = .clampToEdge; ss.tAddressMode = .clampToEdge
        shadowSampler = device.makeSamplerState(descriptor: ss)!
        let shadowDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false); shadowDesc.storageMode = .private; shadowDesc.usage = [.renderTarget, .shaderRead]
        guard let shadow = device.makeTexture(descriptor: shadowDesc) else { throw RenderError.unavailable("Schattenpuffer konnte nicht angelegt werden.") }; shadowTexture = shadow; shadow.label = "2048 directional shadow atlas"
        var nearMaps: [Int: MTLTexture] = [:]
        for resolution in [1024, 2048] {
            shadowDesc.width = resolution; shadowDesc.height = resolution
            guard let map = device.makeTexture(descriptor: shadowDesc) else { throw RenderError.unavailable("Nahschattenpuffer konnte nicht angelegt werden.") }
            map.label = "Stabilized near shadows \(resolution)"; nearMaps[resolution] = map
        }
        nearShadowTextures = nearMaps
        let weaponShadowDesc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:512,height:512,mipmapped:false)
        weaponShadowDesc.usage=[.renderTarget,.shaderRead];weaponShadowDesc.storageMode = .private
        guard let weaponShadow=device.makeTexture(descriptor:weaponShadowDesc) else { throw RenderError.unavailable("Waffen-Schattenpuffer konnte nicht angelegt werden.") }
        weaponShadow.label="512 viewmodel-only self shadows";weaponShadowTexture=weaponShadow
        meshes = try Self.makeMeshes(device: device)
        textures = try Self.loadTextures(device: device, assetRoot: assetRoot)
        guard let characterRoot = assetRoot ?? NativeResources.assetRoot else {
            throw RenderError.unavailable("Die Soldatenressourcen fehlen im Programmpaket.")
        }
        skinnedSoldiers = try SkinnedSoldierRenderer(device: device, library: library,
            assetURL: characterRoot.appendingPathComponent("characters/soldier/soldier.glb"))
        buffers = try (0..<3).map { index in guard let b = device.makeBuffer(length: 48_000 * MemoryLayout<GPUInstance>.stride, options: .storageModeShared) else { throw RenderError.unavailable("Instanzpuffer konnte nicht angelegt werden.") }; b.label = "Instances frame \(index)"; return b }
        uniformBuffers = (0..<3).map { _ in device.makeBuffer(length: MemoryLayout<GPUUniforms>.stride, options: .storageModeShared)! }
        metalView = view; view.device = device; view.colorPixelFormat = .bgra8Unorm_srgb; view.depthStencilPixelFormat = .depth32Float; view.sampleCount = main[4] == nil ? 1 : 4; view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.25, green: 0.35, blue: 0.42, alpha: 1)
        lightMatrix = Self.orthographic(left: -65, right: 65, bottom: -65, top: 65, near: 1, far: 220) * Self.lookAt(eye: sun * 100, target: .zero)
        buildScenery()
    }

    func setQuality(_ high: Bool) {
        highQuality = high; currentScale = high ? 1 : 0.82
        metalView?.sampleCount = high && pipelines[4] != nil ? 4 : 1
        lastSize = .zero
    }
    func reset() { particles.removeAll(keepingCapacity: true); tracers.removeAll(keepingCapacity: true); recoil = 0; shake = 0; flash = 0; smoothFOV = 76; weaponAimBlend = 0; weaponWallBlend = 0; shells.reset(); skinnedSoldiers.reset(); shellImpacts.removeAll(keepingCapacity: true); shotAge = 10 }

    func handle(events: [GameEvent], simulation: CombatSimulation) {
        if events.contains(where: { $0.kind == .shot }) {
            // Events arrive before draw/advanceEffects. A newly approached wall
            // must affect this shot's visual muzzle and ejection port already.
            weaponWallBlend=max(weaponWallBlend,weaponClearance(simulation))
        }
        for event in events {
            switch event.kind {
            case .shot:
                let kind = event.weapon ?? simulation.activeWeapon
                // Use this shot's current simulation pose, not last-frame camera state.
                let transform = weaponTransform(simulation: simulation, eye: simulation.eyePosition, yaw: simulation.player.yaw, pitch: simulation.player.pitch)
                let port = transform * SIMD4<Float>(0.048, 0.028, -0.114, 1)
                let localVelocity = SIMD4<Float>(2.15 + random.next() * 0.7, 1.45 + random.next() * 0.6, 0.35 + random.next() * 0.5, 0)
                let velocity = transform * localVelocity
                let rotation = simd_float3x3(columns: (SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z), SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z), SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
                let orientation = simd_quatf(rotation) * simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1,0,0))
                shells.eject(weapon: kind, position: SIMD3(port.x,port.y,port.z), velocity: SIMD3(velocity.x,velocity.y,velocity.z), orientation: orientation.vector)
                shotAge = 0
                recoil = min(1, recoil + (event.weapon == .sniper ? 0.75 : 0.28)); flash = 0.06
                let muzzleZ: Float = kind == .sniper ? -0.924 : -0.724
                let muzzle = transform * SIMD4<Float>(0,0.019,muzzleZ,1)
                let origin = SIMD3(muzzle.x,muzzle.y,muzzle.z)
                let forward = -SIMD3(transform.columns.2.x,transform.columns.2.y,transform.columns.2.z)
                // Keep the authoritative hit point; close cover must never
                // produce a backwards beam through the first-person receiver.
                if simd_dot(event.endPosition-origin,forward)>0 {
                    tracers.append(Tracer(start: origin, end: event.endPosition, life: 0.065, hostile: false))
                }
                spark(at: event.endPosition, count: 5, explosive: false)
            case .enemyShot:
                tracers.append(Tracer(start: event.position, end: event.endPosition, life: 0.11, hostile: true))
            case .explosion:
                shake = min(0.8, shake + 5 / max(3, simd_distance(cameraEye, event.position)))
                spark(at: event.position, count: highQuality ? 72 : 40, explosive: true)
            case .coverDestroyed: spark(at: event.position, count: 22, explosive: false)
            case .damage: shake = min(0.5, shake + 0.13)
            case .land: shake = max(shake, 0.065)
            default: break
            }
        }
        if particles.count > 450 { particles.removeFirst(particles.count - 450) }
        if tracers.count > 40 { tracers.removeFirst(tracers.count - 40) }
    }

    func draw(in view: MTKView, simulation: CombatSimulation, mode: NativeRenderMode, deltaTime: Float) {
        resize(view)
        guard let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor else { return }
        let dt = min(max(deltaTime, 0), 0.05)
        frameAverage = frameAverage * 0.97 + min(max(deltaTime, 0.001), 1) * 0.03
        if mode != .paused { advanceEffects(deltaTime: dt, simulation: simulation) }
        let size = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        let scene = prepare(simulation: simulation, mode: mode, size: size, deltaTime: dt)
        inflight.wait()
        let slot = frame % 3; frame += 1
        guard let command = queue.makeCommandBuffer() else { inflight.signal(); return }
        command.label = "Blacksite frame \(frame)"
        encode(command: command, descriptor: descriptor, samples: view.sampleCount, slot: slot, scene: scene)
        let semaphore = inflight; command.addCompletedHandler { _ in semaphore.signal() }
        command.present(drawable); command.commit()
        statistics = "\(deviceName) · \(view.sampleCount)× MSAA · \(scene.visibleCount + skinnedSoldiers.soldierCount) Instanzen · \(scene.main.count + scene.weapon.count + scene.weaponShadows.count + scene.shadows.count + scene.nearShadows.count + skinnedSoldiers.drawCallCount + 1) Draws · \(Int(1 / max(frameAverage, 0.001))) FPS"
    }

    /// Captures the same native GPU pipeline, including shadows and material
    /// sampling. This deliberately avoids screenshots of a browser or mockup.
    func renderOffscreen(simulation: CombatSimulation, width: Int, height: Int, to url: URL) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false); descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let color = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable("Vorschaubild konnte nicht angelegt werden.") }
        let samples = highQuality && pipelines[4] != nil ? 4 : 1
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false); depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        depthDesc.sampleCount = samples; depthDesc.textureType = samples > 1 ? .type2DMultisample : .type2D
        guard let depth = device.makeTexture(descriptor: depthDesc), let command = queue.makeCommandBuffer() else { throw RenderError.unavailable("Vorschaubild konnte nicht gerendert werden.") }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store; pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        if samples > 1 {
            let multisample = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            multisample.textureType = .type2DMultisample; multisample.sampleCount = samples; multisample.storageMode = .private; multisample.usage = .renderTarget
            guard let target = device.makeTexture(descriptor: multisample) else { throw RenderError.unavailable("MSAA-Vorschaubild konnte nicht angelegt werden.") }
            pass.colorAttachments[0].texture = target; pass.colorAttachments[0].resolveTexture = color; pass.colorAttachments[0].storeAction = .multisampleResolve
        }
        let scene = prepare(simulation: simulation, mode: .playing, size: SIMD2(Float(width), Float(height)), deltaTime: 1)
        inflight.wait(); let slot = frame % 3; frame += 1
        encode(command: command, descriptor: pass, samples: samples, slot: slot, scene: scene)
        command.commit(); command.waitUntilCompleted(); inflight.signal()
        if let error = command.error { throw error }
        guard skinnedSoldiers.invalidPoseCount == 0, skinnedSoldiers.capacityDropCount == 0 else {
            throw RenderError.unavailable("Soldatenprüfung: ungültige oder nicht ausgegebene Skelettposen.")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // BGRA to RGBA for AppKit's bitmap encoder.
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), let data = bitmap.bitmapData else { throw RenderError.unavailable("PNG-Speicher konnte nicht angelegt werden.") }
        bytes.withUnsafeBytes { data.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.unavailable("PNG konnte nicht kodiert werden.") }
        try png.write(to: url)
    }

    /// Bounded native GPU measurement. The same render targets are reused for
    /// every frame; warmup is excluded and completed command buffers are released.
    func benchmark(simulation: CombatSimulation, width: Int, height: Int, frames: Int) throws -> [String: Any] {
        let count = min(240, max(1, frames)), samples = highQuality && pipelines[4] != nil ? 4 : 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .private
        guard let resolved = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable("Benchmark-Farbpuffer konnte nicht angelegt werden.") }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = resolved; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        if samples > 1 {
            descriptor.textureType = .type2DMultisample; descriptor.sampleCount = samples
            guard let msaa = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable("Benchmark-MSAA konnte nicht angelegt werden.") }
            pass.colorAttachments[0].texture = msaa; pass.colorAttachments[0].resolveTexture = resolved; pass.colorAttachments[0].storeAction = .multisampleResolve
        }
        descriptor.pixelFormat = .depth32Float
        guard let depth = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable("Benchmark-Tiefenpuffer konnte nicht angelegt werden.") }
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        var cpu: [Double] = [], gpu: [Double] = [], wall: [Double] = []
        var visible = 0, draws = 0
        for index in 0..<(count + 10) {
            try autoreleasepool {
                let begin = ProcessInfo.processInfo.systemUptime
                visualTime += 1 / 60
                let scene = prepare(simulation: simulation, mode: .playing, size: SIMD2(Float(width),Float(height)), deltaTime: 1 / 60)
                inflight.wait(); let slot = frame % 3; frame += 1
                guard let command = queue.makeCommandBuffer() else { inflight.signal(); throw RenderError.unavailable("Benchmark-Befehlspuffer fehlt.") }
                encode(command: command, descriptor: pass, samples: samples, slot: slot, scene: scene)
                let cpuEnd = ProcessInfo.processInfo.systemUptime
                command.commit(); command.waitUntilCompleted(); inflight.signal()
                if let error = command.error { throw error }
                if index >= 10 {
                    cpu.append((cpuEnd-begin)*1000); gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
                    wall.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
                }
                visible = scene.visibleCount + skinnedSoldiers.soldierCount; draws = scene.main.count + scene.weapon.count + scene.weaponShadows.count + scene.shadows.count + scene.nearShadows.count + skinnedSoldiers.drawCallCount + 1
            }
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0,+)/Double(max(1,values.count)) }
        func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count-1,Int(Double(values.count)*0.95))] }
        return ["device": deviceName, "backend": "Metal", "width": width, "height": height, "frames": count, "warmupFrames": 10,
                "samples": samples, "cpuAverageMs": mean(cpu), "cpuP95Ms": p95(cpu), "gpuAverageMs": mean(gpu), "gpuP95Ms": p95(gpu),
                "serialFrameAverageMs": mean(wall), "gpuAllocatedMB": Double(device.currentAllocatedSize)/1_048_576,
                "visibleInstances": visible, "drawCalls": draws, "forestTrees": forest.count, "skyTextureWidth": textures[23].width, "nearShadowResolution": highQuality ? 2048 : 1024]
    }

    private func resize(_ view: MTKView) {
        let backing = view.window?.backingScaleFactor ?? 2
        let maximum: CGFloat = highQuality ? 2560 : 1440
        let width = max(view.bounds.width, 1), height = max(view.bounds.height, 1)
        let scale = min(backing, maximum / width) * currentScale
        let size = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        if size != lastSize { view.autoResizeDrawable = false; view.drawableSize = size; lastSize = size }
    }
    private struct PreparedScene {
        var instances: [GPUInstance]
        var main: [RenderBatch]
        var shadows: [RenderBatch]
        var nearShadows: [RenderBatch]
        var weapon: [RenderBatch]
        var weaponShadows: [RenderBatch]
        var weaponLightMatrix: simd_float4x4
        var nearVolume: DirectionalShadowVolume
        var uniforms: GPUUniforms
        var visibleCount: Int
        var enemies: [EnemyState]
        var time: Double
        var terrain: TerrainProfile
        var obstacles: [Obstacle]
    }
    private func prepare(simulation: CombatSimulation, mode: NativeRenderMode, size: SIMD2<Float>, deltaTime: Float) -> PreparedScene {
        let p = simulation.player
        var eye = simulation.eyePosition
        var yaw = p.yaw, pitch = p.pitch
        if mode == .menu { eye = SIMD3(12, 6.5, 33); let dir = simd_normalize(SIMD3<Float>(-3, 2, -8) - eye); yaw = atan2(-dir.x, -dir.z); pitch = asin(dir.y) }
        let bob: Float = simulation.isMoving && p.grounded && mode == .playing ? sin(visualTime * (simulation.isSprinting ? 14 : 10)) * (p.prone ? 0.009 : 0.027) : 0
        eye.y += bob
        yaw += sin(visualTime * 53) * shake * 0.012; pitch += cos(visualTime * 67) * shake * 0.013 + recoil * 0.012
        let forward = SIMD3<Float>(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
        cameraEye = eye; cameraForward = forward
        let aiming = simulation.isAiming && mode != .menu && !weaponAimObstructed
        let readyFOV:Float=simulation.isSprinting ? 83:76
        let aimedFOV:Float=simulation.activeWeapon == .sniper ? 14.8:55
        let targetFOV: Float = aiming ? aimedFOV : readyFOV
        smoothFOV += (targetFOV - smoothFOV) * min(1, max(deltaTime, 0.001) * 14)
        let view = Self.lookAt(eye: eye, target: eye + forward)
        let projection = Self.perspective(fov: smoothFOV * .pi / 180, aspect: size.x / max(size.y, 1), near: 0.04, far: 450)
        let vp = projection * view
        let shadowResolution = highQuality ? 2048 : 1024
        // Use the unshaken camera for a stable grid: recoil must not move shadows.
        let nearVolume = DirectionalShadowVolume.near(eye: mode == .menu ? eye : simulation.eyePosition,
            forward: mode == .menu ? forward : viewDirection(yaw: p.yaw, pitch: p.pitch), sun: sun, resolution: shadowResolution)
        let farVolume = DirectionalShadowVolume(matrix: lightMatrix)
        var all = scenery
        for obstacle in simulation.obstacles {
            if coverCache[obstacle.id] == nil { coverCache[obstacle.id] = buildCover(obstacle) }
            if !obstacle.destroyed { all.append(contentsOf: coverCache[obstacle.id] ?? []) }
        }
        for enemy in simulation.enemies { all.append(contentsOf: soldierWeapon(enemy, time: simulation.elapsed)) }
        for grenade in simulation.grenades {
            appendItem(to: &all, mesh: 1, position: grenade.position, scale: SIMD3(0.085, 0.105, 0.085), color: SIMD3(0.18, 0.23, 0.12), material: SIMD4(0.48, 0.6, 0, 0))
            appendItem(to: &all, mesh: 0, position: grenade.position + SIMD3(0, 0.1, 0), scale: SIMD3(0.06, 0.07, 0.04), color: SIMD3(0.34, 0.34, 0.29), material: SIMD4(0.28, 0.85, 0, 0))
            if Int(grenade.fuse * 9) % 2 == 0 { appendItem(to: &all, mesh: 1, position: grenade.position + SIMD3(0, 0.14, 0), scale: SIMD3(repeating: 0.025), color: SIMD3(1, 0.1, 0.025), material: SIMD4(0.3, 0, 4, 0), shadow: false) }
        }
        for supply in simulation.supplies {
            let position = supply.position + SIMD3<Float>(0, 0.24 + sin(visualTime * 2.7 + Float(supply.id)) * 0.035, 0)
            appendItem(to: &all, position: position, scale: SIMD3(0.46, 0.34, 0.32), color: SIMD3(0.19, 0.29, 0.23), material: SIMD4(0.65, 0.2, 0, 0), yaw: visualTime * 0.25)
            appendItem(to: &all, position: position + SIMD3(0, 0.18, 0), scale: SIMD3(0.3, 0.018, 0.07), color: SIMD3(0.34, 1, 0.63), material: SIMD4(0.5, 0, 1.3, 0), shadow: false)
        }
        for casing in shells.casings {
            let length: Float = casing.weapon == .sniper ? 0.072 : 0.055
            let radius: Float = casing.weapon == .sniper ? 0.007 : 0.006
            let pose = Self.translation(casing.position) * simd_float4x4(simd_quatf(vector: casing.orientation))
            appendTransformed(to: &all, mesh: 11, transform: pose * Self.scale(SIMD3(radius,length,radius)), color: SIMD3(0.65,0.41,0.14), material: SIMD4(0.25,0.93,0,13), shadow: true)
            appendTransformed(to: &all, mesh: 2, transform: pose * Self.translation(SIMD3(0,-length*0.503,0)) * Self.scale(SIMD3(radius*0.4,0.0006,radius*0.4)), color: SIMD3(0.42,0.36,0.22), material: SIMD4(0.4,0.85,0,13), shadow: false)
        }
        for particle in particles {
            let t = particle.life / particle.duration; let size = particle.scale * (particle.luminous > 0 ? max(0.05, t) : 1.6 - t * 0.6)
            appendItem(to: &all, mesh: 1, position: particle.position, scale: SIMD3(repeating: size), color: particle.tint * max(0.25, t), material: SIMD4(0.9, 0, particle.luminous * t, 0), shadow: false)
        }
        for tracer in tracers { appendBeam(to: &all, from: tracer.start, to: tracer.end, width: tracer.hostile ? 0.013 : 0.008, color: tracer.hostile ? SIMD3(1, 0.23, 0.045) : SIMD3(1, 0.77, 0.3), emissive: 5) }
        if simulation.extractionReady {
            for i in 0..<64 {
                let angle = Float(i) / 64 * 2 * .pi; let next = Float(i + 1) / 64 * 2 * .pi
                let center = simulation.extractionPosition + SIMD3<Float>(0, 0.035, 0)
                appendBeam(to: &all, from: center + SIMD3(sin(angle) * GameMap.extractionRadius, 0, cos(angle) * GameMap.extractionRadius), to: center + SIMD3(sin(next) * GameMap.extractionRadius, 0, cos(next) * GameMap.extractionRadius), width: 0.035, color: SIMD3(0.12, 0.95, 0.56), emissive: 1.5)
            }
        }
        var worldByMesh = [[GPUInstance]](repeating: [], count: meshes.count), shadowByMesh = [[GPUInstance]](repeating: [], count: meshes.count)
        var nearByMesh = [[GPUInstance]](repeating: [], count: meshes.count)
        // Conservative sphere frustum checks keep tall trees and nearby cover
        // visible. Scope narrows the horizontal cone without rebuilding scenery.
        let aspect = size.x / max(size.y, 1); let halfAngle = atan(tan(smoothFOV * .pi / 360) * max(aspect, 1)) + 0.2
        let cosCone = cos(halfAngle)
        // Render and shadow detail are independent. Sparse far crowns still
        // cast foliage silhouettes without resubmitting the dense visible LOD.
        for tree in forest {
            let offset = tree.center - eye, distance = simd_length(offset)
            let visibleTree = distance < tree.radius + 7 || (distance < 360 + tree.radius && simd_dot(offset,forward) + tree.radius > distance*cosCone)
            if visibleTree {
                let lod = distance < (highQuality ? 85 : 60) ? 0 : distance < (highQuality ? 155 : 125) ? 1 : 2
                for item in tree.levels[lod] {
                    let delta = item.center-eye, range = simd_length(delta)
                    if range < item.radius+7 || (range < 360+item.radius && simd_dot(delta,forward)+item.radius > range*cosCone) {
                        worldByMesh[item.mesh].append(item.instance)
                    }
                }
            }
            if farVolume.intersects(center:tree.center,radius:tree.radius+0.3) {
                // LOD2's leaves intentionally have shadow=false for the legacy
                // camera-LOD path. Explicitly include them in this shadow LOD.
                for item in tree.levels[2] where item.shadow || item.mesh == 6 {
                    if farVolume.intersects(center:item.center,radius:item.radius+0.25) { shadowByMesh[item.mesh].append(item.instance) }
                }
            }
            if nearVolume.intersects(center:tree.center,radius:tree.radius+0.3) {
                let lod = distance <= 35 ? 0 : 1
                for item in tree.levels[lod] where item.shadow {
                    if nearVolume.intersects(center:item.center,radius:item.radius+0.25) { nearByMesh[item.mesh].append(item.instance) }
                }
            }
        }
        for item in all {
            if item.shadow {
                // Wind-displaced twig tips need a small conservative margin.
                let shadowRadius = item.radius + 0.25
                if farVolume.intersects(center: item.center, radius: shadowRadius) { shadowByMesh[item.mesh].append(item.instance) }
                if nearVolume.intersects(center: item.center, radius: shadowRadius) { nearByMesh[item.mesh].append(item.instance) }
            }
            let offset = item.center - eye, distance = simd_length(offset)
            if distance < item.radius + 7 || (distance < 360 + item.radius && simd_dot(offset, forward) + item.radius > distance * cosCone) { worldByMesh[item.mesh].append(item.instance) }
        }
        var weaponByMesh = [[GPUInstance]](repeating: [], count: meshes.count)
        var weaponCastersByMesh = [[GPUInstance]](repeating: [], count: meshes.count)
        let weaponBase=weaponTransform(simulation:simulation,eye:simulation.eyePosition,yaw:p.yaw,pitch:p.pitch)
        let weaponCenter=weaponBase*SIMD4<Float>(0,-0.10,-0.25,1)
        let weaponFocus=SIMD3(weaponCenter.x,weaponCenter.y,weaponCenter.z)
        let weaponLightMatrix=Self.orthographic(left:-1.2,right:1.2,bottom:-1.2,top:1.2,near:0.1,far:7)
            * Self.lookAt(eye:weaponFocus+sun*3.5,target:weaponFocus)
        if mode != .menu && !(aiming && simulation.activeWeapon == .sniper) {
            // Use the same unshaken pose as the actual shot/ejection event.
            for item in weapon(simulation: simulation, eye: simulation.eyePosition, yaw: p.yaw, pitch: p.pitch) {
                weaponByMesh[item.mesh].append(item.instance)
                // Flash, reticle and transmissive scope glass cannot cast an
                // opaque shadow across the hand or receiver.
                if item.instance.material.z<=0 && Int(item.instance.material.w+0.5) != 12 { weaponCastersByMesh[item.mesh].append(item.instance) }
            }
        }
        var instances: [GPUInstance] = []
        instances.reserveCapacity(worldByMesh.reduce(0) { $0+$1.count } + shadowByMesh.reduce(0) { $0+$1.count } + nearByMesh.reduce(0) { $0+$1.count } + weaponByMesh.reduce(0) { $0+$1.count } + weaponCastersByMesh.reduce(0) { $0+$1.count })
        func batches(_ source: [[GPUInstance]]) -> [RenderBatch] {
            var result: [RenderBatch] = []
            for mesh in source.indices where !source[mesh].isEmpty {
                let count = source[mesh].count
                guard count > 0 else { continue }
                result.append(RenderBatch(mesh: mesh, offset: instances.count, count: count)); instances.append(contentsOf: source[mesh].prefix(count))
            }; return result
        }
        farShadowInstanceCount = shadowByMesh.reduce(0) { $0+$1.count }
        nearShadowInstanceCount = nearByMesh.reduce(0) { $0+$1.count }
        let shadows = batches(shadowByMesh), nearShadows = batches(nearByMesh)
        let visible = worldByMesh.reduce(0) { $0 + $1.count } + weaponByMesh.reduce(0) { $0+$1.count }, main = batches(worldByMesh), weaponBatches=batches(weaponByMesh), weaponShadowBatches=batches(weaponCastersByMesh)
        let uniform = GPUUniforms(viewProjection: vp, inverseViewProjection: vp.inverse, lightViewProjection: lightMatrix, eyeTime: SIMD4(eye, visualTime), sunDirection: SIMD4(sun, 1), fogColor: SIMD4(fog, 1), viewport: SIMD4(size.x, size.y, 0, 0), nearLightViewProjection: nearVolume.matrix,
                                  shadowParameters: SIMD4(1 / Float(shadowResolution), DirectionalShadowVolume.nearWidth, DirectionalShadowVolume.nearDepth, 0.30))
        return PreparedScene(instances: instances, main: main, shadows: shadows, nearShadows: nearShadows, weapon:weaponBatches,weaponShadows:weaponShadowBatches,weaponLightMatrix:weaponLightMatrix, nearVolume: nearVolume, uniforms: uniform, visibleCount: visible,
                             enemies: simulation.enemies, time: simulation.elapsed, terrain: simulation.terrain, obstacles: simulation.obstacles)
    }
    private func encode(command: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, samples: Int, slot: Int, scene: PreparedScene) {
        // The frame semaphore has granted ownership of this slot before any
        // joint upload. Main and shadow passes share the exact same pose.
        skinnedSoldiers.prepare(enemies: scene.enemies, time: scene.time, terrain: scene.terrain, slot: slot, nearShadow: scene.nearVolume, supportObstacles: scene.obstacles + shellGroundColliders)
        let requiredBytes = scene.instances.count * MemoryLayout<GPUInstance>.stride
        if requiredBytes > buffers[slot].length, let grown = device.makeBuffer(length: requiredBytes + 4096 * MemoryLayout<GPUInstance>.stride, options: .storageModeShared) {
            buffers[slot] = grown
        }
        let instanceBuffer = buffers[slot], uniformBuffer = uniformBuffers[slot]
        guard requiredBytes <= instanceBuffer.length else { return }
        scene.instances.withUnsafeBytes { data in if let source = data.baseAddress { instanceBuffer.contents().copyMemory(from: source, byteCount: data.count) } }
        var uniform = scene.uniforms; withUnsafeBytes(of: &uniform) { uniformBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let shadowPass = MTLRenderPassDescriptor(); shadowPass.depthAttachment.texture = shadowTexture; shadowPass.depthAttachment.loadAction = .clear; shadowPass.depthAttachment.storeAction = .store; shadowPass.depthAttachment.clearDepth = 1
        if let encoder = command.makeRenderCommandEncoder(descriptor: shadowPass) {
            encoder.label = "Sun shadow map"; encoder.setRenderPipelineState(shadowPipeline); encoder.setDepthStencilState(depthState); encoder.setCullMode(.none); encoder.setDepthBias(0.001, slopeScale: 1.5, clamp: 0.01)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 2); encoder.setFragmentTexture(textures[21], index: 0); encoder.setFragmentSamplerState(sampler, index: 0)
            drawBatches(scene.shadows, encoder: encoder, buffer: instanceBuffer)
            skinnedSoldiers.encodeShadow(encoder: encoder, slot: slot)
            encoder.endEncoding()
        }
        let nearTexture = nearShadowTextures[highQuality ? 2048 : 1024]!
        let nearPass = MTLRenderPassDescriptor(); nearPass.depthAttachment.texture = nearTexture
        nearPass.depthAttachment.loadAction = .clear; nearPass.depthAttachment.storeAction = .store; nearPass.depthAttachment.clearDepth = 1
        if let encoder = command.makeRenderCommandEncoder(descriptor: nearPass) {
            encoder.label = "Stabilized near sun shadows"; encoder.setRenderPipelineState(shadowPipeline)
            encoder.setDepthStencilState(depthState); encoder.setCullMode(.none)
            encoder.setDepthBias(0, slopeScale: 0.65, clamp: 0.00015)
            // setVertexBytes owns a copy; never overwrite uniforms used by the far pass.
            var nearUniform = uniform; nearUniform.lightViewProjection = uniform.nearLightViewProjection
            encoder.setVertexBytes(&nearUniform, length: MemoryLayout<GPUUniforms>.stride, index: 2)
            encoder.setFragmentTexture(textures[21], index: 0); encoder.setFragmentSamplerState(sampler, index: 0)
            drawBatches(scene.nearShadows, encoder: encoder, buffer: instanceBuffer)
            skinnedSoldiers.encodeShadow(encoder: encoder, slot: slot, near: true)
            encoder.endEncoding()
        }
        if !scene.weapon.isEmpty {
            let weaponPass=MTLRenderPassDescriptor();weaponPass.depthAttachment.texture=weaponShadowTexture
            weaponPass.depthAttachment.loadAction = .clear;weaponPass.depthAttachment.storeAction = .store;weaponPass.depthAttachment.clearDepth=1
            if let encoder=command.makeRenderCommandEncoder(descriptor:weaponPass) {
                encoder.label="Viewmodel self shadows only";encoder.setRenderPipelineState(shadowPipeline)
                encoder.setDepthStencilState(depthState);encoder.setCullMode(.none)
                encoder.setDepthBias(0,slopeScale:0.65,clamp:0.00015)
                var weaponUniform=uniform;weaponUniform.lightViewProjection=scene.weaponLightMatrix
                encoder.setVertexBytes(&weaponUniform,length:MemoryLayout<GPUUniforms>.stride,index:2)
                encoder.setFragmentTexture(textures[21],index:0);encoder.setFragmentSamplerState(sampler,index:0)
                drawBatches(scene.weaponShadows,encoder:encoder,buffer:instanceBuffer)
                encoder.endEncoding()
            }
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor), let pipeline = pipelines[samples], let skyPipeline = skyPipelines[samples] else { return }
        encoder.label = "Atmosphere and instanced world"; encoder.setCullMode(.none)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 2); encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(textures[23], index: 23); encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setRenderPipelineState(skyPipeline); encoder.setDepthStencilState(skyDepthState); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.setFragmentTexture(shadowTexture, index: 10); encoder.setFragmentTexture(nearTexture, index: 24)
        encoder.setFragmentTexture(scene.weapon.isEmpty ? shadowTexture:weaponShadowTexture,index:31)
        var weaponLight=matrix_identity_float4x4
        encoder.setFragmentBytes(&weaponLight,length:MemoryLayout<simd_float4x4>.stride,index:3)
        encoder.setFragmentSamplerState(sampler, index: 0); encoder.setFragmentSamplerState(shadowSampler, index: 1)
        drawBatches(scene.main, encoder: encoder, buffer: instanceBuffer)
        if !scene.weapon.isEmpty {
            var weaponUniform=uniform;weaponUniform.viewport.z=1
            encoder.setVertexBytes(&weaponUniform,length:MemoryLayout<GPUUniforms>.stride,index:2)
            encoder.setFragmentBytes(&weaponUniform,length:MemoryLayout<GPUUniforms>.stride,index:2)
            weaponLight=scene.weaponLightMatrix
            encoder.setFragmentBytes(&weaponLight,length:MemoryLayout<simd_float4x4>.stride,index:3)
            drawBatches(scene.weapon,encoder:encoder,buffer:instanceBuffer)
            // Soldier palettes/contacts retain the original world uniform block.
            encoder.setVertexBuffer(uniformBuffer,offset:0,index:2)
            encoder.setFragmentBuffer(uniformBuffer,offset:0,index:2)
        }
        skinnedSoldiers.encodeMain(encoder: encoder, samples: samples, slot: slot)
        skinnedSoldiers.encodeContacts(encoder: encoder, samples: samples, slot: slot)
        encoder.endEncoding()
    }
    private func drawBatches(_ batches: [RenderBatch], encoder: MTLRenderCommandEncoder, buffer: MTLBuffer) {
        for batch in batches { let mesh = meshes[batch.mesh]; encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0); encoder.setVertexBuffer(buffer, offset: batch.offset * MemoryLayout<GPUInstance>.stride, index: 1); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count, instanceCount: batch.count) }
    }

    private func buildScenery() {
        var items: [RenderItem] = []; var rng = SeededRandom(seed: 183)
        let metal = SIMD3<Float>(0.17, 0.20, 0.19), concrete = SIMD3<Float>(0.61, 0.63, 0.59)
        appendItem(to: &items, position: SIMD3(0, 0.005, 0), scale: SIMD3(12, 0.02, 91), color: SIMD3(0.8, 0.84, 0.86), material: SIMD4(1, 0, 0, 6), shadow: false)
        for z in stride(from: Float(-39), through: 39, by: 7) { appendItem(to: &items, position: SIMD3(0, 0.0155, z), scale: SIMD3(0.14, 0.001, 2.8), color: SIMD3(0.69, 0.64, 0.43), material: SIMD4(0.9, 0, 0, 0), shadow: false) }
        for x: Float in [-6.2, 6.2] { appendItem(to: &items, position: SIMD3(x, 0.04, 0), scale: SIMD3(0.3, 0.08, 85), color: concrete, material: SIMD4(0.9, 0, 0, 2)) }
        // Mesh fence: fine metal wires cast real shadows and remain legible when
        // the player approaches; all wires share a single instanced draw call.
        func grounded(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, Self.terrainHeight(p.x,p.z), p.z) }
        func fence(_ flatStart: SIMD3<Float>, _ flatEnd: SIMD3<Float>) {
            let start = grounded(flatStart), end = grounded(flatEnd)
            let direction = simd_normalize(end - start); let length = simd_distance(start, end)
            appendBeam(to: &items, from: start + SIMD3(0, 0.15, 0), to: start + SIMD3(0, 3.25, 0), width: 0.065, color: metal)
            appendBeam(to: &items, from: start + SIMD3(0, 2.9, 0), to: end + SIMD3(0, 2.9, 0), width: 0.03, color: metal)
            appendBeam(to: &items, from: start + SIMD3(0, 0.3, 0), to: end + SIMD3(0, 0.3, 0), width: 0.022, color: metal)
            for t in stride(from: Float(0), through: length, by: 0.5) {
                let b = start + direction * t + SIMD3(0, 0.3, 0)
                let left = start + direction * max(0, t - 1.3) + SIMD3(0, 2.9, 0)
                let right = start + direction * min(length, t + 1.3) + SIMD3(0, 2.9, 0)
                appendBeam(to: &items, from: b, to: left, width: 0.009, color: SIMD3(0.32, 0.36, 0.31), shadow: false)
                appendBeam(to: &items, from: b, to: right, width: 0.009, color: SIMD3(0.32, 0.36, 0.31), shadow: false)
            }
        }
        for x: Float in [-38, 38] { for z in stride(from: Float(-42), to: 42, by: 6) { fence(SIMD3(x, 0, z), SIMD3(x, 0, z + 6)) } }
        for z: Float in [-42, 42] { for x in stride(from: Float(-38), to: 34, by: 6) where abs(x + 3) > 7 { fence(SIMD3(x, 0, z), SIMD3(x + 6, 0, z)) } }
        for x: Float in [-10, 10] {
            let floor = Self.terrainHeight(x,-39)
            appendItem(to: &items, position: SIMD3(x, floor+3.8, -39), scale: SIMD3(0.8, 7.6, 0.8), color: concrete, material: SIMD4(0.9, 0, 0, 2))
            appendItem(to: &items, position: SIMD3(x, floor+0.5, -39), scale: SIMD3(1.5, 1, 1.5), color: concrete, material: SIMD4(0.9, 0, 0, 2))
        }
        appendItem(to: &items, position: SIMD3(0, 6.9, -39), scale: SIMD3(20, 1.1, 0.7), color: SIMD3(0.24, 0.29, 0.22), material: SIMD4(0.7, 0.5, 0, 0))
        for x in stride(from: Float(-7.5), through: 7.5, by: 1.5) { appendItem(to: &items, position: SIMD3(x, 6.9, -38.64), scale: SIMD3(0.8, 0.08, 0.02), color: SIMD3(0.9, 0.71, 0.33), material: SIMD4(0.4, 0, 0.3, 0), shadow: false) }
        for flat: SIMD3<Float> in [SIMD3(-32, 0, -36), SIMD3(32, 0, 33)] {
            let p = grounded(flat)
            for dx: Float in [-1.7, 1.7] { for dz: Float in [-1.7, 1.7] { appendItem(to: &items, position: p + SIMD3(dx, 3, dz), scale: SIMD3(0.22, 6, 0.22), color: metal) } }
            appendItem(to: &items, position: p + SIMD3(0, 5.5, 0), scale: SIMD3(4.2, 0.25, 4.2), color: metal)
            appendItem(to: &items, position: p + SIMD3(0, 8, 0), scale: SIMD3(4.8, 0.16, 4.8), color: SIMD3(0.23, 0.30, 0.22))
            for dx: Float in [-2, 2] { appendItem(to: &items, position: p + SIMD3(dx, 6.2, 0), scale: SIMD3(0.1, 1.3, 4), color: SIMD3(0.30, 0.35, 0.28)) }
            appendItem(to: &items, position: p + SIMD3(0, 6.1, -2), scale: SIMD3(4, 1.1, 0.1), color: SIMD3(0.30, 0.35, 0.28))
            for dx: Float in [-0.55, 0.55] { appendItem(to: &items, position: p + SIMD3(dx, 2.8, 2.2), scale: SIMD3(0.08, 5.6, 0.1), color: metal) }
            for y in stride(from: Float(0.4), through: 5.4, by: 0.38) { appendItem(to: &items, position: p + SIMD3(0, y, 2.2), scale: SIMD3(1.1, 0.08, 0.12), color: metal) }
            for dx: Float in [-1.7, 1.7] { appendBeam(to: &items, from: p + SIMD3(dx, 0.3, -1.7), to: p + SIMD3(dx, 5.4, 1.7), width: 0.10, color: metal) }
        }
        for flat: SIMD3<Float> in [SIMD3(-8, 0, 25), SIMD3(9, 0, -17), SIMD3(-11, 0, -31), SIMD3(28, 0, 11)] {
            let p = grounded(flat)
            appendItem(to: &items, mesh: 2, position: p + SIMD3(0, 4.8, 0), scale: SIMD3(0.075, 9.6, 0.075), color: metal)
            appendItem(to: &items, position: p + SIMD3(0.55, 9.2, 0), scale: SIMD3(1.2, 0.1, 0.12), color: metal)
            appendItem(to: &items, position: p + SIMD3(1, 9.1, 0), scale: SIMD3(0.8, 0.09, 0.45), color: SIMD3(1, 0.82, 0.52), material: SIMD4(0.5, 0, 2.4, 0))
        }
        appendItem(to: &items, mesh: 7, position: .zero, scale: SIMD3(repeating: 1), color: SIMD3(0.92, 0.94, 0.88), material: SIMD4(1, 0, 0, 1), shadow: true)
        forest.removeAll(keepingCapacity: true)
        for index in 0..<230 {
            let a = Float(index) * 2.3999632 + rng.next() * 0.4
            let radius: Float = index < 105 ? 55 + rng.next() * 50 : 105 + rng.next() * 100
            let x = cos(a) * radius, z = sin(a) * radius
            if abs(x) < 41 && abs(z) < 47 { continue }
            let p = SIMD3<Float>(x, Self.terrainHeight(x, z), z)
            forest.append(buildTree(position: p, height: 12 + rng.next() * 15, seed: UInt64(index + 421)))
        }
        for i in 0..<25 {
            let a = Float(i) / 25 * .pi * 2, r: Float = 174 + rng.next() * 50
            let s = SIMD3<Float>(16 + rng.next() * 20, 11 + rng.next() * 19, 18 + rng.next() * 24)
            appendItem(to: &items, mesh: 8, position: SIMD3(cos(a) * r, Self.terrainHeight(cos(a) * r, sin(a) * r) - s.y * 0.42, sin(a) * r), scale: s, color: SIMD3(0.86, 0.91, 0.88), material: SIMD4(1, 0, 0, 3), yaw: a, shadow: false)
        }
        for _ in 0..<42 {
            let a = rng.next() * .pi * 2, r: Float = 45 + rng.next() * 45
            let x = cos(a) * r, z = sin(a) * r
            if abs(x) < 40 && abs(z) < 45 { continue }
            let s: Float = 0.7 + rng.next() * 2.8
            appendItem(to: &items, mesh: 8, position: SIMD3(x, Self.terrainHeight(x, z) + s * 0.24, z), scale: SIMD3(s * 1.4, s, s), color: SIMD3(0.83, 0.88, 0.79), material: SIMD4(1, 0, 0, 3), yaw: a)
        }
        for _ in 0..<250 {
            let x = (rng.next() - 0.5) * 130, z = (rng.next() - 0.5) * 130, s = 0.08 + rng.next() * 0.38
            if abs(x) < 6 { continue }
            appendItem(to: &items, mesh: 8, position: SIMD3(x, Self.terrainHeight(x, z) + s * 0.2, z), scale: SIMD3(s, s * 0.5, s * 0.8), color: SIMD3(0.6, 0.62, 0.55), material: SIMD4(1, 0, 0, 3), shadow: false)
        }
        for _ in 0..<1700 {
            var x = (rng.next() - 0.5) * 120; if abs(x) < 7 { x += x < 0 ? -8 : 8 }; let z = (rng.next() - 0.5) * 120
            let s = 0.25 + rng.next() * 0.6, tone = 0.62 + rng.next() * 0.55
            appendItem(to: &items, mesh: 4, position: SIMD3(x, Self.terrainHeight(x, z), z), scale: SIMD3(0.6 + rng.next(), s * 0.6, 1), color: SIMD3(0.26, 0.33, 0.15) * tone, material: SIMD4(1, 0, 0, 8), yaw: rng.next() * .pi * 2, shadow: false)
        }
        scenery = items
    }

    private static func terrainHeight(_ x: Float, _ z: Float) -> Float {
        TerrainProfile.battlefield.height(x: x, z: z)
    }

    private func buildTree(position: SIMD3<Float>, height: Float, seed: UInt64) -> ForestTree {
        var levels: [[RenderItem]] = []
        for lod in 0..<3 {
            var rng = SeededRandom(seed: seed); var parts: [RenderItem] = []
            let lean = (rng.next() - 0.5) * 0.085, rotation = rng.next() * .pi * 2
            let base = Self.translation(position) * Self.rotationY(rotation) * Self.rotationX(lean)
            let trunkRadius = height * (0.012 + rng.next() * 0.005)
            let bark = SIMD3<Float>(0.82, 0.80, 0.74)
            appendTransformed(to: &parts, mesh: 5, transform: base * Self.scale(SIMD3(trunkRadius, height, trunkRadius)), color: bark, material: SIMD4(1, 0, height, 5))
            let tiers = [10, 8, 6][lod], arms = [6, 5, 4][lod], twigs = [5, 4, 3][lod]
            let crownStart: Float = 0.25 + rng.next() * 0.12
            let crownWidth: Float = height * (0.18 + rng.next() * 0.045)
            let tint = SIMD3<Float>(0.68 + rng.next() * 0.19, 0.82 + rng.next() * 0.13, 0.69 + rng.next() * 0.13)
            for tier in 0..<tiers {
                let t = Float(tier) / Float(tiers)
                let y = height * (crownStart + (1 - crownStart) * t)
                // The lower skirt is broken, middle branches spread unevenly,
                // and the upper leader narrows gradually rather than forming a cone.
                let envelope = pow(max(0.04, 1 - t), 0.58)
                for arm in 0..<arms {
                    let azimuth = Float(arm) / Float(arms) * .pi * 2 + Float(tier) * 2.18 + (rng.next() - 0.5) * 0.85
                    if tier < 2 && rng.next() < 0.22 { continue }
                    let length = crownWidth * envelope * (0.70 + rng.next() * 0.48)
                    let radial = SIMD3<Float>(cos(azimuth), 0, sin(azimuth))
                    let slope = -0.22 + t * 0.46 + (rng.next() - 0.5) * 0.3
                    let branchDirection = simd_normalize(radial + SIMD3<Float>(0, slope, 0))
                    let start = SIMD3<Float>(0, y + (rng.next() - 0.5) * 0.65, 0)
                    if lod < 2 {
                        let woodRotation = simd_float4x4(simd_quatf(from: SIMD3<Float>(0, 1, 0), to: branchDirection))
                        appendTransformed(to: &parts, mesh: 5, transform: base * Self.translation(start) * woodRotation * Self.scale(SIMD3(0.04 * (1 - t) + 0.012, length, 0.04 * (1 - t) + 0.012)), color: bark, material: SIMD4(1, 0, length, 5), shadow: lod == 0)
                    }
                    for twig in 0..<twigs {
                        let fraction = 0.22 + Float(twig) / Float(max(1, twigs - 1)) * 0.71
                        let side: Float = twig % 2 == 0 ? -1 : 1
                        let transverse = SIMD3<Float>(-radial.z, 0, radial.x)
                        let origin = start + branchDirection * length * fraction
                        let dir = simd_normalize(radial * 0.65 + transverse * side * (0.35 + rng.next() * 0.55) + SIMD3<Float>(0, 0.2 + rng.next() * 0.42, 0))
                        let orientation = simd_float4x4(simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir))
                        let twigSize = (1.35 + rng.next() * 0.65) * (0.75 + envelope * 0.35) * (lod == 2 ? 1.22 : 1)
                        let roll = Self.rotationY((rng.next() - 0.5) * 2.0)
                        appendTransformed(to: &parts, mesh: 6, transform: base * Self.translation(origin) * orientation * roll * Self.scale(SIMD3(repeating: twigSize)), color: tint * (0.82 + rng.next() * 0.26), material: SIMD4(0.95, 0.58 + fraction * 0.38, 0, 4), shadow: lod < 2)
                        if lod == 0 && twig > 0 {
                            appendTransformed(to: &parts, mesh: 6, transform: base * Self.translation(origin + transverse * side * 0.14) * orientation * Self.rotationY(1.5) * Self.scale(SIMD3(repeating: twigSize * 0.82)), color: tint, material: SIMD4(0.95, 0.70 + fraction * 0.24, 0, 4))
                        }
                    }
                }
            }
            for a in 0..<3 {
                appendTransformed(to: &parts, mesh: 6, transform: base * Self.translation(SIMD3(0, height * 0.93, 0)) * Self.rotationY(Float(a) * 2.094) * Self.scale(SIMD3(repeating: 1.35)), color: tint, material: SIMD4(0.95, 0.96, 0, 4), shadow: lod < 2)
            }
            levels.append(parts)
        }
        return ForestTree(center: position + SIMD3(0, height * 0.5, 0), radius: height * 0.65, levels: levels)
    }

    private func buildCover(_ obstacle: Obstacle) -> [RenderItem] {
        var out: [RenderItem] = []; let p = obstacle.position, s = obstacle.size
        let metal = SIMD3<Float>(0.18, 0.23, 0.22), concrete = SIMD3<Float>(0.66, 0.67, 0.62)
        func box(_ position: SIMD3<Float>, _ scale: SIMD3<Float>, _ color: SIMD3<Float>, material: SIMD4<Float> = SIMD4(0.65, 0.3, 0, 0)) { appendItem(to: &out, position: p + position, scale: scale, color: color, material: material) }
        switch obstacle.kind {
        case .container:
            let color: SIMD3<Float> = obstacle.id % 2 == 0 ? SIMD3(0.46, 0.24, 0.13) : SIMD3(0.19, 0.35, 0.34)
            box(SIMD3(0, s.y * 0.5, 0), s, color, material: SIMD4(0.65, 0.62, 0, 0))
            let longX = s.x > s.z, length = longX ? s.x : s.z
            for t in stride(from: -length * 0.5 + 0.18, to: length * 0.5, by: 0.32) {
                for side: Float in [-1, 1] {
                    let position = longX ? SIMD3(t, s.y * 0.5, side * (s.z * 0.5 + 0.027)) : SIMD3(side * (s.x * 0.5 + 0.027), s.y * 0.5, t)
                    box(position, longX ? SIMD3(0.095, s.y - 0.2, 0.07) : SIMD3(0.07, s.y - 0.2, 0.095), color * 0.92)
                }
            }
            for y: Float in [0.09, s.y - 0.09] { for side: Float in [-1, 1] { box(SIMD3(0, y, side * s.z * 0.5), SIMD3(s.x + 0.07, 0.14, 0.1), metal) } }
            for x in [-s.x * 0.5, s.x * 0.5] { for z in [-s.z * 0.5, s.z * 0.5] { box(SIMD3(x, s.y * 0.5, z), SIMD3(0.14, s.y, 0.14), metal) } }
            for x: Float in [-0.65, 0.65] { box(SIMD3(x, s.y * 0.5, s.z * 0.5 + 0.09), SIMD3(0.045, s.y - 0.35, 0.045), metal) }
            // The main shell already supplies the roof at the collision height.
            // A second raised plate would bury feet and contact shadows.
            box(SIMD3(0, 2.1, s.z * 0.5 + 0.056), SIMD3(min(2, s.x - 0.3), 0.46, 0.022), SIMD3(0.72, 0.69, 0.52))
            for x: Float in [-0.6, -0.25, 0.1, 0.45] { box(SIMD3(x, 2.1, s.z * 0.5 + 0.075), SIMD3(0.12, 0.22, 0.01), metal) }
        case .bunker:
            let roofThickness = min(0.3, s.y * 0.5), wallHeight = s.y - roofThickness
            box(SIMD3(0, wallHeight * 0.5, 0), SIMD3(s.x, wallHeight, s.z), concrete, material: SIMD4(0.92, 0, 0, 2))
            box(SIMD3(0, s.y - roofThickness * 0.5, 0), SIMD3(s.x + 0.65, roofThickness, s.z + 0.65), concrete * 0.8, material: SIMD4(0.9, 0, 0, 2))
            box(SIMD3(0, 0.25, 0), SIMD3(s.x + 0.25, 0.5, s.z + 0.25), concrete * 0.65, material: SIMD4(1, 0, 0, 3))
            for x in [-s.x * 0.32, 0, s.x * 0.32] {
                box(SIMD3(x, s.y * 0.66, s.z * 0.5 + 0.045), SIMD3(2.4, 1.4, 0.11), SIMD3(0.045, 0.08, 0.09), material: SIMD4(0.17, 0.8, 0, 0))
                for dx: Float in [-1.1, 0, 1.1] { box(SIMD3(x + dx, s.y * 0.66, s.z * 0.5 + 0.12), SIMD3(0.075, 1.45, 0.08), metal) }
                box(SIMD3(x, s.y * 0.66, s.z * 0.5 + 0.13), SIMD3(2.4, 0.06, 0.08), metal)
            }
            box(SIMD3(-s.x * 0.3, 1.24, s.z * 0.5 + 0.07), SIMD3(1.5, 2.48, 0.13), SIMD3(0.2, 0.28, 0.22))
            box(SIMD3(-s.x * 0.3 + 0.54, 1.1, s.z * 0.5 + 0.16), SIMD3(0.1, 0.1, 0.15), metal)
            for x in stride(from: -s.x * 0.5 + 1, to: s.x * 0.5, by: 2.7) { box(SIMD3(x, s.y * 0.5, s.z * 0.5 + 0.012), SIMD3(0.025, s.y, 0.021), metal * 1.4) }
            for y in stride(from: Float(1), to: s.y, by: 1.1) { box(SIMD3(0, y, s.z * 0.5 + 0.012), SIMD3(s.x, 0.024, 0.021), metal * 1.4) }
            box(SIMD3(1.6, s.y + 0.55, 1), SIMD3(2.5, 1, 2), metal)
            for x in stride(from: Float(0.55), to: 2.6, by: 0.16) { box(SIMD3(x, s.y + 0.56, 2.01), SIMD3(0.05, 0.7, 0.03), metal * 0.5) }
        case .barrier:
            box(SIMD3(0, s.y * 0.5, 0), s, concrete, material: SIMD4(0.98, 0, 0, 2))
            box(SIMD3(0, 0.13, 0), SIMD3(s.x + 0.13, 0.26, s.z + 0.26), concrete * 0.8, material: SIMD4(1, 0, 0, 2))
            for x in stride(from: -s.x * 0.5 + 0.32, to: s.x * 0.5, by: 0.78) {
                for side: Float in [-1, 1] { box(SIMD3(x, s.y * 0.71, side * (s.z * 0.5 + 0.009)), SIMD3(0.42, 0.20, 0.018), SIMD3(0.72, 0.53, 0.16)) }
            }
        case .crate:
            let wood = SIMD3<Float>(0.42, 0.33, 0.18)
            box(SIMD3(0, s.y * 0.5, 0), s, wood, material: SIMD4(0.98, 0, 0, 0))
            for x in [-s.x * 0.42, s.x * 0.42] { for side: Float in [-1, 1] { box(SIMD3(x, s.y * 0.5, side * (s.z * 0.5 + 0.028)), SIMD3(0.15, s.y, 0.07), wood * 1.18) } }
            for y in stride(from: Float(0.08), to: s.y, by: 0.29) { for side: Float in [-1, 1] { box(SIMD3(0, y, side * (s.z * 0.5 + 0.01)), SIMD3(s.x, 0.022, 0.028), wood * 0.58) } }
            for x in [-s.x * 0.28, s.x * 0.28] { box(SIMD3(x, s.y + 0.028, 0), SIMD3(0.07, 0.045, s.z), metal) }
        case .barrel:
            appendItem(to: &out, mesh: 2, position: p + SIMD3(0, s.y * 0.5, 0), scale: SIMD3(s.x * 0.5, s.y, s.z * 0.5), color: SIMD3(0.47, 0.18, 0.095), material: SIMD4(0.54, 0.65, 0, 0))
            for y in [s.y * 0.1, s.y * 0.3, s.y * 0.72, s.y * 0.96] { appendItem(to: &out, mesh: 2, position: p + SIMD3(0, y, 0), scale: SIMD3(s.x * 0.515, 0.045, s.z * 0.515), color: metal) }
            box(SIMD3(0, 0.65, s.z * 0.5 + 0.01), SIMD3(0.23, 0.25, 0.017), SIMD3(0.9, 0.63, 0.1))
        }
        return out
    }

    private func soldierWeapon(_ enemy: EnemyState, time: Double) -> [RenderItem] {
        var result: [RenderItem] = []
        let parts = SoldierModel.weaponParts(enemy: enemy, time: time)
        result.reserveCapacity(parts.count)
        for part in parts {
            appendTransformed(to: &result, mesh: part.mesh, transform: part.transform,
                              color: part.color, material: part.material, shadow: part.castsShadow)
        }
        return result
    }

    private struct WeaponParts {
        var fixed: [RenderItem]
        var magazine: [RenderItem]
        var leftHand: [RenderItem]
        var rightHand: [RenderItem]
        var chargingHandle: [RenderItem]
    }

    private func reloadPose(_ simulation: CombatSimulation) -> WeaponReloadPose {
        let remaining=simulation.weapons[simulation.activeWeapon]?.reloadRemaining ?? 0
        return WeaponReloadPose(progress: remaining > 0 ? 1-remaining/simulation.activeWeapon.reloadDuration : 0, kind: simulation.activeWeapon)
    }

    private func weaponTransform(simulation: CombatSimulation, eye: SIMD3<Float>, yaw: Float, pitch: Float, wallAmount: Float? = nil) -> simd_float4x4 {
        let sniper=simulation.activeWeapon == .sniper, wall=wallAmount ?? weaponWallBlend
        let aim=weaponAimBlend*(1-wall), presentation=reloadPose(simulation).presentationBlend
        let bob:Float=(simulation.isMoving ? sin(visualTime*8)*0.004 : sin(visualTime*1.4)*0.001)*(1-aim*0.8)
        let sprintDrop:Float=simulation.isSprinting ? 0.10:0
        let aimHeight:Float=sniper ? -0.114:-0.095
        let offset=SIMD3<Float>(0.19*(1-aim)-presentation*0.045,
            -0.205+(aimHeight+0.205)*aim+bob-sprintDrop+presentation*0.085-wall*0.07,
            -0.40+aim*0.20+recoil*0.038-presentation*0.12+wall*0.30)
        let sway=sin(visualTime*1.05)*0.004*(1-aim)
        return Self.translation(eye) * Self.rotationY(yaw) * Self.rotationX(pitch) * Self.translation(offset)
            * Self.rotationX(recoil*(0.065-aim*0.038)+presentation*0.22+wall*1.36)
            * Self.rotationZ(-0.055*(1-aim)+sway-presentation*0.56+wall*0.12)
    }
    private func weapon(simulation: CombatSimulation, eye: SIMD3<Float>, yaw: Float, pitch: Float) -> [RenderItem] {
        let kind=simulation.activeWeapon
        if weaponParts[kind] == nil { weaponParts[kind]=makeWeaponParts(kind) }
        guard let parts=weaponParts[kind] else { return [] }
        let base=weaponTransform(simulation:simulation,eye:eye,yaw:yaw,pitch:pitch)
        var out:[RenderItem]=[]; out.reserveCapacity(parts.fixed.count+parts.magazine.count+parts.leftHand.count+parts.rightHand.count+12)
        func transformed(_ group:[RenderItem],_ matrix:simd_float4x4) {
            for item in group {
                let tint=item.instance.tint
                appendTransformed(to:&out,mesh:item.mesh,transform:matrix*item.instance.model,color:SIMD3(tint.x,tint.y,tint.z),material:item.instance.material,shadow:false)
            }
        }
        let reload=reloadPose(simulation), leftPose=base*reload.supportHandTransform
        transformed(parts.fixed,base); transformed(parts.rightHand,base)
        transformed(parts.magazine,base*reload.magazineTransform)
        transformed(parts.leftHand,leftPose)
        transformed(parts.chargingHandle,base*Self.translation(SIMD3(0,0,reload.slideOffset)))
        // Hands follow their grip points; the sleeves connect those wrists to
        // elbows below the camera, instead of moving a rigid arm as one object.
        let camera=Self.translation(eye)*Self.rotationY(yaw)*Self.rotationX(pitch)
        func forearm(wrist:SIMD3<Float>,pose:simd_float4x4,elbow:SIMD3<Float>,maximumLength:Float) {
            let w=pose*SIMD4(wrist,1),e=camera*SIMD4(elbow,1)
            let end=SIMD3(w.x,w.y,w.z),towardsElbow=SIMD3(e.x,e.y,e.z)-end
            let length=min(maximumLength,simd_length(towardsElbow))
            guard length>0.001 else { return }
            let start=end+simd_normalize(towardsElbow)*length
            let rotation=simd_float4x4(simd_quatf(from:SIMD3<Float>(0,1,0),to:(end-start)/length))
            appendTransformed(to:&out,mesh:14,transform:Self.translation((start+end)*0.5)*rotation*Self.scale(SIMD3(0.032,length,0.029)),color:SIMD3(0.24,0.27,0.20),material:SIMD4(0.94,0,0,16),shadow:false)
            appendTransformed(to:&out,mesh:2,transform:Self.translation(end)*rotation*Self.scale(SIMD3(0.023,0.023,0.021)),color:SIMD3(0.08,0.10,0.075),material:SIMD4(0.9,0,0,10),shadow:false)
        }
        forearm(wrist:SIMD3(-0.040,-0.054,-0.281),pose:leftPose,elbow:SIMD3(-0.14,-0.57,0.04),maximumLength:0.34)
        forearm(wrist:SIMD3(0.035,-0.097,0.061),pose:base,elbow:SIMD3(0.32,-0.55,0.05),maximumLength:0.31)
        // The bolt moves independently in the real ejection opening on each shot.
        let cycling=max(0,1-shotAge/0.095),slide=max(cycling*0.055,reload.slideOffset)
        appendTransformed(to:&out,mesh:9,transform:base * Self.translation(SIMD3(0.027,0.025,-0.115+slide)) * Self.scale(SIMD3(0.019,0.025,0.047)),color:SIMD3(0.19,0.21,0.21),material:SIMD4(0.27,0.85,0,9),shadow:false)
        if kind == .sniper {
            appendTransformed(to:&out,mesh:2,transform:base * Self.translation(SIMD3(0.058,0.009,-0.028+slide)) * Self.rotationZ(.pi/2) * Self.scale(SIMD3(0.006,0.06,0.006)),color:SIMD3(0.15,0.17,0.17),material:SIMD4(0.28,0.85,0,9),shadow:false)
            appendTransformed(to:&out,mesh:1,transform:base * Self.translation(SIMD3(0.088,0.009,-0.028+slide)) * Self.scale(SIMD3(repeating:0.013)),color:SIMD3(0.07,0.085,0.085),material:SIMD4(0.5,0.4,0,9),shadow:false)
        }
        if flash > 0 {
            let muzzle:Float=kind == .sniper ? -0.92:-0.72
            appendTransformed(to:&out,mesh:1,transform:base * Self.translation(SIMD3(0,0.019,muzzle-0.055)) * Self.scale(SIMD3(0.025+flash*0.15,0.022+flash*0.1,0.075)),color:SIMD3(1,0.56,0.10),material:SIMD4(0.5,0,4,0),shadow:false)
        }
        return out
    }

    private func makeWeaponParts(_ kind:WeaponKind) -> WeaponParts {
        var fixed:[RenderItem]=[],magazine:[RenderItem]=[],left:[RenderItem]=[],right:[RenderItem]=[],chargingHandle:[RenderItem]=[]
        let sniper=kind == .sniper
        let metal=SIMD3<Float>(0.085,0.095,0.092), steel=SIMD3<Float>(0.19,0.205,0.21), dark=SIMD3<Float>(0.035,0.045,0.042)
        let polymer=SIMD3<Float>(0.24,0.255,0.20), glove=SIMD3<Float>(0.095,0.12,0.095), rubber=SIMD3<Float>(0.042,0.05,0.043)
        let m=SIMD4<Float>(0.54,0.18,0,15), p=SIMD4<Float>(0.76,0.03,0,10), g=SIMD4<Float>(0.93,0,0,16)
        func part(_ group:inout[RenderItem],_ position:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,mesh:Int=9,material:SIMD4<Float>?=nil,rx:Float=0,ry:Float=0,rz:Float=0) {
            appendTransformed(to:&group,mesh:mesh,transform:Self.translation(position)*Self.rotationX(rx)*Self.rotationY(ry)*Self.rotationZ(rz)*Self.scale(size),color:color,material:material ?? m,shadow:false)
        }
        // Sculpted lower receiver, separate upper shoulders and actual port void.
        part(&fixed,SIMD3(0,-0.014,-0.105),SIMD3(0.059,0.073,sniper ? 0.31:0.265),metal,mesh:12)
        part(&fixed,SIMD3(-0.016,0.028,-0.12),SIMD3(0.042,0.046,sniper ? 0.30:0.26),metal)
        part(&fixed,SIMD3(0.022,0.030,-0.195),SIMD3(0.023,0.047,0.073),metal)
        part(&fixed,SIMD3(0.022,0.030,-0.034),SIMD3(0.023,0.047,0.08),metal)
        part(&fixed,SIMD3(0.022,0.049,-0.115),SIMD3(0.027,0.009,0.095),steel)
        part(&fixed,SIMD3(0.030,0.005,-0.114),SIMD3(0.025,0.008,0.102),steel)
        part(&fixed,SIMD3(0.010,0.026,-0.114),SIMD3(0.004,0.038,0.105),dark,material:p)
        // Hinged dust cover below the port; ejector deflector and charging handle.
        part(&fixed,SIMD3(0.038,-0.006,-0.115),SIMD3(0.006,0.035,0.090),metal,rz:-0.9)
        part(&fixed,SIMD3(0.038,0.013,-0.058),SIMD3(0.018,0.027,0.027),steel,ry:0.32)
        part(&chargingHandle,SIMD3(0,0.046,0.035),SIMD3(0.072,0.010,0.016),dark)
        // Takedown pins, fire selector, trigger guard and an actual curved trigger.
        for z:Float in [-0.18,-0.025] { for side:Float in [-1,1] {
            part(&fixed,SIMD3(side*0.031,-0.014,z),SIMD3(0.004,0.006,0.004),steel,mesh:2,rz:.pi/2)
            part(&fixed,SIMD3(side*0.035,-0.014,z),SIMD3(0.0015,0.004,0.001),dark,rz:.pi/2)
        } }
        part(&fixed,SIMD3(-0.032,-0.022,0.017),SIMD3(0.006,0.026,0.010),steel,rx:-0.7)
        part(&fixed,SIMD3(0,-0.054,-0.058),SIMD3(0.034,0.009,0.067),dark)
        for z:Float in [-0.084,-0.032] { part(&fixed,SIMD3(0,-0.035,z),SIMD3(0.03,0.04,0.008),dark) }
        part(&fixed,SIMD3(0,-0.034,-0.05),SIMD3(0.008,0.03,0.009),steel,rx:0.24)
        // Stock has a narrow buffer tube and open struts rather than a solid slab.
        part(&fixed,SIMD3(0,0.009,0.10),SIMD3(0.020,0.19,0.020),metal,mesh:2,rx:.pi/2)
        part(&fixed,SIMD3(0,0.023,0.15),SIMD3(0.05,0.047,0.125),polymer,material:p)
        part(&fixed,SIMD3(0,-0.046,0.18),SIMD3(0.038,0.018,0.11),polymer,material:p,rx:-0.27)
        part(&fixed,SIMD3(0,-0.010,0.223),SIMD3(0.054,0.127,0.032),rubber,material:g,rx:-0.10)
        for y in stride(from:Float(-0.055),through:0.036,by:0.013) { part(&fixed,SIMD3(0,y,0.242),SIMD3(0.045,0.005,0.004),dark,material:g) }
        // Pistol grip and curved detachable magazine.
        part(&fixed,SIMD3(0,-0.090,0.007),SIMD3(0.034,0.12,0.051),polymer,material:p,rx:-0.23)
        for y in stride(from:Float(-0.12),through:-0.05,by:0.017) { part(&fixed,SIMD3(0,y,0.038),SIMD3(0.03,0.005,0.006),dark,material:g) }
        let magazineY:Float=sniper ? -0.096:-0.132,magazineHeight:Float=sniper ? 0.105:0.185
        part(&magazine,SIMD3(0,magazineY,-0.142),SIMD3(sniper ? 0.05:0.041,magazineHeight,0.073),sniper ? metal:polymer,mesh:13,material:sniper ? m:p)
        part(&magazine,SIMD3(0,magazineY-magazineHeight*0.5,-0.117),SIMD3(sniper ? 0.055:0.046,0.014,0.081),dark,material:p)
        for side:Float in [-1,1] { for row in 0..<(sniper ? 3:5) {
            let t=Float(row)/5,z:Float = -0.142+t*t*0.025
            part(&magazine,SIMD3(side*(sniper ? 0.0255:0.021),magazineY+magazineHeight*0.35-t*magazineHeight*0.8,z),SIMD3(0.003,0.008,0.060),dark,material:p)
        } }
        // Octagonal-looking handguard with separate shoulders, slots and clamps.
        let foreLength:Float=sniper ? 0.33:0.29,foreCenter:Float = -0.365
        part(&fixed,SIMD3(0,0.012,foreCenter),SIMD3(0.066,0.066,foreLength),sniper ? polymer:metal,mesh:12,material:sniper ? p:m)
        for side:Float in [-1,1] { for row in 0..<5 {
            let z:Float = -0.475+Float(row)*0.044
            part(&fixed,SIMD3(side*0.0334,0.015,z),SIMD3(0.003,0.019,0.028),dark,material:p)
            part(&fixed,SIMD3(side*0.0345,-0.009,z),SIMD3(0.003,0.005,0.026),steel)
        } }
        // Consistent 21 mm top rail, with short transverse lugs.
        part(&fixed,SIMD3(0,0.056,-0.245),SIMD3(0.034,0.011,0.49),dark)
        for z in stride(from:Float(-0.475),through:0.025,by:0.016) { part(&fixed,SIMD3(0,0.064,z),SIMD3(0.039,0.009,0.007),steel) }
        let muzzle:Float=sniper ? -0.92:-0.72
        part(&fixed,SIMD3(0,0.019,(muzzle-0.49)*0.5),SIMD3(sniper ? 0.013:0.010,abs(muzzle+0.49),sniper ? 0.013:0.010),steel,mesh:2,rx:.pi/2)
        part(&fixed,SIMD3(0,0.019,muzzle+0.027),SIMD3(sniper ? 0.021:0.017,0.062,sniper ? 0.021:0.017),dark,mesh:10,rx:.pi/2)
        part(&fixed,SIMD3(0,0.019,muzzle+0.056),SIMD3(0.013,0.005,0.013),dark,mesh:2,rx:.pi/2)
        for z:Float in [muzzle+0.015,muzzle+0.036] { for side:Float in [-1,1] { part(&fixed,SIMD3(side*(sniper ? 0.021:0.017),0.019,z),SIMD3(0.002,0.017,0.008),rubber,material:g) } }
        if sniper {
            for z:Float in [-0.225,-0.054] { part(&fixed,SIMD3(0,0.087,z),SIMD3(0.027,0.047,0.028),metal); part(&fixed,SIMD3(0,0.11,z),SIMD3(0.032,0.024,0.032),steel,mesh:10,rx:.pi/2) }
            part(&fixed,SIMD3(0,0.114,-0.16),SIMD3(0.029,0.315,0.029),dark,mesh:2,rx:.pi/2)
            part(&fixed,SIMD3(0,0.114,-0.337),SIMD3(0.044,0.086,0.044),dark,mesh:10,rx:.pi/2)
            part(&fixed,SIMD3(0,0.114,0.011),SIMD3(0.037,0.065,0.037),dark,mesh:10,rx:.pi/2)
            for z:Float in [-0.366,0.035] { part(&fixed,SIMD3(0,0.114,z),SIMD3(z<0 ? 0.037:0.030,0.018,z<0 ? 0.037:0.030),SIMD3(0.012,0.032,0.031),mesh:15,material:SIMD4(0.10,0,0,12),rx:z<0 ? -.pi/2:.pi/2) }
            part(&fixed,SIMD3(0,0.153,-0.16),SIMD3(0.019,0.034,0.019),steel,mesh:2)
            part(&fixed,SIMD3(0.037,0.118,-0.16),SIMD3(0.015,0.031,0.015),steel,mesh:2,rz:.pi/2)
            for i in 0..<16 { let a=Float(i) * .pi/8; part(&fixed,SIMD3(cos(a)*0.0195,0.157,-0.16+sin(a)*0.0195),SIMD3(0.002,0.024,0.002),dark) }
            // Folded bipod below the extended fore-end.
            for side:Float in [-1,1] { part(&fixed,SIMD3(side*0.031,-0.029,-0.48),SIMD3(0.008,0.16,0.008),steel,mesh:2,rx:.pi/2,ry:side*0.1) }
        } else {
            // Open circular reflex housing. The sight line remains genuinely open.
            part(&fixed,SIMD3(0,0.073,-0.09),SIMD3(0.033,0.022,0.050),dark)
            part(&fixed,SIMD3(0,0.097,-0.09),SIMD3(0.025,0.038,0.025),metal,mesh:10,rx:.pi/2)
            part(&fixed,SIMD3(0.031,0.092,-0.086),SIMD3(0.009,0.021,0.009),steel,mesh:2,rz:.pi/2)
            part(&fixed,SIMD3(0,0.095,-0.106),SIMD3(repeating:0.0015),SIMD3(1,0.055,0.01),mesh:1,material:SIMD4(0.5,0,2,0))
            part(&fixed,SIMD3(0,0.071,-0.49),SIMD3(0.006,0.025,0.006),steel)
        }
        // Anatomical palms, separate finger phalanges and narrow sleeve cuffs.
        func hand(_ group:inout[RenderItem],leftHand:Bool) {
            let center=leftHand ? SIMD3<Float>(-0.032,-0.036,-0.327):SIMD3<Float>(0.026,-0.079,0.015)
            part(&group,center,SIMD3(0.044,0.029,0.078),glove,material:g,rz:leftHand ? -0.3:0.6)
            part(&group,center+SIMD3(leftHand ? -0.008:0.015,-0.017,0.047),SIMD3(0.049,0.036,0.029),rubber,material:g)
            for i in 0..<4 {
                let z=center.z-0.032+Float(i)*0.017
                let y=center.y+Float(i%2)*0.002
                part(&group,SIMD3(center.x+0.023,y,z),SIMD3(0.018,0.014,0.013),glove,material:g,rz:-0.35)
                part(&group,SIMD3(center.x+0.030,y+0.012,z-0.002),SIMD3(0.013,0.023,0.012),glove,material:g,rz:-0.1)
                part(&group,SIMD3(center.x+0.022,y+0.024,z-0.003),SIMD3(0.016,0.012,0.011),rubber,material:g,rz:0.4)
            }
            part(&group,center+SIMD3(-0.017,0.021,0.012),SIMD3(0.016,0.017,0.039),glove,material:g,ry:-0.4)
        }
        hand(&left,leftHand:true); hand(&right,leftHand:false)
        return WeaponParts(fixed:fixed,magazine:magazine,leftHand:left,rightHand:right,chargingHandle:chargingHandle)
    }

    private func spark(at position: SIMD3<Float>, count: Int, explosive: Bool) {
        for i in 0..<count {
            let a = random.next() * .pi * 2, speed: Float = explosive ? 2 + random.next() * 10 : 0.8 + random.next() * 3
            let luminous = explosive && i % 3 != 0
            let life: Float = explosive ? (luminous ? 0.3 + random.next() * 0.5 : 1.2 + random.next() * 1.4) : 0.2 + random.next() * 0.5
            particles.append(Particle(position: position, velocity: SIMD3(cos(a) * speed, 1.0 + random.next() * speed, sin(a) * speed), life: life, duration: life, scale: explosive ? (luminous ? 0.14 + random.next() * 0.26 : 0.09 + random.next() * 0.18) : 0.012 + random.next() * 0.025, tint: luminous ? SIMD3(1, 0.25 + random.next() * 0.4, 0.015) : SIMD3(0.25, 0.24, 0.20), luminous: luminous ? 5 : 0, gravity: luminous ? 5 : 12))
        }
    }
    func advanceEffects(deltaTime: Float, simulation: CombatSimulation) {
        let dt = min(0.1, max(0, deltaTime))
        weaponAimBlend += ((simulation.isAiming ? 1:0)-weaponAimBlend)*(1-exp(-dt*18))
        let target=weaponClearance(simulation)
        // Safety is immediate on approach; only recovery is smoothed, so a
        // sprint or sudden turn cannot leave the barrel inside nearby cover.
        if target>weaponWallBlend { weaponWallBlend=target }
        else { weaponWallBlend += (target-weaponWallBlend)*(1-exp(-dt*12)) }
        updateEffects(deltaTime: dt, terrain: simulation.terrain)
        shotAge += dt
        shellCollisionCache.removeAll(keepingCapacity: true)
        shellCollisionCache.append(contentsOf: simulation.obstacles)
        shellCollisionCache.append(contentsOf: shellGroundColliders)
        shellImpacts.append(contentsOf: shells.step(deltaTime: dt, obstacles: shellCollisionCache, terrain: simulation.terrain))
        if shellImpacts.count > 128 { shellImpacts.removeFirst(shellImpacts.count - 128) }
    }
    private func weaponClearance(_ simulation: CombatSimulation) -> Float {
        let pose=weaponTransform(simulation:simulation,eye:simulation.eyePosition,yaw:simulation.player.yaw,pitch:simulation.player.pitch,wallAmount:0)
        let end=pose*SIMD4<Float>(0,0.019,simulation.activeWeapon == .sniper ? -0.924:-0.724,1)
        let ray=SIMD3(end.x,end.y,end.z)-simulation.eyePosition,length=simd_length(ray)
        if length>0.001 {
            let distance=simulation.visualWallDistance(origin:simulation.eyePosition,direction:ray/length,maximumDistance:length+0.12,padding:0.065)
            let intrusion=max(0,length+0.10-distance)
            return min(1,intrusion/0.54)
        }
        return 0
    }
    func drainShellImpacts() -> [ShellImpact] {
        let impacts = shellImpacts; shellImpacts.removeAll(keepingCapacity: true); return impacts
    }
    private func updateEffects(deltaTime: Float, terrain: TerrainProfile) {
        visualTime += deltaTime; recoil *= exp(-deltaTime * 12); shake *= exp(-deltaTime * 7); flash = max(0, flash - deltaTime)
        for i in particles.indices {
            particles[i].life -= deltaTime; particles[i].velocity.y -= particles[i].gravity * deltaTime; particles[i].position += particles[i].velocity * deltaTime
            let ground = terrain.height(x: particles[i].position.x, z: particles[i].position.z) + 0.035
            if particles[i].position.y < ground { particles[i].position.y = ground; particles[i].velocity.y *= -0.25; particles[i].velocity.x *= 0.7; particles[i].velocity.z *= 0.7 }
        }
        particles.removeAll { $0.life <= 0 }
        for i in tracers.indices { tracers[i].life -= deltaTime }; tracers.removeAll { $0.life <= 0 }
    }

    private func appendItem(to items: inout [RenderItem], mesh: Int = 0, position: SIMD3<Float>, scale: SIMD3<Float>, color: SIMD3<Float>, material: SIMD4<Float> = SIMD4(0.7, 0.4, 0, 0), yaw: Float = 0, shadow: Bool = true) {
        appendTransformed(to: &items, mesh: mesh, transform: Self.translation(position) * Self.rotationY(yaw) * Self.scale(scale), color: color, material: material, shadow: shadow)
    }
    private func appendTransformed(to items: inout [RenderItem], mesh: Int, transform: simd_float4x4, color: SIMD3<Float>, material: SIMD4<Float>, shadow: Bool = true) {
        let a = SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z), b = SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z), c = SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let normals = simd_float3x3(columns: (a, b, c)).inverse.transpose
        let bounds = meshes[mesh]
        let localCenter = SIMD4<Float>(bounds.boundsCenter,1)
        let worldCenter = transform * localCenter
        let center = SIMD3(worldCenter.x, worldCenter.y, worldCenter.z)
        let instance = GPUInstance(model: transform, normal0: SIMD4(normals.columns.0, 0), normal1: SIMD4(normals.columns.1, 0), normal2: SIMD4(normals.columns.2, 0), tint: SIMD4(color, 1), material: material)
        let e=bounds.halfExtents
        // Model transforms may combine rotation and nonuniform scaling. This
        // transformed AABB encloses every vertex, including lathed rims.
        let radius = simd_length(simd_abs(a)*e.x + simd_abs(b)*e.y + simd_abs(c)*e.z)
        items.append(RenderItem(mesh: mesh, instance: instance, center: center, radius: radius, shadow: shadow))
    }
    private func appendBeam(to items: inout [RenderItem], from: SIMD3<Float>, to: SIMD3<Float>, width: Float, color: SIMD3<Float>, emissive: Float = 0, shadow: Bool = true) {
        let offset = to - from, length = simd_length(offset); guard length > 0.0001 else { return }
        let direction = offset / length
        let rotation = simd_float4x4(simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction))
        appendTransformed(to: &items, mesh: 0, transform: Self.translation((from + to) * 0.5) * rotation * Self.scale(SIMD3(width, length, width)), color: color, material: SIMD4(0.65, 0.5, emissive, 0), shadow: shadow && emissive == 0)
    }

    private static func translation(_ v: SIMD3<Float>) -> simd_float4x4 { var m = matrix_identity_float4x4; m.columns.3 = SIMD4(v, 1); return m }
    private static func scale(_ v: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(v, 1)) }
    private static func rotationY(_ angle: Float) -> simd_float4x4 { let c = cos(angle), s = sin(angle); return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))) }
    private static func rotationX(_ angle: Float) -> simd_float4x4 { let c = cos(angle), s = sin(angle); return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))) }
    private static func rotationZ(_ angle: Float) -> simd_float4x4 { let c=cos(angle),s=sin(angle); return simd_float4x4(columns:(SIMD4(c,s,0,0),SIMD4(-s,c,0,0),SIMD4(0,0,1,0),SIMD4(0,0,0,1))) }
    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target), x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z)), y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0), SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }
    private static func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fov * 0.5), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }
    private static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(2 / (right - left), 0, 0, 0), SIMD4(0, 2 / (top - bottom), 0, 0), SIMD4(0, 0, 1 / (near - far), 0), SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), near / (near - far), 1)))
    }

    private static func makeMeshes(device: MTLDevice) throws -> [Mesh] {
        var cube: [GPUVertex] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))]
        let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1)]
        for (normal, tangent, bitangent) in faces { for uv in corners { cube.append(GPUVertex(position: normal * 0.5 + tangent * (uv.x - 0.5) + bitangent * (uv.y - 0.5), normal: normal, uv: uv)) } }
        var sphere: [GPUVertex] = []
        func sphereVertex(_ u: Float, _ v: Float) -> GPUVertex { let a = u * .pi * 2, b = v * .pi; let p = SIMD3<Float>(sin(b) * cos(a), cos(b), sin(b) * sin(a)); return GPUVertex(position: p, normal: p, uv: SIMD2(u, v)) }
        for y in 0..<8 { for x in 0..<12 { for uv in corners { sphere.append(sphereVertex((Float(x) + uv.x) / 12, (Float(y) + uv.y) / 8)) } } }
        var cylinder: [GPUVertex] = []
        for i in 0..<16 {
            let a = Float(i) / 16 * .pi * 2, b = Float(i + 1) / 16 * .pi * 2
            let n0 = SIMD3<Float>(cos(a), 0, sin(a)), n1 = SIMD3<Float>(cos(b), 0, sin(b))
            let p0 = n0 + SIMD3(0, -0.5, 0), p1 = n1 + SIMD3(0, -0.5, 0), p2 = n1 + SIMD3(0, 0.5, 0), p3 = n0 + SIMD3(0, 0.5, 0)
            cylinder.append(contentsOf: [GPUVertex(position: p0, normal: n0, uv: SIMD2(0, 0)), GPUVertex(position: p1, normal: n1, uv: SIMD2(1, 0)), GPUVertex(position: p2, normal: n1, uv: SIMD2(1, 1)), GPUVertex(position: p0, normal: n0, uv: SIMD2(0, 0)), GPUVertex(position: p2, normal: n1, uv: SIMD2(1, 1)), GPUVertex(position: p3, normal: n0, uv: SIMD2(0, 1))])
            for y: Float in [-0.5, 0.5] { let normal = SIMD3<Float>(0, y * 2, 0); for p in [SIMD3<Float>(0, y, 0), n0 + SIMD3(0, y, 0), n1 + SIMD3(0, y, 0)] { cylinder.append(GPUVertex(position: p, normal: normal, uv: SIMD2(p.x * 0.5 + 0.5, p.z * 0.5 + 0.5))) } }
        }
        let plane = corners.map { GPUVertex(position: SIMD3($0.x - 0.5, $0.y - 0.5, 0), normal: SIMD3(0, 0, 1), uv: SIMD2($0.x, 1 - $0.y)) }
        var grass: [GPUVertex] = []
        for blade in 0..<6 {
            let angle = Float(blade) * 2.3999632
            let side = SIMD3<Float>(cos(angle), 0, sin(angle))
            let lean = SIMD3<Float>(-sin(angle), 0, cos(angle))
            let height: Float = 0.58 + Float((blade * 7) % 5) * 0.105
            func grassVertex(_ across: Float, _ t: Float) -> GPUVertex {
                let width: Float = 0.010 * pow(1-t,0.72)
                let p = side * ((Float(blade%3)-1)*0.035 + (across-0.5)*width*2) + lean * (t*t*0.16) + SIMD3<Float>(0,t*height,0)
                return GPUVertex(position:p,normal:simd_normalize(lean+SIMD3<Float>(0,0.3+t*0.4,0)),uv:SIMD2(across,t))
            }
            for segment in 0..<3 { for uv in corners { grass.append(grassVertex(uv.x,(Float(segment)+uv.y)/3)) } }
        }
                var trunk: [GPUVertex] = []
        func trunkVertex(_ u: Float, _ t: Float) -> GPUVertex {
            let a = u * .pi * 2, radius = (1 - t * 0.86) * (1 + sin(a * 5 + t * 13) * 0.06)
            let p = SIMD3<Float>(cos(a) * radius + sin(t * 4) * 0.11, t, sin(a) * radius + sin(t * 6) * 0.08)
            return GPUVertex(position: p, normal: simd_normalize(SIMD3(cos(a), 0.11, sin(a))), uv: SIMD2(u, t))
        }
        for y in 0..<8 { for x in 0..<12 { for uv in corners { trunk.append(trunkVertex((Float(x) + uv.x) / 12, (Float(y) + uv.y) / 8)) } } }
        // Atlas UV polygon lies entirely inside the black alpha island around
        // the photographed twig. A full rectangle would expose opaque cone UVs.
        let outline: [SIMD2<Float>] = [SIMD2(30,100),SIMD2(850,100),SIMD2(990,500),SIMD2(920,1300),SIMD2(855,1540),SIMD2(650,1810),SIMD2(390,1825),SIMD2(360,1800),SIMD2(250,1740),SIMD2(190,1680),SIMD2(155,1500),SIMD2(119,1310),SIMD2(30,1000)]
        func twigVertex(_ pixel: SIMD2<Float>) -> GPUVertex {
            let t = (1810 - pixel.y) / 1625, x = (pixel.x - 550) / 1625
            let z = sin(t * .pi) * 0.055 + x * x * 0.16
            return GPUVertex(position: SIMD3(x,t,z), normal: simd_normalize(SIMD3(-x*0.25,-cos(t * .pi)*0.1,1)), uv: pixel / SIMD2(1024,2048))
        }
        var twig: [GPUVertex] = []
        for i in outline.indices { twig.append(contentsOf: [twigVertex(SIMD2(540,950)),twigVertex(outline[i]),twigVertex(outline[(i+1)%outline.count])]) }
        // A one-metre grid across the playable area shares the collision
        // heightfield's diagonal. Wider cells outside the arena join the same
        // coordinate rows, so the transition has no cracks or separate skirts.
        let axis = Array(stride(from: Float(-220), to: -48, by: 4))
            + Array(stride(from: Float(-48), through: 48, by: 1))
            + Array(stride(from: Float(52), through: 220, by: 4))
        var terrain: [GPUVertex] = []
        terrain.reserveCapacity((axis.count-1)*(axis.count-1)*6)
        func terrainVertex(_ x: Float, _ z: Float) -> GPUVertex {
            GPUVertex(position: SIMD3(x, terrainHeight(x,z), z),
                      normal: TerrainProfile.battlefield.normal(x: x, z: z),
                      uv: SIMD2(x,z)*0.01)
        }
        for z in 0..<(axis.count-1) { for x in 0..<(axis.count-1) {
            let a=terrainVertex(axis[x],axis[z]), b=terrainVertex(axis[x+1],axis[z])
            let c=terrainVertex(axis[x+1],axis[z+1]), d=terrainVertex(axis[x],axis[z+1])
            terrain.append(contentsOf:[a,d,b,b,d,c])
        } }
        var rock: [GPUVertex] = []
        func rockPoint(_ u: Float, _ v: Float) -> SIMD3<Float> {
            let p = sphereVertex(u,v).position
            let r: Float = 0.84 + sin(p.x*6.1+p.z*3.7)*cos(p.y*5.3)*0.13 + sin(p.z*8.2+p.y*6.4)*0.07
            return p*r
        }
        for y in 0..<12 { for x in 0..<20 {
            for index in stride(from:0,to:6,by:3) {
                let uv0=(SIMD2<Float>(Float(x),Float(y))+corners[index])/SIMD2(20,12)
                let uv1=(SIMD2<Float>(Float(x),Float(y))+corners[index+1])/SIMD2(20,12)
                let uv2=(SIMD2<Float>(Float(x),Float(y))+corners[index+2])/SIMD2(20,12)
                let p0=rockPoint(uv0.x,uv0.y),p1=rockPoint(uv1.x,uv1.y),p2=rockPoint(uv2.x,uv2.y)
                let cross=simd_cross(p1-p0,p2-p0)
                let n=simd_length_squared(cross)>0.000001 ? simd_normalize(cross) : simd_normalize(p0)
                for (p,uv) in [(p0,uv0),(p1,uv1),(p2,uv2)] { let nn=simd_dot(n,p)<0 ? -n : n; rock.append(GPUVertex(position:p,normal:simd_normalize(nn*0.5+simd_normalize(p)*0.5),uv:uv)) }
            }
        } }
        let named: [(String,[GPUVertex])] = Array(zip(["Box", "Sphere", "Cylinder", "Plane", "Grass", "Tapered bark", "Photographic twig", "Shared battlefield heightfield", "Weathered rock"], [cube,sphere,cylinder,plane,grass,trunk,twig,terrain,rock])) + WeaponGeometry.meshes()
        return try named.map { name, vertices in
            guard let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<GPUVertex>.stride, options: .storageModeShared) else { throw RenderError.unavailable("Metal-Geometrie konnte nicht angelegt werden.") }
            var low=SIMD3<Float>(repeating:.infinity),high=SIMD3<Float>(repeating:-.infinity)
            for vertex in vertices { low=simd_min(low,vertex.position); high=simd_max(high,vertex.position) }
            buffer.label = name; return Mesh(vertices: buffer, count: vertices.count, boundsCenter:(low+high)*0.5, halfExtents:(high-low)*0.5)
        }
    }

    private static func loadTextures(device: MTLDevice, assetRoot: URL?) throws -> [MTLTexture] {
        let loader = MTKTextureLoader(device: device)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [assetRoot, Bundle.main.resourceURL?.appendingPathComponent("Assets"), cwd.appendingPathComponent("native/Assets"), cwd.appendingPathComponent("Assets")].compactMap { $0 }
        guard let root = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("textures/pine/alpha.jpg").path) }) else { throw RenderError.unavailable("Fotografische Landschaftstexturen fehlen. Bitte native/scripts/build-app.sh ausführen.") }
        func load(_ path: String, color: Bool) throws -> MTLTexture {
            do {
                let options: [MTKTextureLoader.Option: Any] = [.SRGB: color, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue]
                let texture: MTLTexture
                if path.hasPrefix("textures/pine/"), let source = CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil), let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil), let island = atlas.cropping(to: CGRect(x: 0, y: 0, width: atlas.width / 4, height: atlas.height / 2)) {
                    texture = try loader.newTexture(cgImage: island, options: options)
                } else { texture = try loader.newTexture(URL: root.appendingPathComponent(path), options: options) }
                texture.label = path; return texture
            } catch { throw RenderError.unavailable("Textur \(path) konnte nicht geladen werden: \(error.localizedDescription)") }
        }
        var result: [MTLTexture] = []
        for folder in ["forest-earth", "floor", "forest-rock"] {
            for file in ["color", "normal", "roughness"] { result.append(try load("textures/\(folder)/\(file).jpg", color: file == "color")) }
        }
        result.append(try load("textures/pine/color.jpg", color: true)) // 9
        result.append(result[0]) // 10 is replaced by the native depth shadow map.
        for folder in ["forest-bark", "forest-ground", "asphalt"] {
            for file in ["color", "normal", "roughness"] { result.append(try load("textures/\(folder)/\(file).jpg", color: file == "color")) }
        }
        for file in ["normal", "alpha", "roughness"] { result.append(try load("textures/pine/\(file).jpg", color: false)) }
        // The 8K photographic panorama is retained at source resolution; the
        // unused pine atlas islands above are excluded from GPU memory instead.
        let skyURL = root.appendingPathComponent("environment/sunrise.jpg")
        guard let source = CGImageSourceCreateWithURL(skyURL as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RenderError.unavailable("Fotografischer Himmel fehlt: environment/sunrise.jpg") }
        let sky = try loader.newTexture(cgImage: image, options: [.SRGB: true, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft, .textureStorageMode: MTLStorageMode.private.rawValue]); sky.label = "Kloppenheim 06 photographic pure sky"; result.append(sky)
        result.append(result[0]) // 24 is replaced by the near depth shadow map.
        for folder in ["weapon-metal", "weapon-fabric"] {
            for file in ["color", "normal", "roughness"] { result.append(try load("textures/\(folder)/\(file).jpg",color:file == "color")) }
        }
        return result
    }
}
