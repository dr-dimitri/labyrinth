import Foundation
import Metal
import simd
import BlacksiteCore

/// World bounds of the actual cached cover mesh's axis-aligned box parts.
struct CombatSurfaceBox: Sendable {
    let minimum:SIMD3<Float>
    let maximum:SIMD3<Float>
}
struct CombatSurfaceProjection: Sendable {
    let position:SIMD3<Float>
    let radius:Float
}

/// Bounded world-space effects. No emitter is tied to render frequency, and no
/// transparent particle is submitted to an opaque shadow pass.
@MainActor
final class NativeCombatEffects {
    private struct Particle {
        var position:SIMD3<Float>
        var velocity:SIMD3<Float>
        var color:SIMD3<Float>
        var age:Float = 0
        var lifetime:Float
        var radius:Float
        var rotation:Float
        var aspect:Float
        var opacity:Float
        var gravity:Float
        var kind:Int // 0 smoke, 1 dust, 2 sparks, 3 chips, 4 flash
    }
    private struct Decal {
        var position:SIMD3<Float> // local to an obstacle, otherwise world space
        var normal:SIMD3<Float>
        var tangent:SIMD3<Float>
        var material:SurfaceMaterial
        var obstacleID:Int?
        var radius:Float
        var seed:Float
        var age:Float = 0
    }
    // These layouts are mirrored by CombatParticle/CombatDecal in Shaders.metal.
    private struct ParticleGPU { var positionAge:SIMD4<Float>;var shape:SIMD4<Float>;var tintAspect:SIMD4<Float>;var supportPlane:SIMD4<Float> }
    private struct DecalGPU { var positionOpacity:SIMD4<Float>;var axisU:SIMD4<Float>;var axisV:SIMD4<Float>;var tintKind:SIMD4<Float> }
    private enum Failure:LocalizedError {
        case resource(String)
        var errorDescription:String? { if case .resource(let value)=self { return value };return nil }
    }
    private var particles:[Particle] = []
    private var decals:[Decal] = []
    private var obstaclePositions:[Int:SIMD3<Float>] = [:]
    private var random:UInt64 = 0x91ab34
    private let alphaPipelines:[Int:MTLRenderPipelineState]
    private let additivePipelines:[Int:MTLRenderPipelineState]
    private let decalPipelines:[Int:MTLRenderPipelineState]
    private let depth:MTLDepthStencilState
    private let particleBuffers:[MTLBuffer]
    private let decalBuffers:[MTLBuffer]
    private var alphaCounts=[0,0,0],additiveCounts=[0,0,0],decalCounts=[0,0,0]
    private var alphaDepths=[[Float]](repeating:[],count:3),additiveDepths=[[Float]](repeating:[],count:3)
    private var particleLimit=256,decalLimit=80
    private var droppedParticles=0,droppedDecals=0,ignoredShots=0
    private(set) var drawCallCount=0

    var diagnostics:[String:Any] {
        ["combatParticles":particles.count,"impactDecals":decals.count,
         "combatParticleLimit":particleLimit,"impactDecalLimit":decalLimit,
         "combatParticleDrops":droppedParticles,"impactDecalDrops":droppedDecals,
         "shotsWithoutSurfaceImpact":ignoredShots,"combatEffectDrawCalls":drawCallCount,
         "activeSmoke":particles.filter { $0.kind==0 }.count,
         "activeSparks":particles.filter { $0.kind==2 }.count,
         "activeFlashes":particles.filter { $0.kind==4 }.count,
         "decalMaterials":Dictionary(grouping:decals,by: { $0.material.rawValue }).mapValues { $0.count }]
    }

