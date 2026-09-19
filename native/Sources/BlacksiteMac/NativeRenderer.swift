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
    var levelAddition = false
    var ownerID:Int? = nil
}
private struct CoverVisual {
    let stage: CoverDamageStage
    let isRubble: Bool
    let position: SIMD3<Float>
    let size: SIMD3<Float>
    let items: [RenderItem]
}
private struct CoverFragment {
    let mesh: Int
    let offset: SIMD2<Float>
    let size: SIMD3<Float>
    let yaw: Float
    let color: SIMD3<Float>
    let material: SIMD4<Float>
}
private struct CachedCoverFragments {
    let createdAt: Double
    let fragments: [CoverFragment]
}
private struct MissionVisual {
    let kind: MissionKind
    let phase: MissionPhase
    let position: SIMD3<Float>
    let radius: Float
    let terrain: TerrainProfile
    let props: [RenderItem]
    let ring: [RenderItem]
}
private struct OperationExitVisual {
    let id: String
    let position: SIMD3<Float>
    let radius: Float
    let routeKind: OperationRouteKind
    let terrain: TerrainProfile
    let props: [RenderItem]
    let ring: [RenderItem]
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
    private let glassPipelines:[Int:MTLRenderPipelineState]
    private let glassDepthState:MTLDepthStencilState
    private let shadowPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let skyDepthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let shadowSampler: MTLSamplerState
    private var textures: [MTLTexture]
    private let textureRoot: URL
    private let library: MTLLibrary
    private(set) var map: MapDefinition
    private var appearanceBuffer: MTLBuffer
    private let shadowTexture: MTLTexture
    private var nearShadowTexture: MTLTexture
    private let weaponShadowTexture: MTLTexture
    private var meshes: [Mesh]
    private let baseMeshCount: Int
    private struct VegetationBatch { let id:String;let kind:VegetationKind;let mesh:Int;let plants:Int }
    private struct VegetationResources { let meshes:[Mesh];let batches:[VegetationBatch];let alpha:MTLTexture? }
    private var vegetationBatches:[VegetationBatch]=[]
    private var vegetationAlpha:MTLTexture?
    private struct SpotResources { let textures:[MTLTexture];let terrain:[Mesh] }
    private var spotResources:SpotResources
    private var spotShadowInstanceCounts:[Int]=[]
    private var spotLightPowers:[Float]=[]
    private var skinnedSoldiers: SkinnedSoldierRenderer?
    private let combatEffects: NativeCombatEffects
    private let inflight = DispatchSemaphore(value: 3)
    private var buffers: [MTLBuffer]
    private let uniformBuffers: [MTLBuffer]
    private var frame = 0
    private var highQuality = true
    private var renderTargetBytes = 0
    private let instanceCapacity = 48_000
    private var scenery: [RenderItem] = []
    private var forest: [ForestTree] = []
    private var coverCache: [Int: CoverVisual] = [:]
    private var debrisCache: [Int: CachedCoverFragments] = [:]
    private var reconMarkerCount=0
    private var breachChargeVisualCount=0
    private var operatorVisualParts=0
    private var clearGlassCount=0
    private var activeBreachCount=0
    private var breachFrameCount=0
    private var damagedCoverCount = 0
    private var solidDebrisCount = 0
    private var decorativeDebrisCount = 0
    private var staticLevelDetailCount = 0
    private var activeLevelItemCount = 0
    private var missionVisual: MissionVisual?
    private var operationExitVisuals: [OperationExitVisual] = []
    private var operationMarkerIDs: [String] = []
    private var missionPropCount = 0
    private var missionRingCount = 0
    private var missionPropShadowCount = 0
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
    private var displayedCamouflagePattern: CamouflagePattern = .none
    private var camouflageClothingInstances = 0
    private var decoyPulseTimes:[Int:Double]=[:]
    private var alarmReporterVisualCount=0,alarmPropInstances=0
    private var noiseEmitterVisualCount=0
    private var noiseDecoyVisualCount=0
    private var noisePropInstances=0
    private var smokeVolumeCount=0
    private var smokeGrenadeVisualCount=0
    private var smokeDensities:[Float]=[]
    private var shells = ShellSimulation()
    private var shellImpacts: [ShellImpact] = []
    var characterDiagnostics: [String: Any] {
        var diagnostics:[String:Any] = ["skinnedSoldiers": (skinnedSoldiers?.soldierCount ?? 0),
         "soldierTriangles": (skinnedSoldiers?.triangleCount ?? 0),
         "soldierDrawCallsIncludingShadows": (skinnedSoldiers?.drawCallCount ?? 0),
         "soldierTextureWidth": (skinnedSoldiers?.baseColorSize.x ?? 0),
         "invalidSoldierPoses": (skinnedSoldiers?.invalidPoseCount ?? 0),
         "droppedSoldiers": (skinnedSoldiers?.capacityDropCount ?? 0),
         "footContactPatches": (skinnedSoldiers?.footContactCount ?? 0),
         "farShadowInstances": farShadowInstanceCount, "nearShadowInstances": nearShadowInstanceCount]
        diagnostics.merge(combatEffects.diagnostics) { _,new in new }
        diagnostics["mapID"]=map.id
        diagnostics["mapVersion"]=map.version
        diagnostics["sceneryInstances"]=scenery.count
        diagnostics["forestTrees"]=forest.count
        diagnostics["mapTextureReferences"]=map.resources.texturePaths.count
        diagnostics["mapSupportSurfaces"]=shellGroundColliders.count
        diagnostics["mapTerrainVertices"]=meshes[7].count
        diagnostics["gameplayVegetationZones"]=vegetationBatches.count
        diagnostics["gameplayVegetationPlants"]=vegetationBatches.reduce(0) { $0+$1.plants }
        diagnostics["gameplayVegetationVertices"]=vegetationBatches.reduce(0) { $0+meshes[$1.mesh].count }
        diagnostics["gameplayVegetationInstances"]=vegetationBatches.count
        diagnostics["gameplayVegetationAlphaWidth"]=vegetationAlpha?.width ?? 0
        diagnostics["gameplayVegetationPlantBudget"]=NativeVegetationGeometry.maximumPlants
        diagnostics["playerCamouflagePattern"]=displayedCamouflagePattern.rawValue
        diagnostics["camouflageClothingInstances"]=camouflageClothingInstances
        diagnostics["noiseEmitterVisuals"]=noiseEmitterVisualCount
        diagnostics["noiseDecoyVisuals"]=noiseDecoyVisualCount
        diagnostics["noisePropInstances"]=noisePropInstances
        diagnostics["gameplaySmokeVolumes"]=smokeVolumeCount
        diagnostics["smokeGrenadeVisuals"]=smokeGrenadeVisualCount
        diagnostics["smokeDensities"]=smokeDensities
        diagnostics["smokeUniformBytes"]=MemoryLayout<GPUWorldSmoke>.stride
        diagnostics["smokeVolumeDrawCalls"]=0
        diagnostics["visibleReconMarkers"]=reconMarkerCount
        diagnostics["breachChargeVisuals"]=breachChargeVisualCount
        diagnostics["operatorVisualParts"]=operatorVisualParts
        diagnostics["reconMarkerShadowCasters"]=0
        diagnostics["clearGlassSurfaces"]=clearGlassCount
        diagnostics["activeBreachSurfaces"]=activeBreachCount
        diagnostics["breachFrameBodies"]=breachFrameCount
        diagnostics["clearGlassShadowCasters"]=0
        diagnostics["alarmReporterVisuals"]=alarmReporterVisualCount
        diagnostics["alarmPropInstances"]=alarmPropInstances
        diagnostics["spotlightPowers"]=spotLightPowers
        diagnostics["spotShadowInstances"]=spotShadowInstanceCounts
        diagnostics["spotShadowResolution"]=SpotShadowVolume.resolution
        diagnostics["spotShadowTerrainVertices"]=spotResources.terrain.map(\.count)
        diagnostics["textureMemoryMB"]=textureMemoryMB
        diagnostics["textureDimensions"]=textureDimensions
        diagnostics["textureQuality"]=highQuality ? "high":"balanced"
        diagnostics["damagedCoverCount"]=damagedCoverCount
        diagnostics["solidDebrisCount"]=solidDebrisCount
        diagnostics["decorativeDebrisInstances"]=decorativeDebrisCount
        diagnostics["coverCacheEntries"]=coverCache.count
        diagnostics["debrisCacheEntries"]=debrisCache.count
        diagnostics["levelDetailInstances"]=activeLevelItemCount
        diagnostics["levelDetailInstanceBudget"]=96
        diagnostics["missionPropInstances"]=missionPropCount
        diagnostics["missionRingSegments"]=missionRingCount
        diagnostics["operationExitMarkers"]=operationMarkerIDs.count
        diagnostics["operationMarkerIDs"]=operationMarkerIDs
        diagnostics["missionPropShadowCasters"]=missionPropShadowCount
        return diagnostics
    }
    // These shallow surfaces only affect visual shell physics. Append them
    // after gameplay cover so ShellSimulation's support indices remain stable.
    private var shellGroundColliders: [Obstacle] = []
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
    private var sun: SIMD3<Float> { simd_normalize(map.environment.sunDirection) }
    private var fog: SIMD3<Float> { map.environment.fogColor }
    private var lightMatrix = matrix_identity_float4x4

