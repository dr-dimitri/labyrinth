import AppKit
import SceneKit
import BlacksiteCore
import simd

/// Camera input is deliberately separate from document tools: right drag orbits,
/// middle drag pans, wheel zooms. Left mouse and keyboard operate only this view.
@MainActor
final class NativeEditorScene: SCNView {
    let world = SCNNode(), cameraNode = SCNNode()
    var target = SIMD3<Float>(0, 0, 0), distance: Float = 45, yaw: Float = 0.6, pitch: Float = 0.8
    var topDown = false { didSet { updateCamera() } }
    var hovered: ((SIMD3<Float>)->Void)?
    private var tracking: NSTrackingArea?
    var picked: ((String?, SIMD3<Float>?, NSEvent) -> Void)?
    var dragged: ((SIMD3<Float>, NSEvent) -> Void)?
    var released: (() -> Void)?
    var cancelled: (() -> Void)?
    var keyAction: ((UInt16) -> Void)?
    private var terrain: TerrainProfile = .flat
    private var cachedDocument: LevelDocument?, cachedSelection: Set<String> = []
    private var selectableNodes: [(String,SCNNode,NSColor)] = []
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        scene = SCNScene(); scene?.rootNode.addChildNode(world)
        cameraNode.camera = SCNCamera(); cameraNode.camera?.zFar = 2000
        scene?.rootNode.addChildNode(cameraNode); pointOfView = cameraNode
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 650; scene?.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.name = "sun"; sun.light = SCNLight(); sun.light?.type = .directional
        sun.light?.intensity = 900; sun.eulerAngles = SCNVector3(-0.8, -0.6, 0)
        scene?.rootNode.addChildNode(sun)
        backgroundColor = NSColor(hex: 0x263a44); antialiasingMode = .multisampling2X
        preferredFramesPerSecond = 30; rendersContinuously = false
        setAccessibilityLabel("Levelansicht. Linksklick: auswählen. Rechtsziehen: Kamera. Mittlere Taste: verschieben. Mausrad: Zoom.")
        updateCamera()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func updateCamera() {
        cameraNode.camera?.usesOrthographicProjection = topDown
        cameraNode.camera?.orthographicScale = Double(distance)
        if topDown {
            cameraNode.simdPosition = target + SIMD3(0, distance, 0)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        } else {
            cameraNode.simdPosition = target + SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
            cameraNode.look(at: SCNVector3(target))
        }
        needsDisplay = true
    }
    func focus(_ point: SIMD3<Float>) { target = point; updateCamera() }
    func rebuild(_ document: LevelDocument, selection: Set<String>) throws {
        if cachedDocument == document { updateSelection(document,selection); return }
        let map = try document.makeMap(purpose: .preview); terrain = map.terrain
        cachedDocument = document; cachedSelection = []; selectableNodes.removeAll(keepingCapacity:true)
        world.childNodes.forEach { $0.removeFromParentNode() }
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var groups = Array(repeating: [Int32](),count: 4)
        let b = document.bounds, stride = b.width + 1
        for z in 0...b.depth { for x in 0...b.width {
            vertices.append(SCNVector3(Float(b.x + x), document.terrain.heights[z * stride + x], Float(b.z + z)))
            normals.append(SCNVector3(terrain.normal(x: Float(b.x+x),z: Float(b.z+z))))
        } }
        for z in 0..<b.depth { for x in 0..<b.width {
            let a = Int32(z * stride + x), c = a + Int32(stride)
            let region = document.environment.surfaces.last { Float(b.x+x)+0.5 >= $0.x && Float(b.x+x)+0.5 <= $0.x+$0.width && Float(b.z+z)+0.5 >= $0.z && Float(b.z+z)+0.5 <= $0.z+$0.depth }
            let materialIndex = LevelGroundMaterial.allCases.firstIndex(of: region?.material ?? .earth) ?? 0
            groups[materialIndex] += [a, c, a + 1, a + 1, c, c + 1]
        } }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: groups.map { SCNGeometryElement(indices: $0,primitiveType: .triangles) })
        geometry.materials = [0x79694e,0x568043,0x848788,0x383e42].map { material(NSColor(hex: $0)) }
        geometry.materials.forEach { $0.isDoubleSided = true }
        let ground = SCNNode(geometry: geometry); ground.name = "ground"; ground.categoryBitMask = 1; world.addChildNode(ground)
        for object in document.objects where !object.hidden {
            for part in LevelObjectCatalog.placedParts(for: object,terrain: terrain) {
                let color = NSColor(calibratedRed: CGFloat(part.color.x),green: CGFloat(part.color.y),blue: CGFloat(part.color.z),alpha: 1)
                let node = box(part.size,center: part.center,color: color)
                selectableNodes.append((object.id,node,color))
                node.name = object.id; node.categoryBitMask = 2; world.addChildNode(node)
            }
        }
        for marker in document.markers {
            let node = SCNNode(geometry: SCNSphere(radius: 0.38))
            node.geometry?.firstMaterial = material(.systemCyan)
            selectableNodes.append((marker.id,node,.systemCyan))
            node.simdPosition = map.grounded(marker.position.value) + SIMD3(0, 0.4, 0)
            node.name = marker.id; node.categoryBitMask = 4; world.addChildNode(node)
            if marker.kind == .playerStart {
                let forward = SIMD3<Float>(-sin(marker.yaw),0,-cos(marker.yaw))
                let arrow = box(SIMD3(0.12,0.12,1.5),center: node.simdPosition+forward*0.8,color: .systemCyan)
                arrow.simdEulerAngles.y = marker.yaw; arrow.categoryBitMask = 8; world.addChildNode(arrow)
            }
            if marker.kind == .extraction {
                let ring = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(marker.radius),pipeRadius: 0.04))
                ring.simdPosition = node.simdPosition-SIMD3(0,0.3,0); ring.geometry?.firstMaterial = material(.systemYellow); ring.categoryBitMask = 8; world.addChildNode(ring)
            }
        }
        let environment = document.environment
        backgroundColor = NSColor(calibratedRed: CGFloat(environment.fogColor.x),green: CGFloat(environment.fogColor.y),blue: CGFloat(environment.fogColor.z),alpha: 1)
        if let sun = scene?.rootNode.childNode(withName: "sun",recursively: false) {
            let direction = simd_normalize(environment.sunDirection.value)
            sun.simdPosition = direction*100
            sun.look(at: SCNVector3Zero,up: abs(direction.y)>0.99 ? SCNVector3(0,0,1) : SCNVector3(0,1,0),localFront: SCNVector3(0,0,-1))
            sun.light?.intensity = CGFloat(environment.sunIntensity*900)
        }
        for water in environment.water {
            let node = box(SIMD3(Float(water.width),0.02,Float(water.depth)),center: SIMD3(Float(water.x)+Float(water.width)/2,water.surfaceHeight,Float(water.z)+Float(water.depth)/2),color: .systemBlue)
            node.opacity = 0.65; node.categoryBitMask = 8; world.addChildNode(node)
        }
        for zone in map.environment.vegetationZones {
            for index in 0..<zone.requiredPlantCount {
                let angle = Float(index)*2.39996, r = sqrt(Float(index+1)/Float(zone.requiredPlantCount))*zone.radii.x
                let x = zone.center.x+cos(angle)*r, z = zone.center.y+sin(angle)*r
                let node = box(SIMD3(0.12,zone.height,0.12),center: SIMD3(x,terrain.height(x: x,z: z)+zone.height/2,z),color: .systemGreen)
                node.categoryBitMask = 8; world.addChildNode(node)
            }
        }
        // One-metre grid and a distinct perimeter, both following the same heightfield.
        var grid: [SCNVector3] = [], lines: [Int32] = []
        func line(_ x: Float, _ z: Float, _ xx: Float, _ zz: Float) {
            let n = Int32(grid.count)
            grid += [SCNVector3(x, terrain.height(x: x, z: z) + 0.025, z), SCNVector3(xx, terrain.height(x: xx, z: zz) + 0.025, zz)]
            lines += [n, n + 1]
        }
        for z in 0...b.depth { for x in 0..<b.width { line(Float(b.x+x), Float(b.z+z), Float(b.x+x+1), Float(b.z+z)) } }
        for x in 0...b.width { for z in 0..<b.depth { line(Float(b.x+x), Float(b.z+z), Float(b.x+x), Float(b.z+z+1)) } }
        let mesh = SCNGeometry(sources: [SCNGeometrySource(vertices: grid)], elements: [SCNGeometryElement(indices: lines, primitiveType: .line)])
        mesh.firstMaterial = material(NSColor.black.withAlphaComponent(0.5)); mesh.firstMaterial?.lightingModel = .constant
        let gridNode = SCNNode(geometry: mesh); gridNode.categoryBitMask = 8; world.addChildNode(gridNode)
        let left = Float(b.x), north = Float(b.z), width = Float(b.width), depth = Float(b.depth)
        let perimeter: [(SIMD3<Float>,SIMD3<Float>)] = [
            (SIMD3(left,0,north+depth/2),SIMD3(0.1,0.3,depth)),
            (SIMD3(left+width,0,north+depth/2),SIMD3(0.1,0.3,depth)),
            (SIMD3(left+width/2,0,north),SIMD3(width,0.3,0.1)),
            (SIMD3(left+width/2,0,north+depth),SIMD3(width,0.3,0.1))]
        for (center, size) in perimeter {
            var p = center; p.y = terrain.height(x: p.x,z: p.z)
            let node = box(size, center: p, color: .systemYellow); node.categoryBitMask = 8; world.addChildNode(node)
        }
        updateSelection(document,selection)
    }
    private func updateSelection(_ document: LevelDocument,_ selection: Set<String>) {
        let changed = cachedSelection.symmetricDifference(selection)
        for (id,node,color) in selectableNodes where changed.contains(id) {
            node.geometry?.firstMaterial?.diffuse.contents = selection.contains(id) ? NSColor.systemOrange : color
        }
        cachedSelection = selection
        world.childNodes.filter { $0.categoryBitMask == 16 }.forEach { $0.removeFromParentNode() }
        let selected = document.objects.filter { selection.contains($0.id) && !$0.locked && !$0.hidden }
        if !selected.isEmpty {
            var center = selected.reduce(SIMD3<Float>.zero) { $0+$1.position.value } / Float(selected.count)
            center.y = terrain.height(x: center.x,z: center.z)+0.5
            for (name,offset,color) in [("move.x",SIMD3<Float>(2,0,0),NSColor.systemRed),("move.z",SIMD3<Float>(0,0,2),NSColor.systemBlue),("scale",SIMD3<Float>(2,0,2),NSColor.systemYellow),("rotate",SIMD3<Float>(-2,0,2),NSColor.systemCyan)] {
                let node = box(SIMD3(repeating: 0.55),center: center+offset,color: color); node.name = "handle:"+name; node.categoryBitMask = 16; world.addChildNode(node)
            }
        }
        needsDisplay = true
    }
    func clearGhost() { scene?.rootNode.childNode(withName: "placement",recursively: false)?.removeFromParentNode() }
    func showGhost(_ object: LevelObject) {
        clearGhost(); let root = SCNNode(); root.name = "placement"
        for part in LevelObjectCatalog.placedParts(for: object,terrain: terrain) {
            let node = box(part.size,center: part.center,color: .systemCyan); node.opacity = 0.4; node.categoryBitMask = 32; root.addChildNode(node)
        }
        scene?.rootNode.addChildNode(root); needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,options: [.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner: self,userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { if let p = groundPoint(event) { hovered?(p) } }
    func material(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial(); material.diffuse.contents = color; material.roughness.contents = 0.9
        return material
    }
    func box(_ size: SIMD3<Float>, center: SIMD3<Float>, color: NSColor) -> SCNNode {
        let node = SCNNode(geometry: SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0))
        node.geometry?.firstMaterial = material(color); node.simdPosition = center; return node
    }
    func groundPoint(_ event: NSEvent) -> SIMD3<Float>? {
        let point = convert(event.locationInWindow, from: nil)
        return hitTest(point, options: [.categoryBitMask: 1]).first.map { SIMD3($0.worldCoordinates) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let screen = convert(event.locationInWindow, from: nil)
        let hit = hitTest(screen,options: [.categoryBitMask: 16]).first ?? hitTest(screen, options: [.categoryBitMask: 6]).first
        picked?(hit?.node.name, groundPoint(event), event)
    }
    override func mouseDragged(with event: NSEvent) { if let point = groundPoint(event) { dragged?(point, event) } }
    override func mouseUp(with event: NSEvent) { released?() }
    override func rightMouseDragged(with event: NSEvent) {
        yaw -= Float(event.deltaX) * 0.01; pitch = min(1.5, max(0.08, pitch + Float(event.deltaY) * 0.01)); updateCamera()
    }
    override func otherMouseDragged(with event: NSEvent) {
        target.x -= Float(event.deltaX) * distance * 0.002; target.z -= Float(event.deltaY) * distance * 0.002; updateCamera()
    }
    override func scrollWheel(with event: NSEvent) { distance = min(300, max(4, distance * exp(Float(event.scrollingDeltaY) * 0.015))); updateCamera() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled?() } else { keyAction?(event.keyCode) }
    }
}