    init(device:MTLDevice,library:MTLLibrary) throws {
        guard MemoryLayout<ParticleGPU>.stride==64,MemoryLayout<DecalGPU>.stride==64,
              let particleVertex=library.makeFunction(name:"combatParticleVertex"),
              let particleFragment=library.makeFunction(name:"combatParticleFragment"),
              let decalVertex=library.makeFunction(name:"combatDecalVertex"),
              let decalFragment=library.makeFunction(name:"combatDecalFragment") else {
            throw Failure.resource("Metal-Einschlagshader fehlen oder besitzen ein ungültiges Datenlayout.")
        }
        func pipeline(samples:Int,additive:Bool,decal:Bool)throws->MTLRenderPipelineState {
            let p=MTLRenderPipelineDescriptor();p.label=decal ? "Oriented material impact decals":"Instanced translucent combat particles"
            p.vertexFunction=decal ? decalVertex:particleVertex;p.fragmentFunction=decal ? decalFragment:particleFragment
            p.depthAttachmentPixelFormat = .depth32Float;p.rasterSampleCount=samples
            let color=p.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm_srgb;color.isBlendingEnabled=true
            color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor=additive ? .one:.oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .zero;color.destinationAlphaBlendFactor = .one
            return try device.makeRenderPipelineState(descriptor:p)
        }
        var alpha:[Int:MTLRenderPipelineState]=[:],additive:[Int:MTLRenderPipelineState]=[:],marks:[Int:MTLRenderPipelineState]=[:]
        for samples in [1,4] where device.supportsTextureSampleCount(samples) {
            alpha[samples]=try pipeline(samples:samples,additive:false,decal:false)
            additive[samples]=try pipeline(samples:samples,additive:true,decal:false)
            marks[samples]=try pipeline(samples:samples,additive:false,decal:true)
        }
        alphaPipelines=alpha;additivePipelines=additive;decalPipelines=marks
        let d=MTLDepthStencilDescriptor();d.depthCompareFunction = .lessEqual;d.isDepthWriteEnabled=false
        guard let state=device.makeDepthStencilState(descriptor:d) else { throw Failure.resource("Effekt-Tiefentest konnte nicht angelegt werden.") }
        depth=state
        func buffers(_ length:Int,_ name:String)throws->[MTLBuffer] {
            try (0..<3).map { slot in
                guard let b=device.makeBuffer(length:length,options:.storageModeShared) else { throw Failure.resource("Effektpuffer konnte nicht angelegt werden.") }
                b.label="\(name) frame \(slot)";return b
            }
        }
        particleBuffers=try buffers(256*MemoryLayout<ParticleGPU>.stride,"Bounded combat particles")
        decalBuffers=try buffers(80*MemoryLayout<DecalGPU>.stride,"Stable obstacle impact decals")
        particles.reserveCapacity(256);decals.reserveCapacity(80)
    }