    init(view: MTKView, assetRoot: URL?, highQuality: Bool = true, map: MapDefinition = .blacksite) throws {
        guard map.resources.soldierAsset != nil else {
            throw RenderError.unavailable("Karte \(map.id): Für einen spielbaren Einsatz fehlt die Soldatenmodell-Ressource.")
        }
        try map.validateGameplay()
        self.map=map
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.unavailable("Metal wird auf diesem Mac nicht unterstützt.") }
        self.device = device; self.queue = queue; deviceName = device.name
        self.highQuality=highQuality;currentScale=highQuality ? 1:0.82
        guard MemoryLayout<GPUUniforms>.stride == 336,
              MemoryLayout<GPUUniforms>.offset(of: \.nearLightViewProjection) == 256,
              MemoryLayout<GPUUniforms>.offset(of: \.shadowParameters) == 320 else {
            throw RenderError.unavailable("CPU- und Metal-Schattenlayout stimmen nicht überein.")
        }
        guard MemoryLayout<GPUWorldSmoke>.stride==336,MemoryLayout<GPUWorldSmokeVolume>.stride==80,
              MemoryLayout<GPUWorldSmoke>.offset(of:\.first)==16,MemoryLayout<GPUWorldSmoke>.offset(of:\.fourth)==256 else {
            throw RenderError.unavailable("CPU- und Metal-Rauchlayout stimmen nicht überein.")
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
        self.library=library
        appearanceBuffer=try Self.makeAppearanceBuffer(device:device,map:map)
        var main: [Int: MTLRenderPipelineState] = [:], skies: [Int: MTLRenderPipelineState] = [:],glass:[Int:MTLRenderPipelineState]=[:]
        for samples in [1, 4] where device.supportsTextureSampleCount(samples) {
            let p = MTLRenderPipelineDescriptor(); p.label = "Blacksite physically based opaque \(samples)x"
            p.vertexFunction = library.makeFunction(name: "worldVertex"); p.fragmentFunction = library.makeFunction(name: "worldFragment")
            p.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb; p.depthAttachmentPixelFormat = .depth32Float; p.rasterSampleCount = samples; p.isAlphaToCoverageEnabled = samples > 1
            main[samples] = try device.makeRenderPipelineState(descriptor: p)
            let s = MTLRenderPipelineDescriptor(); s.label = "Atmospheric sky \(samples)x"
            s.vertexFunction = library.makeFunction(name: "skyVertex"); s.fragmentFunction = library.makeFunction(name: "skyFragment")
            s.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb; s.depthAttachmentPixelFormat = .depth32Float; s.rasterSampleCount = samples
            skies[samples] = try device.makeRenderPipelineState(descriptor: s)
            let g=MTLRenderPipelineDescriptor();g.label="Physical clear breach glass \(samples)x"
            g.vertexFunction=library.makeFunction(name:"worldVertex");g.fragmentFunction=library.makeFunction(name:"breachGlassFragment")
            g.depthAttachmentPixelFormat = .depth32Float;g.rasterSampleCount=samples
            let color=g.colorAttachments[0]!;color.pixelFormat = .bgra8Unorm_srgb;color.isBlendingEnabled=true
            color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .zero;color.destinationAlphaBlendFactor = .one
            glass[samples]=try device.makeRenderPipelineState(descriptor:g)
        }
        pipelines = main; skyPipelines = skies;glassPipelines=glass
        let sd = MTLRenderPipelineDescriptor(); sd.label = "Directional shadow depth"
        sd.vertexFunction = library.makeFunction(name: "shadowVertex"); sd.fragmentFunction = library.makeFunction(name: "shadowFragment"); sd.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: sd)
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .lessEqual; dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { throw RenderError.unavailable("Tiefenpuffer konnte nicht angelegt werden.") }; depthState = ds
        dd.isDepthWriteEnabled=false;glassDepthState=device.makeDepthStencilState(descriptor:dd)!
        dd.depthCompareFunction = .always; skyDepthState = device.makeDepthStencilState(descriptor: dd)!
        let sm = MTLSamplerDescriptor(); sm.minFilter = .linear; sm.magFilter = .linear; sm.mipFilter = .linear; sm.maxAnisotropy = 8; sm.sAddressMode = .repeat; sm.tAddressMode = .repeat
        sampler = device.makeSamplerState(descriptor: sm)!
        let ss = MTLSamplerDescriptor(); ss.minFilter = .nearest; ss.magFilter = .nearest; ss.compareFunction = .lessEqual; ss.sAddressMode = .clampToEdge; ss.tAddressMode = .clampToEdge
        shadowSampler = device.makeSamplerState(descriptor: ss)!
        let shadowDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false); shadowDesc.storageMode = .private; shadowDesc.usage = [.renderTarget, .shaderRead]
        guard let shadow = device.makeTexture(descriptor: shadowDesc) else { throw RenderError.unavailable("Schattenpuffer konnte nicht angelegt werden.") }; shadowTexture = shadow; shadow.label = "2048 directional shadow atlas"
        nearShadowTexture=try Self.makeNearShadow(device:device,highQuality:highQuality)
        let weaponShadowDesc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:512,height:512,mipmapped:false)
        weaponShadowDesc.usage=[.renderTarget,.shaderRead];weaponShadowDesc.storageMode = .private
        guard let weaponShadow=device.makeTexture(descriptor:weaponShadowDesc) else { throw RenderError.unavailable("Waffen-Schattenpuffer konnte nicht angelegt werden.") }
        weaponShadow.label="512 viewmodel-only self shadows";weaponShadowTexture=weaponShadow
        let root=try Self.resolveTextureRoot(assetRoot:assetRoot);textureRoot=root
        let baseMeshes=try Self.makeMeshes(device:device,map:map)
        baseMeshCount=baseMeshes.count
        let vegetation=try Self.makeVegetation(device:device,root:root,map:map,firstMesh:baseMeshes.count)
        meshes=baseMeshes+vegetation.meshes;vegetationBatches=vegetation.batches;vegetationAlpha=vegetation.alpha
        spotResources=try Self.makeSpotResources(device:device,map:map)
        textures = try autoreleasepool { try Self.loadTextures(device:device,root:root,highQuality:highQuality,resources:map.resources) }
        if let soldier=map.resources.soldierAsset {
            skinnedSoldiers = try SkinnedSoldierRenderer(device:device,library:library,
                assetURL:root.appendingPathComponent(map.resources.assetDirectory).appendingPathComponent(soldier),highQuality:highQuality)
        }
        combatEffects = try NativeCombatEffects(device:device,library:library)
        buffers = try (0..<3).map { index in guard let b = device.makeBuffer(length: 48_000 * MemoryLayout<GPUInstance>.stride, options: .storageModeShared) else { throw RenderError.unavailable("Instanzpuffer konnte nicht angelegt werden.") }; b.label = "Instances frame \(index)"; return b }
        uniformBuffers = (0..<3).map { _ in device.makeBuffer(length: MemoryLayout<GPUUniforms>.stride, options: .storageModeShared)! }
        metalView = view; view.device = device; view.colorPixelFormat = .bgra8Unorm_srgb; view.depthStencilPixelFormat = .depth32Float; view.sampleCount = highQuality && main[4] != nil ? 4:1; view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.25, green: 0.35, blue: 0.42, alpha: 1)
        lightMatrix = Self.makeLightMatrix(map:map)
        shellGroundColliders=map.groundedSupportSurfaces
        buildScenery()
    }

    /// Prepare fallible GPU resources first. The synchronous MainActor commit
    /// leaves no mixed old/new world if an asset fails to decode or upload.
    func setMap(_ next: MapDefinition) throws {
        guard next.resources.soldierAsset != nil else {
            throw RenderError.unavailable("Karte \(next.id): Für einen spielbaren Einsatz fehlt die Soldatenmodell-Ressource.")
        }
        try next.validateGameplay()
        let replacement = try autoreleasepool { () -> ([MTLTexture], SkinnedSoldierRenderer?, Mesh, MTLBuffer,VegetationResources,SpotResources) in
            let resourcesChanged = next.resources != map.resources
            let materials = resourcesChanged
                ? try Self.loadTextures(device: device, root: textureRoot, highQuality: highQuality, resources: next.resources)
                : textures
            let character: SkinnedSoldierRenderer?
            if next.resources.soldierAsset == map.resources.soldierAsset,
               next.resources.assetDirectory == map.resources.assetDirectory { character = skinnedSoldiers }
            else if let file = next.resources.soldierAsset {
                character = try SkinnedSoldierRenderer(device: device, library: library,
                    assetURL: textureRoot.appendingPathComponent(next.resources.assetDirectory).appendingPathComponent(file),
                    highQuality: highQuality)
            } else { character = nil }
            let terrain = try Self.makeMesh(device: device, name: "Active map \(next.id) heightfield",
                                           vertices: NativeMapGeometry.vertices(map: next))
            let appearance = try Self.makeAppearanceBuffer(device: device, map: next)
            let vegetation=try Self.makeVegetation(device:device,root:textureRoot,map:next,firstMesh:baseMeshCount)
            let spots=try Self.makeSpotResources(device:device,map:next)
            return (materials, character, terrain, appearance, vegetation,spots)
        }
        map = next; textures = replacement.0; skinnedSoldiers = replacement.1
        meshes=Array(meshes.prefix(baseMeshCount))+replacement.4.meshes
        meshes[7] = replacement.2; appearanceBuffer = replacement.3
        vegetationBatches=replacement.4.batches;vegetationAlpha=replacement.4.alpha
        spotResources=replacement.5
        shellGroundColliders = next.groundedSupportSurfaces
        lightMatrix = Self.makeLightMatrix(map: next)
        // Submitted command buffers retain only the resources they still use.
        // No registry, hidden second map, or previous scenery cache is retained.
        scenery.removeAll(keepingCapacity: false); forest.removeAll(keepingCapacity: false)
        reset(); visualTime = 0
        buildScenery()
    }

    private static func makeLightMatrix(map: MapDefinition) -> simd_float4x4 {
        let e = map.environment, extent = e.shadowExtent
        let light = simd_normalize(e.sunDirection)
        return orthographic(left: -extent, right: extent, bottom: -extent, top: extent, near: 1, far: e.shadowDepth)
            * lookAt(eye: e.shadowTarget + light * e.shadowDistance, target: e.shadowTarget)
    }

    private static func makeAppearanceBuffer(device: MTLDevice, map: MapDefinition) throws -> MTLBuffer {
        let appearance = map.scenery.terrainAppearance
        guard appearance.regions.count <= 8 else { throw RenderError.unavailable("Karte \(map.id): Höchstens acht Gelände-Materialmasken sind erlaubt.") }
        // Metal: two float4 header fields, then eight records of four float4.
        var fields = [SIMD4<Float>](repeating: .zero, count: 34)
        fields[0] = appearance.leafGradient
        fields[1] = SIMD4(Float(appearance.regions.count), 0, 0, 0)
        for (index, region) in appearance.regions.enumerated() {
            let offset = 2 + index * 4
            fields[offset] = SIMD4(region.center.x, region.center.y, region.radii.x, region.radii.y)
            fields[offset + 1] = SIMD4(region.inner.x, region.inner.y, region.outer.x, region.outer.y)
            fields[offset + 2] = SIMD4(region.shape == .ellipse ? 0 : 1, region.leafReduction, region.minimumLeaf, region.roughnessReduction)
            fields[offset + 3] = SIMD4(region.tint, region.tintStrength)
        }
        guard let buffer = device.makeBuffer(bytes: fields, length: fields.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else {
            throw RenderError.unavailable("Geländematerialien der Karte \(map.id) konnten nicht angelegt werden.")
        }
        buffer.label = "Active map terrain appearance (544 bytes)"
        return buffer
    }

    func setQuality(_ high: Bool) throws {
        guard high != highQuality else { return }
        // Prepare all profile resources before changing any live binding. A
        // failed file/decode/upload leaves the old profile fully operational.
        let replacement=try autoreleasepool { () -> ([MTLTexture],SkinnedSoldierRenderer.MaterialSet?,MTLTexture) in
            let world=try Self.loadTextures(device:device,root:textureRoot,highQuality:high,resources:map.resources)
            let soldiers=try skinnedSoldiers?.prepareMaterials(highQuality:high)
            let near=try Self.makeNearShadow(device:device,highQuality:high)
            return (world,soldiers,near)
        }
        // This synchronous MainActor transaction cannot interleave with draw.
        // Submitted command buffers retain old resources until their GPU work
        // completes; there is no permanent second profile or shadow-map cache.
        textures=replacement.0
        if let materials=replacement.1 { skinnedSoldiers?.installMaterials(materials) }
        nearShadowTexture=replacement.2
        highQuality = high; currentScale = high ? 1 : 0.82
        metalView?.sampleCount = high && pipelines[4] != nil ? 4 : 1
        lastSize = .zero;renderTargetBytes=0
    }
    func reset() { reconMarkerCount=0;breachChargeVisualCount=0;operatorVisualParts=0;clearGlassCount=0;activeBreachCount=0;breachFrameCount=0;smokeVolumeCount=0;smokeGrenadeVisualCount=0;smokeDensities.removeAll(keepingCapacity:true);alarmReporterVisualCount=0;alarmPropInstances=0;spotShadowInstanceCounts=[];spotLightPowers=[];decoyPulseTimes.removeAll(keepingCapacity:true); noiseEmitterVisualCount=0; noiseDecoyVisualCount=0; noisePropInstances=0; displayedCamouflagePattern = .none; camouflageClothingInstances = 0; combatEffects.reset(); tracers.removeAll(keepingCapacity: true); recoil = 0; shake = 0; flash = 0; smoothFOV = 76; weaponAimBlend = 0; weaponWallBlend = 0; shells.reset(); shellCollisionCache.removeAll(keepingCapacity:false); skinnedSoldiers?.reset(); shellImpacts.removeAll(keepingCapacity: true); shotAge = 10; coverCache.removeAll(keepingCapacity:true);debrisCache.removeAll(keepingCapacity:true);damagedCoverCount=0;solidDebrisCount=0;decorativeDebrisCount=0;missionVisual=nil;operationExitVisuals.removeAll(keepingCapacity:false);operationMarkerIDs.removeAll(keepingCapacity:false);missionPropCount=0;missionRingCount=0;missionPropShadowCount=0 }

    func handle(events: [GameEvent], simulation: CombatSimulation) {
        for event in events where event.kind == .decoyPulse && simulation.decoys.contains(where:{ $0.id==event.id }) {
            decoyPulseTimes[event.id]=event.hearing?.time ?? simulation.elapsed
        }
        // Only hit owners need surface extraction. These are the exact cached
        // mesh0 parts used to draw ribs, warning paint, slats and window trims.
        let hitOwners=Set(events.compactMap { $0.surfaceImpact?.obstacleID })
        let destroyed=Set(events.filter { $0.kind == .coverDestroyed }.map(\.id))
        let solidIDs=Set(simulation.coverDebris.compactMap(\.solidObstacleID))
        var surfaceBoxes:[Int:[CombatSurfaceBox]] = [:]
        for obstacle in simulation.obstacles where hitOwners.contains(obstacle.id) && !obstacle.destroyed && !destroyed.contains(obstacle.id) {
            surfaceBoxes[obstacle.id]=coverItems(obstacle,isRubble:solidIDs.contains(obstacle.id)).compactMap { item in
                guard item.mesh==0 else { return nil }
                let m=item.instance.model
                let a=SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z),b=SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z),c=SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z)
                let center=SIMD3(m.columns.3.x,m.columns.3.y,m.columns.3.z),half=(simd_abs(a)+simd_abs(b)+simd_abs(c))*0.5
                return CombatSurfaceBox(minimum:center-half,maximum:center+half)
            }
        }
        combatEffects.handle(events:events,simulation:simulation,highQuality:highQuality,surfaceBoxes:surfaceBoxes)
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
            case .enemyShot:
                tracers.append(Tracer(start: event.position, end: event.endPosition, life: 0.11, hostile: true))
            case .explosion:
                shake = min(0.8, shake + 5 / max(3, simd_distance(cameraEye, event.position)))
            case .damage: shake = min(0.5, shake + 0.13)
            case .land: shake = max(shake, 0.065)
            default: break
            }
        }
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
        statistics = "\(deviceName) · \(view.sampleCount)× MSAA · \(scene.visibleCount + (skinnedSoldiers?.soldierCount ?? 0)) Instanzen · \(scene.main.count + scene.glass.count + scene.weapon.count + scene.weaponShadows.count + scene.shadows.count + scene.nearShadows.count + scene.spotDrawCount + (skinnedSoldiers?.drawCallCount ?? 0) + combatEffects.drawCallCount + 1) Draws · \(Int(1 / max(frameAverage, 0.001))) FPS"
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
        guard (skinnedSoldiers?.invalidPoseCount ?? 0) == 0, (skinnedSoldiers?.capacityDropCount ?? 0) == 0,
              simulation.enemies.isEmpty || skinnedSoldiers != nil else {
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
                visible = scene.visibleCount + (skinnedSoldiers?.soldierCount ?? 0); draws = scene.main.count + scene.glass.count + scene.weapon.count + scene.weaponShadows.count + scene.shadows.count + scene.nearShadows.count + scene.spotDrawCount + (skinnedSoldiers?.drawCallCount ?? 0) + combatEffects.drawCallCount + 1
            }
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0,+)/Double(max(1,values.count)) }
        func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count-1,Int(Double(values.count)*0.95))] }
        return ["device": deviceName, "backend": "Metal", "width": width, "height": height, "frames": count, "warmupFrames": 10,
                "samples": samples, "cpuAverageMs": mean(cpu), "cpuP95Ms": p95(cpu), "gpuAverageMs": mean(gpu), "gpuP95Ms": p95(gpu),
                "serialFrameAverageMs": mean(wall), "gpuAllocatedMB": Double(device.currentAllocatedSize)/1_048_576,
                "visibleInstances": visible, "drawCalls": draws, "forestTrees": forest.count, "skyTextureWidth": textures[23].width, "nearShadowResolution": nearShadowTexture.width,
                "textureQuality":highQuality ? "high":"balanced","textureMemoryMB":textureMemoryMB,"textureDimensions":textureDimensions,
                "renderTargetAccounting":"current render pass attachments"]
    }

    /// Views share allocation with their parent texture (or backing buffer).
    /// Count that allocation once even when the view reports zero allocatedSize.
    private static func allocationResource(_ texture:MTLTexture)->MTLResource {
        var root=texture
        while let parent=root.parent { root=parent }
        if let buffer=root.buffer { return buffer }
        return root
    }

    /// Active application-owned textures, deduplicated by allocation identity.
    /// The driver total also includes buffers and any retained in-flight frames.
    var textureMemoryMB:[String:Double] {
        var seen=Set<ObjectIdentifier>(),result:[String:Double]=[:]
        func account(_ name:String,_ resources:[MTLTexture]) {
            var bytes=0
            for texture in resources {
                let resource=Self.allocationResource(texture)
                if seen.insert(ObjectIdentifier(resource as AnyObject)).inserted { bytes+=resource.allocatedSize }
            }
            result[name]=Double(bytes)/1_048_576
        }
        account("landscape",(Array(0...8)+Array(14...19)).map { textures[$0] })
        account("foliage",([9]+Array(11...13)+Array(20...22)).map { textures[$0] } + (vegetationAlpha.map { [$0] } ?? []))
        account("sky",[textures[23]])
        account("soldiers",(skinnedSoldiers?.materialTextures ?? []))
        account("weapons",Array(25...30).map { textures[$0] })
        account("shadows",[shadowTexture,nearShadowTexture,weaponShadowTexture]+spotResources.textures)
        result["renderTargets"]=Double(renderTargetBytes)/1_048_576
        result["total"]=result.values.reduce(0,+)
        return result
    }
    var textureDimensions:[String:[Int]] {
        var seen=Set<ObjectIdentifier>(),result:[String:[Int]]=[:]
        for resource in textures+(skinnedSoldiers?.materialTextures ?? [])+(vegetationAlpha.map { [$0] } ?? []) where seen.insert(ObjectIdentifier(resource as AnyObject)).inserted {
            result[resource.label ?? "unlabelled"]=[resource.width,resource.height]
        }
        return result
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
        var glass:[RenderBatch]
        var glassDepths:[Float]
        var shadows: [RenderBatch]
        var nearShadows: [RenderBatch]
        var weapon: [RenderBatch]
        var weaponShadows: [RenderBatch]
        var spotShadows:[[RenderBatch]]
        var spotVolumes:[SpotShadowVolume]
        var spotlights:[WorldSpotlightState]
        var smoke:GPUWorldSmoke
        var spotDrawCount:Int { spotlights.indices.reduce(0) { $0 + (spotlights[$1].enabled && spotlights[$1].power>0 ? spotShadows[$1].count+1:0) } }
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
        displayedCamouflagePattern=simulation.loadout.camouflage
        camouflageClothingInstances=0
        var eye = simulation.eyePosition
        var yaw = p.yaw, pitch = p.pitch
        if mode == .menu { eye = map.scenery.menuEye; let dir = simd_normalize(map.scenery.menuTarget - eye); yaw = atan2(-dir.x, -dir.z); pitch = asin(dir.y) }
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
        let projection = Self.perspective(fov: smoothFOV * .pi / 180, aspect: size.x / max(size.y, 1), near: 0.04, far: map.environment.viewDistance)
        let vp = projection * view
        let shadowResolution = highQuality ? 2048 : 1024
        // Use the unshaken camera for a stable grid: recoil must not move shadows.
        let nearVolume = DirectionalShadowVolume.near(eye: mode == .menu ? eye : simulation.eyePosition,
            forward: mode == .menu ? forward : viewDirection(yaw: p.yaw, pitch: p.pitch), sun: sun, resolution: shadowResolution)
        let farVolume = DirectionalShadowVolume(matrix: lightMatrix)
        let spotlights=simulation.spotlights
        let spotVolumes=spotlights.map { SpotShadowVolume(light:$0) }
        var all = scenery
        let solidIDs=Set(simulation.coverDebris.compactMap(\.solidObstacleID))
        let activeIDs=Set(simulation.obstacles.filter { !$0.destroyed }.map(\.id))
        coverCache=coverCache.filter { activeIDs.contains($0.key) }
        let debrisIDs=Set(simulation.coverDebris.map(\.sourceObstacleID))
        debrisCache=debrisCache.filter { debrisIDs.contains($0.key) }
        damagedCoverCount=0;solidDebrisCount=0
        activeBreachCount=simulation.breaches.filter { !$0.isOpen }.count
        let frameIDs=Set(map.breaches.flatMap(\.frameObstacleIDs))
        breachFrameCount=simulation.obstacles.filter { !$0.destroyed && frameIDs.contains($0.id) }.count
        for obstacle in simulation.obstacles where !obstacle.destroyed {
            let rubble=solidIDs.contains(obstacle.id)
            all.append(contentsOf:coverItems(obstacle,isRubble:rubble))
            if rubble { solidDebrisCount+=1 }
            else if obstacle.damageStage == .damaged { damagedCoverCount+=1 }
        }
        activeLevelItemCount=staticLevelDetailCount+coverCache.values.reduce(0) { $0+$1.items.filter(\.levelAddition).count }
        assert(activeLevelItemCount<=96,"Authored level details exceeded the fixed instance budget.")
        appendCoverDebris(to:&all,simulation:simulation)
        appendAcousticProps(to:&all,simulation:simulation)
        appendAlarmProps(to:&all,simulation:simulation)
        appendDeviceProps(to:&all,simulation:simulation)
        let marks=simulation.visibleReconMarks
        reconMarkerCount=marks.count;breachChargeVisualCount=simulation.breachCharges.count;operatorVisualParts=0
        for mark in marks.prefix(ReconMark.maximumCount) {
            for part in NativeOperatorGeometry.marker(mark,eye:eye,time:simulation.elapsed) {
                appendTransformed(to:&all,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
                operatorVisualParts+=1
            }
        }
        for charge in simulation.breachCharges.prefix(BreachChargeState.maximumCount) {
            for part in NativeOperatorGeometry.charge(charge) {
                appendTransformed(to:&all,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
                operatorVisualParts+=1
            }
        }
        assert(operatorVisualParts<=NativeOperatorGeometry.maximumMarkerParts+NativeOperatorGeometry.maximumChargeParts)
        smokeVolumeCount=simulation.smokeVolumes.count
        smokeGrenadeVisualCount=simulation.smokeGrenades.count
        smokeDensities=simulation.smokeVolumes.map(\.density)
        let smokeLighting=simulation.smokeVolumes.map { volume -> SIMD2<Float> in
            let light=simulation.lightSample(at:volume.position)
            return SIMD2(light.directSun,light.artificial)
        }
        let smoke=GPUWorldSmoke(volumes:simulation.smokeVolumes,lighting:smokeLighting)
        for grenade in simulation.smokeGrenades {
            for part in NativeSmokeGeometry.grenade(position:grenade.position) {
                appendTransformed(to:&all,mesh:part.mesh,transform:part.transform,color:part.color,
                    material:part.material,shadow:part.castsShadow)
            }
        }
        if skinnedSoldiers != nil { for enemy in simulation.enemies { all.append(contentsOf: soldierWeapon(enemy, time: simulation.elapsed)) } }
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
        for tracer in tracers { appendBeam(to: &all, from: tracer.start, to: tracer.end, width: tracer.hostile ? 0.013 : 0.008, color: tracer.hostile ? SIMD3(1, 0.23, 0.045) : SIMD3(1, 0.77, 0.3), emissive: 5) }
        appendMissionVisuals(to: &all, status: simulation.missionStatus, operation: simulation.operationStatus, terrain: simulation.terrain)
        var worldByMesh = [[GPUInstance]](repeating: [], count: meshes.count), shadowByMesh = [[GPUInstance]](repeating: [], count: meshes.count)
        var nearByMesh = [[GPUInstance]](repeating: [], count: meshes.count)
        var glassItems:[RenderItem]=[]
        var spotsByMesh=[[[GPUInstance]]](repeating:[[GPUInstance]](repeating:[],count:meshes.count),count:spotlights.count)
        // Conservative sphere frustum checks keep tall trees and nearby cover
        // visible. Scope narrows the horizontal cone without rebuilding scenery.
        let aspect = size.x / max(size.y, 1); let halfAngle = atan(tan(smoothFOV * .pi / 360) * max(aspect, 1)) + 0.2
        let cosCone = cos(halfAngle)
        // Render and shadow detail are independent. Sparse far crowns still
        // cast foliage silhouettes without resubmitting the dense visible LOD.
        for tree in forest {
            let offset = tree.center - eye, distance = simd_length(offset)
            let visibleTree = distance < tree.radius + 7 || (distance < map.environment.viewDistance * 0.8 + tree.radius && simd_dot(offset,forward) + tree.radius > distance*cosCone)
            if visibleTree {
                let lod = distance < (highQuality ? 85 : 60) ? 0 : distance < (highQuality ? 155 : 125) ? 1 : 2
                for item in tree.levels[lod] {
                    let delta = item.center-eye, range = simd_length(delta)
                    if range < item.radius+7 || (range < map.environment.viewDistance * 0.8+item.radius && simd_dot(delta,forward)+item.radius > range*cosCone) {
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
            for index in spotlights.indices where spotlights[index].enabled && spotlights[index].power>0 {
                let volume=spotVolumes[index]
                if volume.intersects(center:tree.center,radius:tree.radius+0.3) {
                    for item in tree.levels[1] where item.shadow && volume.intersects(center:item.center,radius:item.radius+0.25) {
                        spotsByMesh[index][item.mesh].append(item.instance)
                    }
                }
            }
        }
        for item in all {
            if item.shadow {
                // Wind-displaced twig tips need a small conservative margin.
                let shadowRadius = item.radius + 0.25
                if farVolume.intersects(center: item.center, radius: shadowRadius) { shadowByMesh[item.mesh].append(item.instance) }
                if nearVolume.intersects(center: item.center, radius: shadowRadius) { nearByMesh[item.mesh].append(item.instance) }
                // The large terrain uses a cached, exact local patch instead.
                if item.mesh != 7 {
                    for index in spotlights.indices where spotlights[index].enabled && spotlights[index].power>0 {
                        if (spotlights[index].ownerObstacleID == nil || item.ownerID != spotlights[index].ownerObstacleID),
                           spotVolumes[index].intersects(center:item.center,radius:shadowRadius) {
                            spotsByMesh[index][item.mesh].append(item.instance)
                        }
                    }
                }
            }
            let offset = item.center - eye, distance = simd_length(offset)
            if distance < item.radius + 7 || (distance < map.environment.viewDistance * 0.8 + item.radius && simd_dot(offset, forward) + item.radius > distance * cosCone) {
                if item.instance.material.w == NativeBreachGeometry.clearGlassMaterial { glassItems.append(item) }
                else { worldByMesh[item.mesh].append(item.instance) }
            }
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
                if item.instance.material.w == 30 || item.instance.material.w == 31 { camouflageClothingInstances+=1 }
                // Flash, reticle and transmissive scope glass cannot cast an
                // opaque shadow across the hand or receiver.
                if item.instance.material.z<=0 && Int(item.instance.material.w+0.5) != 12 { weaponCastersByMesh[item.mesh].append(item.instance) }
            }
        }
        var instances: [GPUInstance] = []
        instances.reserveCapacity(worldByMesh.reduce(0) { $0+$1.count } + shadowByMesh.reduce(0) { $0+$1.count } + nearByMesh.reduce(0) { $0+$1.count } + weaponByMesh.reduce(0) { $0+$1.count } + weaponCastersByMesh.reduce(0) { $0+$1.count } + spotsByMesh.reduce(0) { $0+$1.reduce(0) { $0+$1.count } })
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
        spotShadowInstanceCounts=spotsByMesh.map { $0.reduce(0) { $0+$1.count } }
        spotLightPowers=spotlights.map { $0.enabled ? $0.power:0 }
        let shadows = batches(shadowByMesh), nearShadows = batches(nearByMesh)
        let spotBatches=spotsByMesh.map { batches($0) }
        let visible = worldByMesh.reduce(0) { $0 + $1.count } + weaponByMesh.reduce(0) { $0+$1.count }, main = batches(worldByMesh), weaponBatches=batches(weaponByMesh), weaponShadowBatches=batches(weaponCastersByMesh)
        glassItems.sort { simd_dot($0.center-eye,forward)>simd_dot($1.center-eye,forward) }
        clearGlassCount=glassItems.count
        let glassBatches=glassItems.map { item -> RenderBatch in
            let batch=RenderBatch(mesh:item.mesh,offset:instances.count,count:1);instances.append(item.instance);return batch
        }
        let glassDepths=glassItems.map { simd_dot($0.center-eye,forward) }
        let uniform = GPUUniforms(viewProjection: vp, inverseViewProjection: vp.inverse, lightViewProjection: lightMatrix, eyeTime: SIMD4(eye, visualTime), sunDirection: SIMD4(sun, 1), fogColor: SIMD4(fog, 1), viewport: SIMD4(size.x, size.y, 0, 0), nearLightViewProjection: nearVolume.matrix,
                                  shadowParameters: SIMD4(1 / Float(shadowResolution), DirectionalShadowVolume.nearWidth, DirectionalShadowVolume.nearDepth, 0.30))
        return PreparedScene(instances: instances, main: main, glass:glassBatches,glassDepths:glassDepths,shadows: shadows, nearShadows: nearShadows, weapon:weaponBatches,weaponShadows:weaponShadowBatches,spotShadows:spotBatches,spotVolumes:spotVolumes,spotlights:spotlights,smoke:smoke,weaponLightMatrix:weaponLightMatrix, nearVolume: nearVolume, uniforms: uniform, visibleCount: visible+glassBatches.count,
                             enemies: simulation.enemies, time: simulation.elapsed, terrain: simulation.terrain, obstacles: simulation.obstacles)
    }
    private func encode(command: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, samples: Int, slot: Int, scene: PreparedScene) {
        var targetIDs=Set<ObjectIdentifier>();renderTargetBytes=0
        for target in [descriptor.colorAttachments[0].texture,descriptor.colorAttachments[0].resolveTexture,descriptor.depthAttachment.texture,descriptor.stencilAttachment.texture].compactMap({ $0 }) {
            let resource=Self.allocationResource(target)
            if targetIDs.insert(ObjectIdentifier(resource as AnyObject)).inserted { renderTargetBytes+=resource.allocatedSize }
        }
        // The frame semaphore has granted ownership of this slot before any
        // joint upload. Main and shadow passes share the exact same pose.
        skinnedSoldiers?.prepare(enemies: scene.enemies, time: scene.time, terrain: scene.terrain, slot: slot, nearShadow: scene.nearVolume, supportObstacles: scene.obstacles + shellGroundColliders,
            spotVolumes:scene.spotlights.indices.map { scene.spotlights[$0].enabled && scene.spotlights[$0].power>0 ? scene.spotVolumes[$0]:nil })
        let effectsEye=SIMD3(scene.uniforms.eyeTime.x,scene.uniforms.eyeTime.y,scene.uniforms.eyeTime.z)
        combatEffects.prepare(slot:slot,eye:effectsEye,forward:cameraForward,terrain:scene.terrain,obstacles:scene.obstacles+shellGroundColliders)
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
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 2); encoder.setFragmentTexture(textures[21], index: 0); encoder.setFragmentTexture(vegetationAlpha ?? textures[21],index:1); encoder.setFragmentSamplerState(sampler, index: 0)
            drawBatches(scene.shadows, encoder: encoder, buffer: instanceBuffer)
            skinnedSoldiers?.encodeShadow(encoder: encoder, slot: slot)
            encoder.endEncoding()
        }
        let nearTexture = nearShadowTexture
        let nearPass = MTLRenderPassDescriptor(); nearPass.depthAttachment.texture = nearTexture
        nearPass.depthAttachment.loadAction = .clear; nearPass.depthAttachment.storeAction = .store; nearPass.depthAttachment.clearDepth = 1
        if let encoder = command.makeRenderCommandEncoder(descriptor: nearPass) {
            encoder.label = "Stabilized near sun shadows"; encoder.setRenderPipelineState(shadowPipeline)
            encoder.setDepthStencilState(depthState); encoder.setCullMode(.none)
            encoder.setDepthBias(0, slopeScale: 0.65, clamp: 0.00015)
            // setVertexBytes owns a copy; never overwrite uniforms used by the far pass.
            var nearUniform = uniform; nearUniform.lightViewProjection = uniform.nearLightViewProjection
            encoder.setVertexBytes(&nearUniform, length: MemoryLayout<GPUUniforms>.stride, index: 2)
            encoder.setFragmentTexture(textures[21], index: 0); encoder.setFragmentTexture(vegetationAlpha ?? textures[21],index:1); encoder.setFragmentSamplerState(sampler, index: 0)
            drawBatches(scene.nearShadows, encoder: encoder, buffer: instanceBuffer)
            skinnedSoldiers?.encodeShadow(encoder: encoder, slot: slot, near: true)
            encoder.endEncoding()
        }
        for index in scene.spotlights.indices where scene.spotlights[index].enabled && scene.spotlights[index].power>0 {
            guard spotResources.textures.indices.contains(index),spotResources.terrain.indices.contains(index) else { continue }
            let pass=MTLRenderPassDescriptor();pass.depthAttachment.texture=spotResources.textures[index]
            pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .store;pass.depthAttachment.clearDepth=1
            if let encoder=command.makeRenderCommandEncoder(descriptor:pass) {
                encoder.label="Shared world lamp \(scene.spotlights[index].id) shadows"
                encoder.setRenderPipelineState(shadowPipeline);encoder.setDepthStencilState(depthState);encoder.setCullMode(.none)
                // Receiver-plane correction supplies the bias at the exact four
                // sampled texel centres; avoid a large perspective raster bias.
                encoder.setDepthBias(0,slopeScale:0,clamp:0)
                var lightUniform=uniform;lightUniform.lightViewProjection=scene.spotVolumes[index].matrix
                encoder.setVertexBytes(&lightUniform,length:MemoryLayout<GPUUniforms>.stride,index:2)
                encoder.setFragmentTexture(textures[21],index:0);encoder.setFragmentTexture(vegetationAlpha ?? textures[21],index:1)
                encoder.setFragmentSamplerState(sampler,index:0)
                var identity=GPUInstance(model:matrix_identity_float4x4,normal0:SIMD4(1,0,0,0),normal1:SIMD4(0,1,0,0),normal2:SIMD4(0,0,1,0),tint:SIMD4(repeating:1),material:SIMD4(1,0,0,1))
                let terrain=spotResources.terrain[index]
                encoder.setVertexBuffer(terrain.vertices,offset:0,index:0)
                encoder.setVertexBytes(&identity,length:MemoryLayout<GPUInstance>.stride,index:1)
                encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:terrain.count)
                drawBatches(scene.spotShadows[index],encoder:encoder,buffer:instanceBuffer)
                skinnedSoldiers?.encodeSpotShadow(encoder:encoder,slot:slot,light:index)
                encoder.endEncoding()
            }
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
                encoder.setFragmentTexture(textures[21],index:0);encoder.setFragmentTexture(vegetationAlpha ?? textures[21],index:1);encoder.setFragmentSamplerState(sampler,index:0)
                drawBatches(scene.weaponShadows,encoder:encoder,buffer:instanceBuffer)
                encoder.endEncoding()
            }
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor), let pipeline = pipelines[samples], let skyPipeline = skyPipelines[samples] else { return }
        encoder.setFragmentBuffer(appearanceBuffer,offset:0,index:4)
        var smoke=scene.smoke
        // The copied fragment block survives all material rebindings, including
        // soldier texture slots, viewmodel uniforms and transparent effects.
        encoder.setFragmentBytes(&smoke,length:MemoryLayout<GPUWorldSmoke>.stride,index:6)
        encoder.label = "Atmosphere and instanced world"; encoder.setCullMode(.none)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 2); encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(textures[23], index: 23); encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setRenderPipelineState(skyPipeline); encoder.setDepthStencilState(skyDepthState); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.setFragmentTexture(shadowTexture, index: 10); encoder.setFragmentTexture(nearTexture, index: 24)
        encoder.setFragmentTexture(scene.weapon.isEmpty ? shadowTexture:weaponShadowTexture,index:31)
        encoder.setFragmentTexture(vegetationAlpha ?? textures[21],index:32)
        encoder.setFragmentTexture(spotResources.textures.first ?? shadowTexture,index:33)
        encoder.setFragmentTexture(spotResources.textures.count>1 ? spotResources.textures[1]:shadowTexture,index:34)
        var worldLighting=GPUWorldLighting(lights:scene.spotlights)
        encoder.setFragmentBytes(&worldLighting,length:MemoryLayout<GPUWorldLighting>.stride,index:5)
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
        skinnedSoldiers?.encodeMain(encoder: encoder, samples: samples, slot: slot)
        skinnedSoldiers?.encodeContacts(encoder: encoder, samples: samples, slot: slot)
        combatEffects.encode(encoder:encoder,samples:samples,slot:slot,farShadow:shadowTexture,nearShadow:nearTexture,shadowSampler:shadowSampler,
            transparentDepths:scene.glassDepths) { index in
                guard let glassPipeline=self.glassPipelines[samples] else { return }
                encoder.setRenderPipelineState(glassPipeline);encoder.setDepthStencilState(self.glassDepthState);encoder.setCullMode(.none)
                // Skinned/decal passes overwrite material samplers. Bind the sky
                // and normal world uniforms explicitly for each interleaved pane.
                encoder.setVertexBuffer(uniformBuffer,offset:0,index:2);encoder.setFragmentBuffer(uniformBuffer,offset:0,index:2)
                encoder.setFragmentTexture(self.textures[23],index:23);encoder.setFragmentSamplerState(self.sampler,index:0)
                self.drawBatches([scene.glass[index]],encoder:encoder,buffer:instanceBuffer)
            }
        encoder.endEncoding()
    }
    private func drawBatches(_ batches: [RenderBatch], encoder: MTLRenderCommandEncoder, buffer: MTLBuffer) {
        for batch in batches { let mesh = meshes[batch.mesh]; encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0); encoder.setVertexBuffer(buffer, offset: batch.offset * MemoryLayout<GPUInstance>.stride, index: 1); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count, instanceCount: batch.count) }
    }

    private func buildScenery() {
        var items: [RenderItem] = []
        let definition=map.scenery
        let metal = SIMD3<Float>(0.17, 0.20, 0.19), concrete = SIMD3<Float>(0.61, 0.63, 0.59)
        for box in definition.boxes where box.ownerID==nil { appendMapBox(box,to:&items) }
        // Mesh fence: fine metal wires cast real shadows and remain legible when
        // the player approaches; all wires share a single instanced draw call.
        func grounded(_ p: SIMD3<Float>) -> SIMD3<Float> { map.grounded(p) }
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
        for segment in definition.fences { fence(segment.start,segment.end) }
        if let gate=definition.extractionGate {
            for x:Float in [-10,10] {
                let p=grounded(gate+SIMD3(x,0,0))
                appendItem(to:&items,position:p+SIMD3(0,3.8,0),scale:SIMD3(0.8,7.6,0.8),color:concrete,material:SIMD4(0.9,0,0,2))
                appendItem(to:&items,position:p+SIMD3(0,0.5,0),scale:SIMD3(1.5,1,1.5),color:concrete,material:SIMD4(0.9,0,0,2))
            }
            let p=grounded(gate)
            appendItem(to:&items,position:p+SIMD3(0,6.9,0),scale:SIMD3(20,1.1,0.7),color:SIMD3(0.24,0.29,0.22),material:SIMD4(0.7,0.5,0,0))
            for x in stride(from:Float(-7.5),through:7.5,by:1.5) where abs(x)>3 {
                appendItem(to:&items,position:p+SIMD3(x,6.9,0.36),scale:SIMD3(0.8,0.08,0.02),color:SIMD3(0.9,0.71,0.33),material:SIMD4(0.4,0,0.3,0),shadow:false)
            }
        }
        for flat in definition.watchtowers {
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
        for flat in definition.lightPoles {
            let p = grounded(flat)
            appendItem(to: &items, mesh: 2, position: p + SIMD3(0, 4.8, 0), scale: SIMD3(0.075, 9.6, 0.075), color: metal)
            appendItem(to: &items, position: p + SIMD3(0.55, 9.2, 0), scale: SIMD3(1.2, 0.1, 0.12), color: metal)
            appendItem(to: &items, position: p + SIMD3(1, 9.1, 0), scale: SIMD3(0.8, 0.09, 0.45), color: SIMD3(0.32, 0.33, 0.28), material: SIMD4(0.65, 0.2, 0, 0))
        }
        appendItem(to: &items, mesh: 7, position: .zero, scale: SIMD3(repeating: 1), color: SIMD3(0.92, 0.94, 0.88), material: SIMD4(1, 0, 0, 1), shadow: true)
        forest=definition.trees.map { buildTree(position:map.grounded($0.position),height:$0.height,seed:$0.seed) }
        for sign in definition.signs where sign.ownerID==nil {
            let start=items.count
            appendLevelSign(to:&items,transform:Self.translation(sign.position)*Self.rotationY(sign.yaw),width:sign.width,materialID:sign.materialID)
            for index in start..<items.count { items[index].levelAddition=true }
        }
        staticLevelDetailCount=items.filter(\.levelAddition).count
        for batch in vegetationBatches {
            let brush=batch.kind == .brush
            appendItem(to:&items,mesh:batch.mesh,position:.zero,scale:SIMD3(repeating:1),
                color:brush ? SIMD3(0.62,0.72,0.46):SIMD3(0.17,0.195,0.105),
                material:SIMD4(0.95,0.82,0,brush ? 28:29),shadow:true)
        }
        scenery=items
    }

    private func appendMapBox(_ box:MapVisualBox,to items:inout [RenderItem],owner:Obstacle?=nil) {
        let mesh:Int
        switch box.mesh { case .box:mesh=0;case .rock:mesh=8;case .grass:mesh=4 }
        let position=owner.map { $0.position+box.position } ?? (box.grounded ? map.grounded(box.position):box.position)
        var material=box.material
        // Store the physical half-width in the asphalt material's unused metal
        // channel. Its edge dirt now follows this road, including rotated roads.
        if Int(material.w+0.5)==6 { material.y=box.size.x*0.5 }
        appendItem(to:&items,mesh:mesh,position:position,scale:box.size,color:box.color,material:material,yaw:box.yaw,shadow:box.castsShadow)
        items[items.count-1].levelAddition=box.levelDetail
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

    /// Signs share the existing box draw batch. Only the shallow metal plate
    /// and its fittings cast shadows; text is a material on that same surface.
    private func appendLevelSign(to items:inout [RenderItem],transform:simd_float4x4,width:Float,materialID:Float) {
        appendTransformed(to:&items,mesh:0,transform:transform*Self.scale(SIMD3(width,0.62,0.016)),color:SIMD3(repeating:1),material:SIMD4(0.89,0.05,0,materialID))
        let frame=SIMD3<Float>(0.12,0.15,0.13)
        for y:Float in [-0.33,0.33] {
            appendTransformed(to:&items,mesh:0,transform:transform*Self.translation(SIMD3(0,y,-0.006))*Self.scale(SIMD3(width+0.05,0.035,0.028)),color:frame,material:SIMD4(0.75,0.30,0,0))
        }
        for x in [-width*0.46,width*0.46] {
            appendTransformed(to:&items,mesh:1,transform:transform*Self.translation(SIMD3(x,0,0.013))*Self.scale(SIMD3(0.018,0.018,0.008)),color:SIMD3(0.41,0.42,0.36),material:SIMD4(0.45,0.75,0,9))
        }
    }

    private func appendOwnerLevelDetails(to items:inout [RenderItem],obstacle:Obstacle) {
        // A fixture may reuse an ID with unrelated geometry. Only the actual
        // authored owner receives its relative signs and attached paint.
        guard let source=map.obstacles.first(where:{ $0.id==obstacle.id }),
              source.kind==obstacle.kind,source.size==obstacle.size,
              source.position.x==obstacle.position.x,source.position.z==obstacle.position.z else { return }
        for box in map.scenery.boxes where box.ownerID==obstacle.id { appendMapBox(box,to:&items,owner:obstacle) }
        for sign in map.scenery.signs where sign.ownerID==obstacle.id {
            let start=items.count
            appendLevelSign(to:&items,transform:Self.translation(obstacle.position+sign.position)*Self.rotationY(sign.yaw),width:sign.width,materialID:sign.materialID)
            for index in start..<items.count { items[index].levelAddition=true }
        }
    }

    private func buildLevelProp(_ obstacle:Obstacle,kind:LevelProp)->[RenderItem] {
        var items:[RenderItem]=[];let p=obstacle.position,s=obstacle.size
        let step=kind == .lowerServiceStep || kind == .upperServiceStep
        // This is exactly the Core AABB, including embedded foundations. No
        // second decorative vent or floating platform sits above the collider.
        appendItem(to:&items,position:p+SIMD3(0,s.y*0.5,0),scale:s,color:step ? SIMD3(0.66,0.67,0.60):SIMD3(0.27,0.32,0.30),material:step ? SIMD4(0.94,0,0,2):SIMD4(0.68,0.25,0,15))
        if step {
            appendItem(to:&items,position:p+SIMD3(-s.x*0.5-0.002,s.y-0.075,0),scale:SIMD3(0.003,0.11,s.z-0.12),color:SIMD3(0.75,0.56,0.19),material:SIMD4(0.95,0,0,0),shadow:false)
            appendItem(to:&items,position:p+SIMD3(0,s.y-0.075,s.z*0.5+0.002),scale:SIMD3(s.x-0.12,0.11,0.003),color:SIMD3(0.75,0.56,0.19),material:SIMD4(0.95,0,0,0),shadow:false)
            appendItem(to:&items,position:p+SIMD3(-s.x*0.5-0.002,s.y-0.60,0),scale:SIMD3(0.003,0.44,min(1.65,s.z-0.2)),color:SIMD3(repeating:1),material:SIMD4(0.97,0,0,24),shadow:false)
        } else {
            for side:Float in [-1,1] {
                appendItem(to:&items,position:p+SIMD3(0,s.y*0.51,side*(s.z*0.5+0.001)),scale:SIMD3(s.x-0.28,s.y*0.63,0.002),color:SIMD3(0.20,0.24,0.22),material:SIMD4(0.85,0.2,0,27),shadow:false)
            }
            appendItem(to:&items,position:p+SIMD3(s.x*0.5+0.001,s.y*0.54,0),scale:SIMD3(0.002,0.29,s.z*0.64),color:SIMD3(repeating:1),material:SIMD4(0.97,0,0,22),shadow:false)
        }
        for index in items.indices { items[index].levelAddition=true }
        return items
    }

    private func coverItems(_ obstacle:Obstacle,isRubble:Bool)->[RenderItem] {
        if let cached=coverCache[obstacle.id],cached.stage == obstacle.damageStage,
           cached.isRubble == isRubble,cached.size == obstacle.size {
            if cached.position == obstacle.position { return cached.items }
            // Axis-aligned gates translate their cached geometry and attached
            // decals with the current collider; a moving door is not a new mesh.
            let delta=obstacle.position-cached.position
            let moved=cached.items.map { original -> RenderItem in
                var item=original;item.center+=delta;item.instance.model.columns.3+=SIMD4(delta,0);return item
            }
            coverCache[obstacle.id]=CoverVisual(stage:cached.stage,isRubble:isRubble,position:obstacle.position,size:obstacle.size,items:moved)
            return moved
        }
        if coverCache[obstacle.id] != nil { combatEffects.removeDecals(obstacleID:obstacle.id) }
        var items:[RenderItem]
        if isRubble {
            // The low concrete remnant is a real collider. Its visible top and
            // sides must stay exactly on that AABB until the simulation removes
            // both; shrinking the solid would leave invisible cover behind.
            items=[]
            appendItem(to:&items,position:obstacle.position+SIMD3(0,obstacle.size.y*0.5,0),scale:obstacle.size,
                color:SIMD3(0.61,0.61,0.55),material:SIMD4(0.98,0,0,19))
        } else if let breach=map.breaches.first(where:{ $0.ownerObstacleID==obstacle.id }) {
            items=[]
            for part in NativeBreachGeometry.parts(obstacle:obstacle,definition:breach) {
                appendTransformed(to:&items,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
            }
        } else if map.breaches.contains(where:{ $0.frameObstacleIDs.contains(obstacle.id) }) {
            items=[]
            for part in NativeBreachGeometry.frame(obstacle:obstacle) {
                appendTransformed(to:&items,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
            }
        } else if let device=map.environment.devices.first(where:{ $0.ownerObstacleID==obstacle.id }) { items=buildDeviceCover(obstacle,kind:device.kind) }
        else if let prop=map.levelProp(for:obstacle) { items=buildLevelProp(obstacle,kind:prop) }
        else { items=buildCover(obstacle) }
        for index in items.indices { items[index].ownerID=obstacle.id }
        coverCache[obstacle.id]=CoverVisual(stage:obstacle.damageStage,isRubble:isRubble,position:obstacle.position,size:obstacle.size,items:items)
        return items
    }

    private func buildDeviceCover(_ obstacle:Obstacle,kind:WorldDeviceKind)->[RenderItem] {
        var items:[RenderItem]=[];let p=obstacle.position,s=obstacle.size
        let metal=SIMD3<Float>(0.22,0.27,0.235)
        let material:SIMD4<Float>=SIMD4(0.70,0.20,0,obstacle.damageStage == .damaged ? 17:15)
        appendItem(to:&items,position:p+SIMD3(0,s.y*0.5,0),scale:s,color:metal,material:material)
        if kind == .generator {
            for side:Float in [-1,1] {
                appendItem(to:&items,position:p+SIMD3(0,s.y*0.51,side*(s.z*0.5+0.002)),scale:SIMD3(s.x*0.75,s.y*0.42,0.004),color:SIMD3(0.09,0.12,0.105),material:SIMD4(0.9,0.1,0,27),shadow:false)
            }
            appendItem(to:&items,position:p+SIMD3(0,s.y-0.12,s.z*0.5+0.003),scale:SIMD3(s.x*0.85,0.07,0.004),color:SIMD3(0.63,0.44,0.12),material:SIMD4(0.9,0,0,0),shadow:false)
        } else {
            for x in stride(from:-s.x*0.5+0.6,through:s.x*0.5-0.3,by:1.2) {
                for side:Float in [-1,1] {
                    appendItem(to:&items,position:p+SIMD3(x,s.y*0.5,side*(s.z*0.5+0.013)),scale:SIMD3(0.055,s.y-0.08,0.026),color:metal*0.7,material:material)
                }
            }
            for side:Float in [-1,1] {
                appendItem(to:&items,position:p+SIMD3(0,0.18,side*(s.z*0.5+0.002)),scale:SIMD3(s.x-0.12,0.12,0.004),color:SIMD3(0.69,0.47,0.13),material:SIMD4(0.95,0,0,0),shadow:false)
            }
        }
        if let alarm=map.environment.alarm,
           map.environment.devices.first(where:{ $0.id==alarm.radioDeviceID })?.ownerObstacleID==obstacle.id {
            for part in NativeAlarmGeometry.module(position:map.grounded(alarm.radioPosition)) {
                appendTransformed(to:&items,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
            }
        }
        // Derive a short physical exhaust connection from the same authored
        // source used by Core. It stays in the owning cover cache on damage,
        // translation or destruction; it is never a separate floating prop.
        for source in map.environment.smokeEmitters {
            guard let deviceID=source.powerDeviceID,
                  map.environment.devices.first(where:{ $0.id==deviceID })?.ownerObstacleID==obstacle.id else { continue }
            let aperture=map.grounded(source.position)
            var attachment=aperture
            attachment.y=min(p.y+s.y-0.06,max(p.y+0.06,aperture.y))
            if abs((aperture.x-p.x)/s.x)>abs((aperture.z-p.z)/s.z) {
                attachment.x=p.x+(aperture.x<p.x ? -1:1)*s.x*0.5
            } else { attachment.z=p.z+(aperture.z<p.z ? -1:1)*s.z*0.5 }
            let delta=aperture-attachment,length=simd_length(delta)
            guard length>0.02,length<0.6 else { continue }
            let orientation=simd_float4x4(simd_quatf(from:SIMD3<Float>(0,1,0),to:delta/length))
            appendTransformed(to:&items,mesh:10,transform:Self.translation((aperture+attachment)*0.5)*orientation*Self.scale(SIMD3(0.039,length,0.039)),
                color:SIMD3(0.19,0.22,0.20),material:SIMD4(0.65,0.45,0,15))
            appendTransformed(to:&items,mesh:10,transform:Self.translation(attachment+delta/length*0.011)*orientation*Self.scale(SIMD3(0.063,0.02,0.063)),
                color:SIMD3(0.25,0.28,0.25),material:SIMD4(0.7,0.35,0,15))
        }
        return items
    }

    private func appendCoverDebris(to items:inout [RenderItem],simulation:CombatSimulation) {
        decorativeDebrisCount=0
        let supportBoxes=simulation.obstacles+shellGroundColliders
        for debris in simulation.coverDebris.prefix(24) {
            let age=max(0,simulation.elapsed-debris.createdAt),remaining=debris.lifetime-age
            guard remaining>0 else { continue }
            if debrisCache[debris.sourceObstacleID]?.createdAt != debris.createdAt {
                var rng=SeededRandom(seed:UInt64(bitPattern:Int64(debris.sourceObstacleID)) &+ 9307)
                var fragments:[CoverFragment]=[]
                for index in 0..<4 {
                    var offset=SIMD2<Float>((rng.next()-0.5)*min(3,debris.size.x+0.7),(rng.next()-0.5)*min(2.2,debris.size.z+0.6))
                    let mesh:Int,size:SIMD3<Float>,color:SIMD3<Float>,material:SIMD4<Float>
                    switch debris.kind {
                    case .crate:
                        mesh=9;size=SIMD3(0.46+rng.next()*0.29,0.035,0.10+rng.next()*0.08)
                        color=SIMD3(0.43,0.30,0.14);material=SIMD4(0.98,0,0,18)
                    case .barrel:
                        mesh=index==0 ? 8:9;size=SIMD3(0.28+rng.next()*0.18,0.035,0.19+rng.next()*0.13)
                        color=SIMD3(0.31,0.16,0.09);material=SIMD4(0.89,0.3,0,20)
                    case .container,.accessPanel:
                        mesh=9;size=SIMD3(0.64+rng.next()*0.31,0.032,0.26+rng.next()*0.16)
                        color=debris.sourceObstacleID%2==0 ? SIMD3(0.34,0.22,0.14):SIMD3(0.18,0.29,0.27)
                        material=SIMD4(0.85,0.35,0,17)
                    case .glass:
                        mesh=3;size=SIMD3(0.12+rng.next()*0.18,0.14+rng.next()*0.16,1)
                        color=SIMD3(0.38,0.55,0.51);material=SIMD4(0.22,0.25,0,35)
                    case .barrier,.bunker:
                        mesh=8;size=SIMD3(0.22+rng.next()*0.15,0.065,0.17+rng.next()*0.12)
                        color=SIMD3(0.56,0.56,0.49);material=SIMD4(1,0,0,19)
                        // Keep cosmetic chips beside the surviving slab rather
                        // than hidden inside its collision volume.
                        offset.y=(index.isMultiple(of:2) ? -1:1)*(debris.size.z*0.5+0.24+rng.next()*0.18)
                    }
                    fragments.append(CoverFragment(mesh:mesh,offset:offset,size:size,yaw:rng.next()*2*Float.pi,color:color,material:material))
                }
                debrisCache[debris.sourceObstacleID]=CachedCoverFragments(createdAt:debris.createdAt,fragments:fragments)
            }
            // Scaling the actual geometry also scales both directional-shadow
            // submissions. No alpha-only disappearance or ghost caster remains.
            let t=min(1,Float(remaining/2)),fade=t*t*(3-2*t)
            guard fade>0.015 else { continue }
            for fragment in debrisCache[debris.sourceObstacleID]?.fragments ?? [] {
                guard decorativeDebrisCount<96 else { break }
                let x=debris.position.x+fragment.offset.x,z=debris.position.z+fragment.offset.y
                var support=SIMD3<Float>(x,simulation.terrain.height(x:x,z:z),z)
                var normal=simulation.terrain.normal(x:x,z:z)
                let glassFragment=debris.kind == .glass
                let extent=(glassFragment ? max(fragment.size.x,fragment.size.y):max(fragment.size.x,fragment.size.z))*fade*0.75
                for box in supportBoxes where !box.destroyed {
                    let top=box.position.y+box.size.y
                    if top>support.y,top<=debris.position.y+0.1,
                       abs(x-box.position.x)+extent<=box.size.x*0.5,
                       abs(z-box.position.z)+extent<=box.size.z*0.5 {
                        support.y=top;normal=SIMD3(0,1,0)
                    }
                }
                let bounds=meshes[fragment.mesh],size=fragment.size*fade
                let bottom=(bounds.boundsCenter.y-bounds.halfExtents.y)*size.y
                let orientation=simd_float4x4(simd_quatf(from:SIMD3<Float>(0,1,0),to:normal))*Self.rotationY(fragment.yaw)
                let surfaceRotation=glassFragment ? Self.rotationX(-.pi/2):matrix_identity_float4x4
                let transform=Self.translation(support+normal*(glassFragment ? 0.003:0.001-bottom))*orientation*surfaceRotation*Self.scale(size)
                appendTransformed(to:&items,mesh:fragment.mesh,transform:transform,color:fragment.color,material:fragment.material,shadow:!glassFragment)
                decorativeDebrisCount+=1
            }
        }
    }

    private func buildCover(_ obstacle: Obstacle) -> [RenderItem] {
        var out: [RenderItem] = []; let p = obstacle.position, s = obstacle.size
        let damaged=obstacle.damageStage == .damaged
        let metal = SIMD3<Float>(0.18, 0.23, 0.22), concrete = SIMD3<Float>(0.66, 0.67, 0.62)
        func box(_ position: SIMD3<Float>, _ scale: SIMD3<Float>, _ color: SIMD3<Float>, material: SIMD4<Float> = SIMD4(0.65, 0.3, 0, 0)) { appendItem(to: &out, position: p + position, scale: scale, color: color, material: material) }
        switch obstacle.kind {
        case .accessPanel,.glass:
            for part in NativeBreachGeometry.fallbackParts(obstacle:obstacle) {
                appendTransformed(to:&out,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
            }
            return out
        case .container:
            let color: SIMD3<Float> = obstacle.id % 2 == 0 ? SIMD3(0.46, 0.24, 0.13) : SIMD3(0.19, 0.35, 0.34)
            box(SIMD3(0, s.y * 0.5, 0), s, color, material: SIMD4(0.65, 0.62, 0, 0))
            let longX = s.x > s.z, length = longX ? s.x : s.z
            for t in stride(from: -length * 0.5 + 0.18, to: length * 0.5, by: 0.32) {
                for side: Float in [-1, 1] {
                    let position = longX ? SIMD3(t, s.y * 0.5, side * (s.z * 0.5 + 0.027)) : SIMD3(side * (s.x * 0.5 + 0.027), s.y * 0.5, t)
                    let dent:Float=damaged && abs(t)<length*0.32 ? 0.045:0
                    let shifted=position-(longX ? SIMD3(0,0,side*dent):SIMD3(side*dent,0,0))
                    box(shifted, longX ? SIMD3(0.095, s.y - 0.2, 0.07) : SIMD3(0.07, s.y - 0.2, 0.095), color * 0.92)
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
            // Authored roof equipment is now a separate Core obstacle. Its
            // compact renderer supplies the exact collision-aligned shell.
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
            // Keep the cylindrical impact surface continuous; the damaged
            // material supplies scraped paint and scorched, dented shading.
            appendItem(to: &out, mesh: 2, position: p + SIMD3(0, s.y * 0.5, 0), scale: SIMD3(s.x * 0.5, s.y, s.z * 0.5), color: SIMD3(0.47, 0.18, 0.095), material: SIMD4(0.54, 0.65, 0, 0))
            for y in [s.y * 0.1, s.y * 0.3, s.y * 0.72, s.y * 0.96] { appendItem(to: &out, mesh: 2, position: p + SIMD3(0, y, 0), scale: SIMD3(s.x * 0.515, 0.045, s.z * 0.515), color: metal) }
            box(SIMD3(0, 0.65, s.z * 0.5 + 0.01), SIMD3(0.23, 0.25, 0.017), SIMD3(0.9, 0.63, 0.1))
        }
        if damaged {
            let materialID:Float
            switch obstacle.kind { case .crate:materialID=18;case .barrier,.bunker:materialID=19;case .barrel:materialID=20;case .container,.accessPanel:materialID=17;case .glass:materialID=NativeBreachGeometry.opaqueGlassMaterial }
            for index in out.indices { out[index].instance.material.w=materialID }
        }
        appendOwnerLevelDetails(to:&out,obstacle:obstacle)
        return out
    }

    private func appendAcousticProps(to items:inout[RenderItem],simulation:CombatSimulation) {
        let start=items.count
        noiseEmitterVisualCount=0;noiseDecoyVisualCount=0
        let activeIDs=Set(simulation.decoys.map(\.id))
        decoyPulseTimes=decoyPulseTimes.filter { activeIDs.contains($0.key) }
        // Lamps are physically attached to existing machinery. They neither add
        // false cover nor turn a remote global state into a screen-space cue.
        for emitter in simulation.noiseEmitters {
            guard let ownerID=emitter.ownerObstacleID,
                  let owner=simulation.obstacles.first(where:{ $0.id==ownerID && !$0.destroyed }) else { continue }
            noiseEmitterVisualCount+=1
            for side:Float in [-1,1] {
                let position=owner.position+SIMD3(0,owner.size.y*0.72,side*(owner.size.z*0.5+0.009))
                appendItem(to:&items,position:position,scale:SIMD3(0.12,0.075,0.016),color:SIMD3(0.045,0.053,0.048),material:SIMD4(0.8,0.1,0,10))
                appendItem(to:&items,mesh:1,position:position+SIMD3(0,0,side*0.011),scale:SIMD3(0.026,0.019,0.008),
                    color:emitter.enabled ? SIMD3(0.31,0.52,0.14):SIMD3(0.045,0.06,0.035),
                    material:SIMD4(0.4,0,emitter.enabled ? 0.55:0,0),shadow:false)
            }
        }
        // The Core centre rests one 9 cm collision radius above its support.
        // A rounded 18 cm device uses that same lower envelope on ground/roofs.
        for decoy in simulation.decoys {
            noiseDecoyVisualCount+=1
            let position=decoy.position
            let pulse=decoyPulseTimes[decoy.id].map { simulation.elapsed-$0<0.18 } ?? false
            appendItem(to:&items,mesh:1,position:position,scale:SIMD3(0.084,0.09,0.084),color:SIMD3(0.14,0.21,0.23),material:SIMD4(0.68,0.2,0,15))
            appendItem(to:&items,mesh:2,position:position,scale:SIMD3(0.085,0.035,0.085),color:SIMD3(0.027,0.037,0.04),material:SIMD4(0.87,0,0,10))
            appendItem(to:&items,mesh:2,position:position+SIMD3(0,0.074,0),scale:SIMD3(0.033,0.015,0.033),color:SIMD3(0.22,0.24,0.20),material:SIMD4(0.6,0.5,0,9))
            appendItem(to:&items,mesh:1,position:position+SIMD3(0,0.085,0),scale:SIMD3(0.012,0.004,0.012),
                color:pulse ? SIMD3(0.9,0.43,0.06):SIMD3(0.12,0.065,0.025),material:SIMD4(0.4,0,pulse ? 1.1:0,0),shadow:false)
        }
        noisePropInstances=items.count-start
        assert(noisePropInstances<=NoiseEmitterState.maximumCount*4+NoiseDecoyState.maximumCount*4)
    }

    private func appendAlarmProps(to items:inout[RenderItem],simulation:CombatSimulation) {
        let start=items.count;alarmReporterVisualCount=0
        guard let alarm=map.environment.alarm else { alarmPropInstances=0;return }
        if let device=simulation.devices.first(where:{ $0.id==alarm.radioDeviceID }),!device.destroyed,
           simulation.obstacles.contains(where:{ $0.id==device.ownerObstacleID && !$0.destroyed }) {
            let part=NativeAlarmGeometry.moduleIndicator(position:map.grounded(alarm.radioPosition),powered:simulation.alarmStatus.radioPowered)
            appendTransformed(to:&items,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
        }
        for enemy in simulation.enemies.lazy.filter({ $0.health>0 }).prefix(NativeAlarmGeometry.maximumReporters) {
            let pending=simulation.pendingContactReports.first { $0.enemyID==enemy.id }
            let justSent=simulation.contactReports.contains { $0.enemyID==enemy.id && simulation.elapsed-$0.transmittedAt>=0 && simulation.elapsed-$0.transmittedAt<0.35 }
            if pending != nil { alarmReporterVisualCount+=1 }
            for part in NativeAlarmGeometry.reporter(enemy:enemy,progress:pending?.progress,
                radio:pending.map { $0.radioAtStart && !$0.radioCancelled } ?? false,transmitted:justSent) {
                appendTransformed(to:&items,mesh:part.mesh,transform:part.transform,color:part.color,material:part.material,shadow:part.castsShadow)
            }
        }
        alarmPropInstances=items.count-start
        assert(alarmPropInstances<=NativeAlarmGeometry.maximumReporters*NativeAlarmGeometry.reporterPartCount+1)
    }

    private func appendDeviceProps(to items:inout[RenderItem],simulation:CombatSimulation) {
        for light in simulation.spotlights {
            let rotation=simd_float4x4(simd_quatf(from:SIMD3<Float>(0,0,-1),to:light.direction))
            let base=Self.translation(light.position)*rotation
            appendTransformed(to:&items,mesh:9,transform:base*Self.translation(SIMD3(0,0,0.13))*Self.scale(SIMD3(0.43,0.22,0.25)),color:SIMD3(0.10,0.13,0.12),material:SIMD4(0.7,0.15,0,15))
            appendTransformed(to:&items,mesh:0,transform:base*Self.translation(SIMD3(0,0,-0.004))*Self.scale(SIMD3(0.34,0.15,0.008)),
                color:light.enabled ? light.color:SIMD3(0.09,0.10,0.085),material:SIMD4(0.4,0,light.enabled ? light.power*3:0,0),shadow:false)
        }
        for definition in map.environment.devices where definition.kind == .serviceGate {
            for point in definition.interactionPoints {
                let p=map.grounded(point)+SIMD3(0,0.9,0)
                appendItem(to:&items,position:p,scale:SIMD3(0.12,0.28,0.12),color:SIMD3(0.13,0.17,0.15),material:SIMD4(0.8,0.1,0,15))
                appendItem(to:&items,position:p-SIMD3(0,0.45,0),scale:SIMD3(0.06,0.9,0.06),color:SIMD3(0.12,0.15,0.13),material:SIMD4(0.8,0.1,0,15))
                appendTransformed(to:&items,mesh:2,transform:Self.translation(p+SIMD3(0,0,0.085))*Self.rotationX(.pi/2)*Self.scale(SIMD3(0.075,0.025,0.075)),color:SIMD3(0.55,0.38,0.11),material:SIMD4(0.7,0.4,0,9))
            }
        }
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
        func transformed(_ group:[RenderItem],_ matrix:simd_float4x4,clothing:Bool=false) {
            for item in group {
                let tint=item.instance.tint
                let material=clothing ? NativeCamouflageAppearance.material(item.instance.material,pattern:simulation.loadout.camouflage):item.instance.material
                appendTransformed(to:&out,mesh:item.mesh,transform:matrix*item.instance.model,color:SIMD3(tint.x,tint.y,tint.z),material:material,shadow:false)
            }
        }
        let reload=reloadPose(simulation), leftPose=base*reload.supportHandTransform
        transformed(parts.fixed,base); transformed(parts.rightHand,base,clothing:true)
        transformed(parts.magazine,base*reload.magazineTransform)
        transformed(parts.leftHand,leftPose,clothing:true)
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
            let cloth=NativeCamouflageAppearance.material(SIMD4(0.94,0,0,16),pattern:simulation.loadout.camouflage)
            appendTransformed(to:&out,mesh:14,transform:Self.translation((start+end)*0.5)*rotation*Self.scale(SIMD3(0.032,length,0.029)),color:SIMD3(0.24,0.27,0.20),material:cloth,shadow:false)
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

    func advanceEffects(deltaTime: Float, simulation: CombatSimulation) {
        let dt = min(0.1, max(0, deltaTime))
        weaponAimBlend += ((simulation.isAiming ? 1:0)-weaponAimBlend)*(1-exp(-dt*18))
        let target=weaponClearance(simulation)
        // Safety is immediate on approach; only recovery is smoothed, so a
        // sprint or sudden turn cannot leave the barrel inside nearby cover.
        if target>weaponWallBlend { weaponWallBlend=target }
        else { weaponWallBlend += (target-weaponWallBlend)*(1-exp(-dt*12)) }
        updateEffects(deltaTime: dt, terrain: simulation.terrain)
        combatEffects.step(deltaTime:dt,simulation:simulation)
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
        for i in tracers.indices { tracers[i].life -= deltaTime }; tracers.removeAll { $0.life <= 0 }
    }

    private func appendMissionVisuals(to items: inout [RenderItem], status: MissionStatus, operation: OperationStatus?, terrain: TerrainProfile) {
        missionPropCount=0; missionRingCount=0; missionPropShadowCount=0
        operationMarkerIDs.removeAll(keepingCapacity:true)
        if status.kind == .operation, status.phase == .extract, let operation {
            missionVisual=nil
            appendOperationExits(to:&items,status:operation,terrain:terrain)
            return
        }
        operationExitVisuals.removeAll(keepingCapacity:true)
        guard let position=status.objectivePosition, status.objectiveRadius>0,
              status.phase != .waves, status.phase != .completed else {
            missionVisual=nil
            return
        }
        if missionVisual?.kind != status.kind || missionVisual?.phase != status.phase ||
            missionVisual?.position != position || missionVisual?.radius != status.objectiveRadius ||
            missionVisual?.terrain != terrain {
            var props:[RenderItem]=[], ring:[RenderItem]=[]
            if status.phase == .collectData || status.phase == .prepareOperation || status.phase == .activateRadio || status.phase == .holdRadio {
                let local=missionProp(dataCase:status.phase == .collectData || status.phase == .prepareOperation)
                let normal=terrain.normal(x:position.x,z:position.z)
                var support=missionSurfacePoint(position,terrain:terrain)
                // Keep the authoritative objective height when a mission is
                // deliberately placed above the terrain by a future scenario.
                support.y=max(position.y,support.y)+0.003
                let base=Self.translation(support)*simd_float4x4(simd_quatf(from:SIMD3<Float>(0,1,0),to:normal))
                for item in local {
                    appendTransformed(to:&props,mesh:item.mesh,transform:base*item.instance.model,
                        color:SIMD3(item.instance.tint.x,item.instance.tint.y,item.instance.tint.z),
                        material:item.instance.material,shadow:item.shadow)
                }
            }
            // Thin ground strips replace the old level horizontal extraction
            // beam. Every endpoint samples the actual terrain/road support;
            // these projected cues never enter either directional shadow pass.
            ring.reserveCapacity(64)
            for i in 0..<64 {
                let angle=Float(i)/64*2*Float.pi, next=Float(i+1)/64*2*Float.pi
                let a=missionSurfacePoint(position+SIMD3(sin(angle)*status.objectiveRadius,0,cos(angle)*status.objectiveRadius),terrain:terrain)
                let b=missionSurfacePoint(position+SIMD3(sin(next)*status.objectiveRadius,0,cos(next)*status.objectiveRadius),terrain:terrain)
                let delta=b-a, length=simd_length(delta), along=delta/max(length,0.0001)
                let middle=(a+b)*0.5
                let up=terrain.normal(x:middle.x,z:middle.z)
                let right=simd_normalize(simd_cross(up,along)), normal=simd_normalize(simd_cross(along,right))
                // At triangle boundaries, lift by the tiny interpolation
                // difference rather than burying half a strip in the ground.
                let surface=missionSurfacePoint(middle,terrain:terrain)
                let center=SIMD3(middle.x,max(middle.y,surface.y)+0.016,middle.z)
                let transform=simd_float4x4(columns:(SIMD4(right*0.048,0),SIMD4(normal*0.003,0),SIMD4(along*length,0),SIMD4(center,1)))
                appendTransformed(to:&ring,mesh:0,transform:transform,color:SIMD3(repeating:1),material:SIMD4(1,0,0.45,0),shadow:false)
            }
            assert(props.count<=24 && ring.count<=64,"Mission geometry exceeded its fixed instance budget.")
            missionVisual=MissionVisual(kind:status.kind,phase:status.phase,position:position,radius:status.objectiveRadius,terrain:terrain,props:props,ring:ring)
        }
        guard let visual=missionVisual else { return }
        items.append(contentsOf:visual.props)
        missionPropCount=visual.props.count
        missionPropShadowCount=visual.props.filter(\.shadow).count
        let color:SIMD3<Float>
        if status.interruption == .contested { color=SIMD3(0.95,0.35,0.10) }
        else if status.phase == .extract { color=SIMD3(0.20,0.72,0.42) }
        else if status.phase == .holdRadio { color=SIMD3(0.18,0.61,0.75) }
        else { color=SIMD3(0.83,0.61,0.23) }
        let progress=max(0,min(1,status.progress/max(status.requiredProgress,0.001)))
        for (index,var item) in visual.ring.enumerated() {
            let complete=Float(index)<progress*Float(visual.ring.count)
            item.instance.tint=SIMD4(color*(complete ? 1:0.58),1)
            item.instance.material.z=complete ? 0.75:0.32
            items.append(item)
        }
        missionRingCount=visual.ring.count
    }

    private func appendOperationExits(to items: inout [RenderItem], status: OperationStatus, terrain: TerrainProfile) {
        assert(status.extractions.count<=NativeOperationVisual.maximumExits,"Operation exit count exceeded its authored limit.")
        let exits=status.extractions.filter(\.unlocked)
        let sameGeometry=operationExitVisuals.count==exits.count && zip(operationExitVisuals,exits).allSatisfy { cached,exit in
            cached.id==exit.id && cached.position==exit.position && cached.radius==exit.radius &&
                cached.routeKind==exit.routeKind && cached.terrain==terrain
        }
        if !sameGeometry {
            operationExitVisuals=exits.map { exit in
                let geometry=NativeOperationVisual.geometry(position:exit.position,radius:exit.radius,
                    routeKind:exit.routeKind,terrain:terrain,supportSurfaces:shellGroundColliders)
                @MainActor func convert(_ parts:[SoldierPart])->[RenderItem] {
                    var result:[RenderItem]=[];result.reserveCapacity(parts.count)
                    for part in parts {
                        appendTransformed(to:&result,mesh:part.mesh,transform:part.transform,
                            color:part.color,material:part.material,shadow:part.castsShadow)
                    }
                    return result
                }
                return OperationExitVisual(id:exit.id,position:exit.position,radius:exit.radius,routeKind:exit.routeKind,
                    terrain:terrain,props:convert(geometry.props),ring:convert(geometry.ring))
            }
        }
        for (visual,exit) in zip(operationExitVisuals,exits) {
            items.append(contentsOf:visual.props)
            missionPropCount+=visual.props.count
            missionPropShadowCount+=visual.props.filter(\.shadow).count
            for (index,var item) in visual.ring.enumerated() {
                let appearance=NativeOperationVisual.ringAppearance(exit:exit,segment:index)
                item.instance.tint=SIMD4(appearance.color,1)
                item.instance.material.z=appearance.emission
                items.append(item)
            }
            missionRingCount+=visual.ring.count
            operationMarkerIDs.append(exit.id)
        }
        assert(missionPropCount<=NativeOperationVisual.maximumExits*NativeOperationVisual.propPartsPerExit &&
               missionRingCount<=NativeOperationVisual.maximumExits*NativeOperationVisual.segmentsPerExit,
               "Operation marker geometry exceeded its fixed instance budget.")
    }

    private func missionSurfacePoint(_ point:SIMD3<Float>,terrain:TerrainProfile)->SIMD3<Float> {
        var height=terrain.height(x:point.x,z:point.z)
        // Same visible support boxes as shells and sole contacts, without any
        // new gameplay collision or an absolute-height assumption on hills.
        for surface in shellGroundColliders where abs(point.x-surface.position.x)<=surface.size.x*0.5 && abs(point.z-surface.position.z)<=surface.size.z*0.5 {
            height=max(height,surface.position.y+surface.size.y)
        }
        return SIMD3(point.x,height,point.z)
    }

    private func missionProp(dataCase:Bool)->[RenderItem] {
        var parts:[RenderItem]=[]
        parts.reserveCapacity(24)
        let polymer=SIMD4<Float>(0.84,0,0,10), metal=SIMD4<Float>(0.48,0.65,0,9)
        let olive=SIMD3<Float>(0.23,0.27,0.16), dark=SIMD3<Float>(0.055,0.064,0.055), steel=SIMD3<Float>(0.28,0.30,0.28)
        func part(_ p:SIMD3<Float>,_ size:SIMD3<Float>,_ color:SIMD3<Float>,mesh:Int=0,material:SIMD4<Float>?=nil,shadow:Bool=true) {
            appendItem(to:&parts,mesh:mesh,position:p,scale:size,color:color,material:material ?? polymer,shadow:shadow)
        }
        if dataCase {
            part(SIMD3(0,0.116,0),SIMD3(0.59,0.20,0.40),olive,mesh:9)
            part(SIMD3(0,0.218,0),SIMD3(0.601,0.009,0.411),dark)
            part(SIMD3(0,0.244,0),SIMD3(0.60,0.045,0.41),olive,mesh:9)
            for x:Float in [-0.255,0.255] { for z:Float in [-0.165,0.165] {
                part(SIMD3(x,0.043,z),SIMD3(0.075,0.08,0.075),dark,mesh:9)
            } }
            for x:Float in [-0.20,0.20] {
                part(SIMD3(x,0.219,0.21),SIMD3(0.05,0.065,0.018),steel,mesh:9,material:metal)
                part(SIMD3(x,0.217,-0.207),SIMD3(0.065,0.035,0.025),dark,mesh:9)
            }
            for x:Float in [-0.075,0.075] { part(SIMD3(x,0.167,0.244),SIMD3(0.024,0.060,0.032),dark,mesh:9) }
            part(SIMD3(0,0.197,0.244),SIMD3(0.171,0.023,0.032),dark,mesh:9)
            part(SIMD3(0,0.268,0),SIMD3(0.205,0.005,0.105),SIMD3(0.44,0.47,0.36),material:metal)
            part(SIMD3(0.20,0.270,0.07),SIMD3(0.021,0.006,0.012),SIMD3(0.95,0.61,0.18),material:SIMD4(0.4,0,0.7,0),shadow:false)
        } else {
            part(SIMD3(0,0.020,0),SIMD3(0.44,0.034,0.32),dark,mesh:9)
            part(SIMD3(0,0.149,0),SIMD3(0.40,0.23,0.28),olive,mesh:9)
            part(SIMD3(0,0.120,-0.173),SIMD3(0.31,0.18,0.07),dark,mesh:9)
            part(SIMD3(0,0.268,0),SIMD3(0.337,0.009,0.22),dark,mesh:9)
            part(SIMD3(-0.05,0.274,0.033),SIMD3(0.17,0.005,0.072),SIMD3(0.025,0.16,0.12),material:SIMD4(0.18,0,0.35,12),shadow:false)
            for x:Float in [-0.08,0.025] { part(SIMD3(x,0.286,-0.072),SIMD3(0.021,0.025,0.021),steel,mesh:2,material:metal) }
            for x:Float in [-0.226,0.226] {
                for z:Float in [-0.075,0.075] { part(SIMD3(x,0.186,z),SIMD3(0.021,0.035,0.024),dark,mesh:9) }
                part(SIMD3(x,0.203,0),SIMD3(0.021,0.020,0.174),dark,mesh:9)
            }
            for y:Float in [0.115,0.14,0.165] { part(SIMD3(0,y,0.142),SIMD3(0.19,0.008,0.005),dark,shadow:false) }
            part(SIMD3(0.145,0.285,-0.095),SIMD3(0.020,0.052,0.020),steel,mesh:2,material:metal)
            part(SIMD3(0.145,0.714,-0.095),SIMD3(0.0045,0.81,0.0045),dark,mesh:2,material:metal)
            part(SIMD3(0.145,1.124,-0.095),SIMD3(repeating:0.007),dark,mesh:1)
        }
        return parts
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
        let z = simd_normalize(eye - target), x = DirectionalShadowVolume.rightVector(for: z), y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0), SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }
    private static func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fov * 0.5), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }
    private static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(2 / (right - left), 0, 0, 0), SIMD4(0, 2 / (top - bottom), 0, 0), SIMD4(0, 0, 1 / (near - far), 0), SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), near / (near - far), 1)))
    }

    private static func makeMeshes(device: MTLDevice, map: MapDefinition) throws -> [Mesh] {
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
        let twig=NativeVegetationGeometry.photographicTwigVertices()
        let terrain=NativeMapGeometry.vertices(map:map)
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
        let named: [(String,[GPUVertex])] = Array(zip(["Box", "Sphere", "Cylinder", "Plane", "Grass", "Tapered bark", "Photographic twig", "Active map heightfield", "Weathered rock"], [cube,sphere,cylinder,plane,grass,trunk,twig,terrain,rock])) + WeaponGeometry.meshes()
        return try named.map { try makeMesh(device:device,name:$0.0,vertices:$0.1) }
    }
    private static func makeMesh(device:MTLDevice,name:String,vertices:[GPUVertex])throws->Mesh {
        guard !vertices.isEmpty,let buffer=device.makeBuffer(bytes:vertices,length:vertices.count*MemoryLayout<GPUVertex>.stride,options:.storageModeShared) else {
            throw RenderError.unavailable("Metal-Geometrie \(name) konnte nicht angelegt werden.")
        }
        var low=SIMD3<Float>(repeating:.infinity),high=SIMD3<Float>(repeating:-.infinity)
        for vertex in vertices { low=simd_min(low,vertex.position);high=simd_max(high,vertex.position) }
        buffer.label=name
        return Mesh(vertices:buffer,count:vertices.count,boundsCenter:(low+high)*0.5,halfExtents:(high-low)*0.5)
    }

    private static func makeSpotResources(device:MTLDevice,map:MapDefinition)throws->SpotResources {
        guard MemoryLayout<GPUWorldLight>.stride==128,MemoryLayout<GPUWorldLighting>.stride==272 else {
            throw RenderError.unavailable("Metal-Lichtdaten besitzen ein ungültiges Speicherlayout.")
        }
        var textures:[MTLTexture]=[],terrain:[Mesh]=[]
        for light in map.environment.spotlights {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:SpotShadowVolume.resolution,height:SpotShadowVolume.resolution,mipmapped:false)
            descriptor.storageMode = .private;descriptor.usage=[.renderTarget,.shaderRead]
            guard let texture=device.makeTexture(descriptor:descriptor) else { throw RenderError.unavailable("Schattenkarte der Lampe \(light.id) konnte nicht angelegt werden.") }
            texture.label="512 shared world lamp \(light.id) shadows";textures.append(texture)
            terrain.append(try makeMesh(device:device,name:"Exact terrain under lamp \(light.id)",
                vertices:NativeMapGeometry.shadowPatch(map:map,center:map.grounded(light.position),range:light.range)))
        }
        return SpotResources(textures:textures,terrain:terrain)
    }

    private static func makeVegetation(device:MTLDevice,root:URL,map:MapDefinition,firstMesh:Int)throws->VegetationResources {
        let zones=NativeVegetationGeometry.meshes(map:map)
        var buffers:[Mesh]=[],batches:[VegetationBatch]=[]
        for zone in zones {
            guard !zone.vertices.isEmpty else {
                throw RenderError.unavailable("Karte \(map.id): Vegetationszone \(zone.id) erzeugt keine sichtbaren Pflanzen. Bitte Ausdehnung und Pflanzenhöhe prüfen.")
            }
            let index=firstMesh+buffers.count
            buffers.append(try makeMesh(device:device,name:"Gameplay foliage \(zone.id)",vertices:zone.vertices))
            batches.append(VegetationBatch(id:zone.id,kind:zone.kind,mesh:index,plants:zone.plantCount))
        }
        var alpha:MTLTexture?
        if zones.contains(where:{ $0.kind == .brush }) {
            guard let path=map.resources.texturePaths[21],map.resources.texturePaths[9] != nil else {
                throw RenderError.unavailable("Karte \(map.id): Buschzonen benötigen eine fotografische Blattfarbe und Alphamaske.")
            }
            let crop=map.resources.textureCrops[21].map { NativeTextureCrop(normalizedX:Double($0.x),normalizedY:Double($0.y),width:Double($0.z),height:Double($0.w)) }
            // Gameplay coverage is a fixed profile in BOTH quality modes. The
            // colour/normal maps may use the usual profile without changing holes.
            alpha=try autoreleasepool { try NativeTextureLoader(device:device,highQuality:false).load(
                url:root.appendingPathComponent(map.resources.assetDirectory).appendingPathComponent(path),srgb:false,origin:.topLeft,crop:crop) }
            alpha?.label="Gameplay foliage fixed coverage"
        }
        return VegetationResources(meshes:buffers,batches:batches,alpha:alpha)
    }

    private static func resolveTextureRoot(assetRoot:URL?)throws->URL {
        let cwd=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let candidates=[assetRoot,Bundle.main.resourceURL?.appendingPathComponent("Assets"),cwd.appendingPathComponent("native/Assets"),cwd.appendingPathComponent("Assets")].compactMap { $0 }
        guard let root=candidates.first(where: { FileManager.default.fileExists(atPath:$0.path) }) else {
            throw RenderError.unavailable("Fotografische Landschaftstexturen fehlen. Bitte native/scripts/build-app.sh ausführen.")
        }
        return root
    }
    private static func makeNearShadow(device:MTLDevice,highQuality:Bool)throws->MTLTexture {
        let resolution=highQuality ? 2048:1024
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:resolution,height:resolution,mipmapped:false)
        descriptor.storageMode = .private;descriptor.usage=[.renderTarget,.shaderRead]
        guard let result=device.makeTexture(descriptor:descriptor) else { throw RenderError.unavailable("Nahschattenpuffer konnte nicht angelegt werden.") }
        result.label="Active stabilized near shadows \(resolution)";return result
    }
    private static func loadTextures(device:MTLDevice,root:URL,highQuality:Bool,resources:MapResourceReferences)throws->[MTLTexture] {
        let loader=NativeTextureLoader(device:device,highQuality:highQuality)
        func fallback(_ bytes:[UInt8],label:String)throws->MTLTexture {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
            descriptor.usage=[.shaderRead];descriptor.storageMode = .shared
            guard let texture=device.makeTexture(descriptor:descriptor) else { throw RenderError.unavailable("Neutrale Materialtextur konnte nicht angelegt werden.") }
            bytes.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:4) }
            texture.label=label;return texture
        }
        let white=try fallback([255,255,255,255],label:"Neutral material"),normal=try fallback([128,128,255,255],label:"Neutral normal")
        let sky=try fallback([92,112,130,255],label:"Neutral sky")
        let normals:Set<Int>=[1,4,7,12,15,18,20,26,29]
        let colors:Set<Int>=[0,3,6,9,11,14,17,23,25,28]
        var result=(0..<31).map { $0==23 ? sky:normals.contains($0) ? normal:white }
        var loaded:[String:MTLTexture]=[:]
        for (slot,path) in resources.texturePaths.sorted(by:{ $0.key<$1.key }) {
            guard (0..<31).contains(slot),slot != 10,slot != 24 else { throw RenderError.unavailable("Ungültiger Karten-Texturslot \(slot).") }
            let color=colors.contains(slot),rectangle=resources.textureCrops[slot]
            let crop=rectangle.map { NativeTextureCrop(normalizedX:Double($0.x),normalizedY:Double($0.y),width:Double($0.z),height:Double($0.w)) }
            let key="\(color)-\(String(describing:rectangle))-\(path)"
            if let existing=loaded[key] { result[slot]=existing;continue }
            let texture:MTLTexture=try autoreleasepool {
                do {
                    let texture=try loader.load(url:root.appendingPathComponent(resources.assetDirectory).appendingPathComponent(path),srgb:color,origin:.topLeft,crop:crop)
                    texture.label=path;return texture
                } catch { throw RenderError.unavailable("Textur \(path) konnte nicht geladen werden: \(error.localizedDescription)") }
            }
            loaded[key]=texture;result[slot]=texture
        }
        result[10]=result[0];result[24]=result[0]
        return result
    }
}
