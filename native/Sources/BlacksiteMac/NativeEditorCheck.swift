import AppKit
import SceneKit
import MetalKit
import BlacksiteCore
import Darwin

/// Reproducible offline integration/performance check, with the same document,
/// editor scene, file store and Metal game renderer used by the application.
@MainActor enum NativeEditorCheck {
    static func residentMB() -> Double {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size)/1_048_576 : -1
    }
    static func run(output: URL) throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func timed<T>(_ operation: () throws -> T) rethrows -> (T,Double) {
            let start = ProcessInfo.processInfo.systemUptime, result = try operation()
            return (result,(ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        var reports: [[String:Any]] = []
        let device = MTLCreateSystemDefaultDevice()
        for example in LevelExample.allCases {
            try autoreleasepool {
                let (document,authorMs) = try timed { try example.makeDocument() }
                let file = output.appendingPathComponent("editor-\(example.rawValue).blacksite-level.json")
                let (_,saveMs) = try timed { try LevelFileStore.save(document,to:file) }
                let (loaded,loadMs) = try timed { try LevelFileStore.read(file) }
                guard loaded == document else { throw LevelDocumentError("Roundtrip verändert \(example.title)") }
                let issues = loaded.playIssues()
                guard issues.isEmpty else { throw LevelDocumentError(issues.map(\.message).joined(separator:"\n")) }
                let (map,compileMs) = try timed { try loaded.makeMap() }
                let canvas = NativeEditorScene(frame:NSRect(x:0,y:0,width:1280,height:800))
                let (_,sceneMs) = try timed { try canvas.rebuild(loaded,selection:[]) }
                canvas.distance = Float(loaded.bounds.width)*0.85; canvas.updateCamera()
                var edits: [Double] = []
                for index in 0..<10 {
                    let (_,ms) = try timed { try canvas.rebuild(loaded,selection:[loaded.objects[index%loaded.objects.count].id]) }
                    edits.append(ms)
                }
                let editor = NativeEditorWindow(document:loaded,fileURL:file,store:LevelFileStore(root:output.appendingPathComponent("timing-store")))
                defer { editor.recoveryTimer?.invalidate(); editor.window?.orderOut(nil) }
                var uiSelection: [Double] = [], transforms: [Double] = []
                for index in 0..<10 {
                    let (_,ms) = timed { editor.session.selection = [loaded.objects[index%loaded.objects.count].id]; editor.refresh() }
                    uiSelection.append(ms)
                }
                for _ in 0..<5 {
                    let (_,ms) = try timed {
                        try editor.session.edit("Bewegen") { $0.objects[0].position.x += 0.1 }; editor.refresh()
                    }; transforms.append(ms)
                }
                let sceneRenderer = SCNRenderer(device:device,options:nil)
                sceneRenderer.scene = canvas.scene; sceneRenderer.pointOfView = canvas.cameraNode
                var frameMs: [Double] = []
                for frame in 0..<40 {
                    let (_,ms) = timed { autoreleasepool { _ = sceneRenderer.snapshot(atTime:Double(frame)/30,with:CGSize(width:1280,height:800),antialiasingMode:.multisampling2X) } }
                    if frame >= 10 { frameMs.append(ms) }
                }
                let sceneImage = sceneRenderer.snapshot(atTime:2,with:CGSize(width:1280,height:800),antialiasingMode:.multisampling2X)
                if let tiff = sceneImage.tiffRepresentation,let bitmap = NSBitmapImageRep(data:tiff),let png = bitmap.representation(using:.png,properties:[:]) { try png.write(to:output.appendingPathComponent("editor-\(example.rawValue).png")) }
                let view = MTKView(frame:canvas.frame,device:device)
                let renderer = try NativeRenderer(view:view,assetRoot:NativeResources.assetRoot,highQuality:false,map:map)
                let game = CombatSimulation(map:map,seed:42,mission:loaded.missionKind)
                for _ in 0..<120 { game.step(deltaTime:1.0/120,input:GameInput()) }
                let graphics = try renderer.benchmark(simulation:game,width:1280,height:800,frames:60)
                try renderer.renderOffscreen(simulation:game,width:1280,height:800,to:output.appendingPathComponent("game-\(example.rawValue).png"))
                reports.append(["example":example.rawValue,"objects":loaded.objects.count,"width":loaded.bounds.width,"depth":loaded.bounds.depth,
                    "authorMs":authorMs,"saveMs":saveMs,"loadMs":loadMs,"compileMs":compileMs,"sceneBuildMs":sceneMs,
                    "selectionAverageMs":edits.reduce(0,+)/Double(edits.count),"selectionMaxMs":edits.max() ?? 0,
                    "fullInspectorSelectionAverageMs":uiSelection.reduce(0,+)/Double(uiSelection.count),"transformAndInspectorAverageMs":transforms.reduce(0,+)/Double(transforms.count),
                    "editorSerialFrameMs":frameMs.reduce(0,+)/Double(frameMs.count),"residentMB":residentMB(),"game":graphics])
            }
        }
        let reference = output.appendingPathComponent("editor-woodland.blacksite-level.json")
        var cycles: [Double] = [], allocations: [Int] = []
        for _ in 0..<10 {
            try autoreleasepool {
                let doc = try LevelFileStore.read(reference), map = try doc.makeMap()
                let editor = NativeEditorWindow(document:doc,fileURL:reference,store:LevelFileStore(root:output.appendingPathComponent("cycle-store")))
                defer { editor.recoveryTimer?.invalidate(); editor.window?.orderOut(nil) }
                let view = MTKView(frame:NSRect(x:0,y:0,width:1280,height:800),device:device)
                let renderer = try NativeRenderer(view:view,assetRoot:NativeResources.assetRoot,highQuality:false,map:map)
                let game = CombatSimulation(map:map,seed:42,mission:doc.missionKind)
                _ = try renderer.benchmark(simulation:game,width:1280,height:800,frames:1)
            }
            cycles.append(residentMB()); allocations.append(device?.currentAllocatedSize ?? 0)
        }
        let result: [String:Any] = ["result":"pass","device":device?.name ?? "unavailable","os":ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryGB":Double(ProcessInfo.processInfo.physicalMemory)/1_073_741_824,"quality":"balanced game; editor SceneKit 2x MSAA",
            "resolution":"1280x800","editorFrameMethod":"serial offscreen snapshots incl. CPU readback, 10 warmup + 30 measured",
            "examples":reports,"cycleResidentMB":cycles,"cycleGPUAllocatedBytes":allocations]
        let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:output.appendingPathComponent("measurements.json"),options:.atomic)
        print(String(decoding:data,as:UTF8.self))
    }
}