    func reset() {
        particles.removeAll(keepingCapacity:true);decals.removeAll(keepingCapacity:true);obstaclePositions.removeAll(keepingCapacity:true)
        alphaCounts=[0,0,0];additiveCounts=[0,0,0];decalCounts=[0,0,0]
        alphaDepths=[[Float]](repeating:[],count:3);additiveDepths=[[Float]](repeating:[],count:3)
        droppedParticles=0;droppedDecals=0;ignoredShots=0;drawCallCount=0;random=0x91ab34
    }
    /// A cover mesh replacement invalidates its old projected surface points.
    /// The current event batch can then place new marks on the updated mesh.
    func removeDecals(obstacleID:Int) { decals.removeAll { $0.obstacleID == obstacleID } }
    private func unit()->Float { random=random &* 2862933555777941757 &+ 3037000493;return Float((random>>32)&0xffffff)/Float(0xffffff) }
    private func vector()->SIMD3<Float> { let a=unit()*2 * Float.pi,y=unit()*2-1,r=sqrt(max(0,1-y*y));return SIMD3(cos(a)*r,y,sin(a)*r) }
    private func add(_ particle:Particle) {
        if particles.count>=particleLimit { particles.removeFirst();droppedParticles+=1 }
        particles.append(particle)
    }
    private func syncSupports(_ simulation:CombatSimulation) {
        obstaclePositions.removeAll(keepingCapacity:true)
        for obstacle in simulation.obstacles where !obstacle.destroyed { obstaclePositions[obstacle.id]=obstacle.position }
        decals.removeAll { mark in mark.obstacleID.map { obstaclePositions[$0]==nil } ?? false }
    }
    func handle(events:[GameEvent],simulation:CombatSimulation,highQuality:Bool,surfaceBoxes:[Int:[CombatSurfaceBox]] = [:]) {
        particleLimit=highQuality ? 256:128;decalLimit=highQuality ? 80:40
        if particles.count>particleLimit { droppedParticles+=particles.count-particleLimit;particles.removeFirst(particles.count-particleLimit) }
        if decals.count>decalLimit { droppedDecals+=decals.count-decalLimit;decals.removeFirst(decals.count-decalLimit) }
        syncSupports(simulation)
        let destroyed=Set(events.filter { $0.kind == .coverDestroyed }.map(\.id))
        decals.removeAll { $0.obstacleID.map { destroyed.contains($0) } ?? false }
        for event in events {
            if let water=event.waterImpact {
                waterSplash(at:water.position,strength:event.kind == .explosion ? 1:0.5,highQuality:highQuality)
            } else if let hearing=event.hearing,hearing.surface == .water,
                      hearing.kind == .footstep || hearing.kind == .landing,
                      let water=simulation.map.waterSurface(at:hearing.position) {
                waterSplash(at:SIMD3(hearing.position.x,water.surfaceHeight,hearing.position.z),
                    strength:hearing.kind == .landing ? 0.7:0.28,highQuality:highQuality)
            }
            switch event.kind {
            case .shot,.enemyShot:
                guard let hit=event.surfaceImpact else { if event.kind == .shot { ignoredShots+=1 };continue }
                let removed=hit.obstacleID.map { destroyed.contains($0) || obstaclePositions[$0]==nil } ?? false
                impact(hit,simulation:simulation,createDecal:!removed,highQuality:highQuality,boxes:hit.obstacleID.flatMap { surfaceBoxes[$0] } ?? [])
            case .explosion: explosion(at:event.position,highQuality:highQuality)
            case .coverDestroyed:
                let kind=simulation.obstacles.first { $0.id==event.id }?.kind
                let color:SIMD3<Float> = kind == .crate ? SIMD3(0.34,0.23,0.11):kind == .glass ? SIMD3(0.63,0.72,0.68):SIMD3(0.27,0.27,0.24)
                for _ in 0..<(highQuality ? 12:6) {
                    add(Particle(position:event.position,velocity:vector()*(1.5+unit()*3)+SIMD3(0,1.5,0),color:color,lifetime:1.2+unit()*0.7,radius:0.025+unit()*0.035,rotation:unit()*6.28,aspect:0.35,opacity:0.95,gravity:8,kind:3))
                }
            default:break
            }
        }
    }

    private func impact(_ hit:SurfaceImpact,simulation:CombatSimulation,createDecal:Bool,highQuality:Bool,boxes:[CombatSurfaceBox]) {
        let normal=simd_normalize(hit.normal),material=hit.material
        guard normal.x.isFinite,normal.y.isFinite,normal.z.isFinite else { return }
        var point=hit.position
        if hit.obstacleID==nil && normal.y>0.8 {
            for support in simulation.map.groundedSupportSurfaces where !support.destroyed {
                if abs(point.x-support.position.x)<=support.size.x*0.5 && abs(point.z-support.position.z)<=support.size.z*0.5 {
                    point.y=max(point.y,support.position.y+support.size.y)
                }
            }
        }
        let tint:SIMD3<Float>
        switch material {
        case .soil:tint=SIMD3(0.28,0.22,0.14)
        case .concrete:tint=SIMD3(0.46,0.45,0.40)
        case .metal:tint=SIMD3(0.26,0.27,0.25)
        case .wood:tint=SIMD3(0.44,0.30,0.13)
        case .asphalt:tint=SIMD3(0.17,0.18,0.18)
        case .glass:tint=SIMD3(0.62,0.73,0.69)
        }
        // A submerged solid still owns its decal and ballistic hit. Dry dust
        // would misrepresent that surface; its separate crossing supplies spray.
        let submerged=simulation.map.waterSurface(at:point).map { point.y < $0.surfaceHeight-0.005 } ?? false
        let count=submerged ? 0:highQuality ? 8:4
        for index in 0..<count {
            let spark=material == .metal && index<count-2
            let chip=material == .glass || (material == .wood && index%2==0) || (material != .metal && index%3==0)
            let kind=spark ? 2:chip ? 3:1
            let direction=simd_normalize(normal*(1.2+unit())+vector()*0.7)
            add(Particle(position:point+normal*0.018,velocity:direction*(spark ? 3+unit()*6:chip ? 1+unit()*2:0.4+unit()*0.8),
                color:spark ? SIMD3(1,0.52,0.10):tint,lifetime:spark ? 0.12+unit()*0.22:chip ? 0.6+unit()*0.6:0.45+unit()*0.55,
                radius:spark ? 0.06+unit()*0.04:chip ? 0.016+unit()*0.025:0.09+unit()*0.08,rotation:unit()*6.28,
                aspect:spark ? 0.07:chip ? (material == .wood ? 0.24:0.65):1,opacity:spark ? 1:chip ? 0.92:0.36,gravity:spark || chip ? 8:0,kind:kind))
        }
        // The pane shader supplies its actual damaged fracture state; opaque
        // bullet-hole discs would incorrectly float in front of clear glass.
        guard createDecal,material != .glass else { return }
        var n=normal,radius:Float = material == .soil ? 0.070:material == .concrete ? 0.050:material == .wood ? 0.042:0.034
        let obstacle=hit.obstacleID.flatMap { id in simulation.obstacles.first { $0.id==id && !$0.destroyed } }
        if let box=obstacle {
            let local=point-box.position
            if let projected=Self.projectSurface(at:point,normal:n,radius:radius,boxes:boxes) {
                point=projected.position;radius=projected.radius
                guard radius>0.008 else { return }
            } else if box.kind == .barrel && abs(n.y)<0.5 {
                // The collider is an AABB, the rendered barrel is round. Use its
                // actual cylinder surface for a tiny tangent-space scorch mark.
                let radial=SIMD2(local.x/(box.size.x*0.5),local.z/(box.size.z*0.5))
                guard simd_length_squared(radial)>0.001 else { return }
                let q=simd_normalize(radial)
                point.x=box.position.x+q.x*box.size.x*0.5;point.z=box.position.z+q.y*box.size.z*0.5
                n=simd_normalize(SIMD3(q.x/box.size.x,0,q.y/box.size.z));radius=min(radius,0.022)
            } else if box.kind == .barrel || boxes.isEmpty {
                let extent=box.size*0.5,center=local-SIMD3(0,box.size.y*0.5,0),a=simd_abs(n)
                let margin=a.y>0.5 ? min(extent.x-abs(center.x),extent.z-abs(center.z)):
                    a.x>0.5 ? min(extent.y-abs(center.y),extent.z-abs(center.z)):min(extent.x-abs(center.x),extent.y-abs(center.y))
                radius=min(radius,margin*0.68)
                guard radius>0.008 else { return }
            } else { return }
        }
        let helper=abs(n.y)<0.9 ? SIMD3<Float>(0,1,0):SIMD3<Float>(1,0,0)
        let tangent=simd_normalize(simd_cross(helper,n)),angle=unit()*2 * Float.pi
        let direction=tangent*cos(angle)+simd_cross(n,tangent)*sin(angle)
        point += n*0.0025
        if decals.count>=decalLimit { decals.removeFirst();droppedDecals+=1 }
        decals.append(Decal(position:point-(obstacle?.position ?? .zero),normal:n,tangent:direction,material:material,obstacleID:hit.obstacleID,radius:radius,seed:unit()*97))
    }

    private func waterSplash(at point:SIMD3<Float>,strength:Float,highQuality:Bool) {
        for _ in 0..<(highQuality ? 6:3) {
            let angle=unit()*Float.pi*2,speed:Float=0.35+strength*0.75
            add(Particle(position:point+SIMD3(0,0.008,0),
                velocity:SIMD3(cos(angle)*speed,(0.6+unit()*1.3)*strength,sin(angle)*speed),
                color:SIMD3(0.53,0.65,0.62),lifetime:0.18+strength*0.30,
                radius:0.016+unit()*0.014,rotation:unit()*6.28,aspect:0.38,opacity:0.55,gravity:5,kind:5))
        }
    }

    private func explosion(at center:SIMD3<Float>,highQuality:Bool) {
        add(Particle(position:center,velocity:.zero,color:SIMD3(1,0.82,0.42),lifetime:0.10,radius:0.72,rotation:0,aspect:1,opacity:1,gravity:0,kind:4))
        add(Particle(position:center,velocity:SIMD3(0,0.8,0),color:SIMD3(1,0.31,0.05),lifetime:0.19,radius:1.25,rotation:unit()*6.28,aspect:1,opacity:0.85,gravity:0,kind:4))
        let count=highQuality ? 42:22
        for index in 0..<count {
            let sparkEnd=highQuality ? 8:4,chipEnd=highQuality ? 14:7
            let spark=index<sparkEnd,chip=index>=sparkEnd && index<chipEnd,smoke=index>=count-(highQuality ? 10:6)
            let kind=spark ? 2:chip ? 3:smoke ? 0:1
            var direction=vector();direction.y=abs(direction.y)*0.8+0.12
            let speed:Float=spark ? 5+unit()*9:chip ? 3+unit()*6:smoke ? 0.3+unit()*0.6:1+unit()*2.6
            let tint:SIMD3<Float>=spark ? SIMD3(1,0.47,0.07):smoke ? SIMD3(0.17,0.165,0.15):SIMD3(0.34,0.29,0.21)
            add(Particle(position:center+vector()*0.20,velocity:direction*speed,color:tint,
                lifetime:spark ? 0.2+unit()*0.25:chip ? 1.0+unit()*0.8:smoke ? 2.5+unit()*1.5:1.2+unit()*0.9,
                radius:spark ? 0.1:chip ? 0.025+unit()*0.05:smoke ? 0.60+unit()*0.45:0.30+unit()*0.35,
                rotation:unit()*6.28,aspect:spark ? 0.035:chip ? 0.30:1,opacity:spark ? 1:chip ? 0.95:smoke ? 0.28:0.38,gravity:spark || chip ? 9:0,kind:kind))
        }
    }

    func step(deltaTime:Float,simulation:CombatSimulation) {
        let dt=min(0.1,max(0,deltaTime));guard dt>0 else { return }
        syncSupports(simulation)
        let supports=simulation.obstacles+simulation.map.groundedSupportSurfaces
        for i in particles.indices {
            let previous=particles[i].position
            particles[i].age+=dt;particles[i].velocity.y-=particles[i].gravity*dt
            particles[i].position+=particles[i].velocity*dt
            if particles[i].kind<=1 {
                particles[i].velocity *= exp(-dt*1.2)
                particles[i].velocity.y+=dt*(particles[i].kind==0 ? 0.32:0.06)
                particles[i].rotation+=dt*0.12
            } else if particles[i].gravity>0 {
                let p=particles[i].position
                var floor=simulation.terrain.height(x:p.x,z:p.z)
                for box in supports where !box.destroyed {
                    let top=box.position.y+box.size.y
                    if abs(p.x-box.position.x)<=box.size.x*0.5 && abs(p.z-box.position.z)<=box.size.z*0.5 && top<=previous.y+0.025 { floor=max(floor,top) }
                }
                if p.y<floor+0.01 { particles[i].position.y=floor+0.01;particles[i].velocity.y=abs(particles[i].velocity.y)*0.16;particles[i].velocity.x *= 0.58;particles[i].velocity.z *= 0.58 }
            }
        }
        particles.removeAll { $0.age >= $0.lifetime }
        for i in decals.indices { decals[i].age+=dt }
        decals.removeAll { $0.age>=12 }
    }

    /// Called only after the parent's inflight semaphore grants this slot.
    func prepare(slot:Int,eye:SIMD3<Float>,forward:SIMD3<Float>,terrain:TerrainProfile,obstacles:[Obstacle]) {
        guard (0..<3).contains(slot) else { return }
        let right=simd_normalize(simd_cross(forward,abs(forward.y)<0.98 ? SIMD3<Float>(0,1,0):SIMD3<Float>(0,0,1)))
        let up=simd_normalize(simd_cross(right,forward))
        // Parallel billboards blend by camera depth, not radial eye distance.
        let alpha=particles.filter { $0.kind != 2 && $0.kind != 4 }.sorted { simd_dot($0.position-eye,forward)>simd_dot($1.position-eye,forward) }
        let additive=particles.filter { $0.kind==2 || $0.kind==4 }.sorted { simd_dot($0.position-eye,forward)>simd_dot($1.position-eye,forward) }
        alphaDepths[slot]=alpha.map { simd_dot($0.position-eye,forward) };additiveDepths[slot]=additive.map { simd_dot($0.position-eye,forward) }
        let target=particleBuffers[slot].contents().bindMemory(to:ParticleGPU.self,capacity:256)
        for (index,p) in (alpha+additive).enumerated() {
            let age=min(1,p.age/p.lifetime),fade=pow(1-age,p.kind<=1 ? 0.8:1.3)
            let growth:Float=p.kind<=1 ? 0.45+age*1.7:p.kind==4 ? 0.7+age*1.8:1
            let rotation=p.kind==2 ? atan2(-simd_dot(p.velocity,right),simd_dot(p.velocity,up)):p.rotation
            let opacity=p.opacity*fade*(p.kind==0 ? min(1,age*10):1)
            target[index]=ParticleGPU(positionAge:SIMD4(p.position,age),shape:SIMD4(p.radius*growth,rotation,Float(p.kind),opacity),tintAspect:SIMD4(p.color,p.aspect),supportPlane:Self.supportPlane(at:p.position,terrain:terrain,obstacles:obstacles))
        }
        let markTarget=decalBuffers[slot].contents().bindMemory(to:DecalGPU.self,capacity:80)
        for (index,d) in decals.enumerated() {
            let point=d.position+(d.obstacleID.flatMap { obstaclePositions[$0] } ?? .zero),fade=min(1,max(0,(12-d.age)/2))
            let kind:Float,tint:SIMD3<Float>
            switch d.material {
            case .soil:kind=0;tint=SIMD3(0.16,0.12,0.075)
            case .concrete:kind=1;tint=SIMD3(0.46,0.44,0.39)
            case .metal:kind=2;tint=SIMD3(0.37,0.39,0.39)
            case .wood:kind=3;tint=SIMD3(0.39,0.25,0.105)
            case .asphalt:kind=4;tint=SIMD3(0.16,0.17,0.17)
            case .glass:kind=5;tint=SIMD3(0.60,0.70,0.66)
            }
            markTarget[index]=DecalGPU(positionOpacity:SIMD4(point,fade),axisU:SIMD4(d.tangent*d.radius,d.seed),axisV:SIMD4(simd_cross(d.normal,d.tangent)*d.radius,0),tintKind:SIMD4(tint,kind))
        }
        alphaCounts[slot]=alpha.count;additiveCounts[slot]=additive.count;decalCounts[slot]=decals.count
        drawCallCount=(alpha.isEmpty ? 0:1)+(additive.isEmpty ? 0:1)+(decals.isEmpty ? 0:1)
    }

    /// The actual receiving triangle/top determines soft particle intersections,
    /// including elevated roofs. Shallow asphalt/curb colliders come from the
    /// parent renderer alongside authoritative gameplay cover.
    nonisolated static func supportPlane(at point:SIMD3<Float>,terrain:TerrainProfile,obstacles:[Obstacle])->SIMD4<Float> {
        var height=terrain.height(x:point.x,z:point.z),normal=terrain.normal(x:point.x,z:point.z)
        for box in obstacles where !box.destroyed {
            let x=point.x-box.position.x,z=point.z-box.position.z,top=box.position.y+box.size.y
            guard abs(x)<=box.size.x*0.5,abs(z)<=box.size.z*0.5,top<=point.y+0.05,top>height else { continue }
            if box.kind == .barrel {
                let radial=SIMD2(x/(box.size.x*0.5),z/(box.size.z*0.5))
                if simd_length_squared(radial)>1 { continue }
            }
            height=top;normal=SIMD3(0,1,0)
        }
        return SIMD4(normal,-simd_dot(normal,SIMD3(point.x,height,point.z)))
    }

    /// Project only outward from the authoritative hit onto visible geometry of
    /// its owner. Equal-depth faces prefer the larger safe area. The 0.68 factor
    /// keeps even a rotated square within that face (below 1/sqrt(2)). A returned
    /// tiny radius is deliberately omitted by the caller rather than overhanging.
    nonisolated static func projectSurface(at point:SIMD3<Float>,normal:SIMD3<Float>,radius:Float,boxes:[CombatSurfaceBox])->CombatSurfaceProjection? {
        guard point.x.isFinite,point.y.isFinite,point.z.isFinite,
              normal.x.isFinite,normal.y.isFinite,normal.z.isFinite,radius.isFinite,radius>0 else { return nil }
        let n=simd_abs(normal),axis=n.x>n.y && n.x>n.z ? 0:n.y>n.z ? 1:2
        guard n[axis]>0.999 else { return nil }
        let u=(axis+1)%3,v=(axis+2)%3,sign:Float=normal[axis]>0 ? 1:-1
        var bestDistance:Float = -.infinity,bestMargin:Float = 0,bestPoint=point
        for box in boxes {
            guard point[u]>=box.minimum[u],point[u]<=box.maximum[u],
                  point[v]>=box.minimum[v],point[v]<=box.maximum[v] else { continue }
            let face=sign>0 ? box.maximum[axis]:box.minimum[axis]
            let distance=(face-point[axis])*sign
            guard distance >= -0.0001 else { continue }
            let margin=min(point[u]-box.minimum[u],box.maximum[u]-point[u],point[v]-box.minimum[v],box.maximum[v]-point[v])
            if distance>bestDistance+0.00001 || (abs(distance-bestDistance)<=0.00001 && margin>bestMargin) {
                bestDistance=distance;bestMargin=margin;bestPoint[axis]=face
            }
        }
        guard bestDistance.isFinite else { return nil }
        return CombatSurfaceProjection(position:bestPoint,radius:min(radius,max(0,bestMargin*0.68)))
    }

    func encode(encoder:MTLRenderCommandEncoder,samples:Int,slot:Int,farShadow:MTLTexture,nearShadow:MTLTexture,shadowSampler:MTLSamplerState,
                transparentDepths:[Float]=[],includeDecals:Bool=true,resetDrawCount:Bool=true,drawSurface:((Int)->Void)?=nil) {
        guard (0..<3).contains(slot) else { return }
        encoder.pushDebugGroup("Depth-ordered glass, impacts and bounded transparent blasts")
        encoder.setDepthStencilState(depth);encoder.setCullMode(.none)
        if resetDrawCount { drawCallCount=0 }
        if includeDecals,decalCounts[slot]>0,let pipeline=decalPipelines[samples] {
            encoder.setRenderPipelineState(pipeline);encoder.setVertexBuffer(decalBuffers[slot],offset:0,index:0)
            encoder.setFragmentTexture(farShadow,index:0);encoder.setFragmentTexture(nearShadow,index:1);encoder.setFragmentSamplerState(shadowSampler,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:decalCounts[slot]);drawCallCount+=1
        }
        let alphaRanges=NativeTransparencyOrder.ranges(sortedDepths:alphaDepths[slot],surfaces:transparentDepths)
        let additiveRanges=NativeTransparencyOrder.ranges(sortedDepths:additiveDepths[slot],surfaces:transparentDepths)
        for segment in alphaRanges.indices {
            encoder.setDepthStencilState(depth);encoder.setCullMode(.none)
            let alpha=alphaRanges[segment],additive=additiveRanges[segment]
            if !alpha.isEmpty,let pipeline=alphaPipelines[samples] {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(particleBuffers[slot],offset:alpha.lowerBound*MemoryLayout<ParticleGPU>.stride,index:0)
                encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:alpha.count);drawCallCount+=1
            }
            if !additive.isEmpty,let pipeline=additivePipelines[samples] {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(particleBuffers[slot],offset:(alphaCounts[slot]+additive.lowerBound)*MemoryLayout<ParticleGPU>.stride,index:0)
                encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:additive.count);drawCallCount+=1
            }
            if segment<transparentDepths.count { drawSurface?(segment) }
        }
        encoder.popDebugGroup()
    }
}
