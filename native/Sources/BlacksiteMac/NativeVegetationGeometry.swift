import simd
import BlacksiteCore

/// Static gameplay foliage: the same geometry, density and heights in every
/// graphics profile. Only distant decorative scenery has independent LODs.
enum NativeVegetationGeometry {
    struct ZoneMesh {
        let id: String
        let kind: VegetationKind
        let vertices: [GPUVertex]
        let plantCount: Int
    }
    static let maximumZones = 16
    static let maximumPlants = EnvironmentZone.maximumTotalPlantCount
    static let maximumPlantsPerZone = EnvironmentZone.maximumPlantCount
    static let maximumVertices = maximumPlants * 648
    static let windMargin: Float = 0.024

    private struct Random {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 2862933555777941757 &+ 3037000493
            return Float((state >> 32) & 0xffffff) / Float(0xffffff)
        }
    }
    private static func seed(_ name: String) -> UInt64 {
        name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    /// The original photographic twig island, also used by the distant trees.
    static func photographicTwigVertices() -> [GPUVertex] {
        let outline:[SIMD2<Float>] = [SIMD2(30,100),SIMD2(850,100),SIMD2(990,500),SIMD2(920,1300),SIMD2(855,1540),SIMD2(650,1810),SIMD2(390,1825),SIMD2(360,1800),SIMD2(250,1740),SIMD2(190,1680),SIMD2(155,1500),SIMD2(119,1310),SIMD2(30,1000)]
        func vertex(_ pixel: SIMD2<Float>) -> GPUVertex {
            let t=(1810-pixel.y)/1625, x=(pixel.x-550)/1625
            return GPUVertex(position:SIMD3(x,t,sin(t * .pi)*0.055+x*x*0.16),
                normal:simd_normalize(SIMD3(-x*0.25,-cos(t * .pi)*0.1,1)),uv:pixel/SIMD2(1024,2048))
        }
        return outline.indices.flatMap { [vertex(SIMD2(540,950)),vertex(outline[$0]),vertex(outline[($0+1)%outline.count])] }
    }

    private static let brush: [GPUVertex] = {
        let twig=photographicTwigVertices()
        var vertices:[GPUVertex]=[]
        for branch in 0..<8 {
            let angle=Float(branch)*2.3999632
            let rotation=simd_quatf(angle:angle,axis:SIMD3(0,1,0))
                * simd_quatf(angle:branch<4 ? 0.55:0.23,axis:SIMD3(1,0,0))
            let height:Float=branch<4 ? 0.85:0.68
            let root=SIMD3<Float>(sin(angle)*0.10,branch<4 ? 0.015:0.29,cos(angle)*0.10)
            for vertex in twig {
                vertices.append(GPUVertex(position:root+rotation.act(vertex.position*height),
                    normal:rotation.act(vertex.normal),uv:vertex.uv))
            }
        }
        let minY=vertices.map(\.position.y).min()!,maxY=vertices.map(\.position.y).max()!
        let radius=vertices.map { simd_length(SIMD2($0.position.x,$0.position.z)) }.max()!
        return vertices.map { vertex in
            GPUVertex(position:SIMD3(vertex.position.x/radius,(vertex.position.y-minY)/(maxY-minY),vertex.position.z/radius),
                normal:simd_normalize(vertex.normal*SIMD3(radius,maxY-minY,radius)),uv:vertex.uv)
        }
    }()

    private static let grass: [GPUVertex] = {
        let corners:[SIMD2<Float>]=[SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,0),SIMD2(1,1),SIMD2(0,1)]
        var vertices:[GPUVertex]=[]
        for blade in 0..<36 {
            let angle=Float(blade)*2.3999632
            let radial=SIMD3<Float>(cos(angle),0,sin(angle)),side=SIMD3<Float>(-sin(angle),0,cos(angle))
            let spread:Float=0.13+sqrt(Float((blade*17)%36)/35)*0.54
            let height:Float=0.68+Float((blade*11)%13)/12*0.32
            func vertex(_ across:Float,_ t:Float)->GPUVertex {
                let width:Float=(0.020+Float(blade%4)*0.005)*pow(1-t,0.65)
                let bend=t*t*(0.15+Float(blade%3)*0.035)
                let p=radial*(spread+bend)+side*((across-0.5)*width*2)+SIMD3(0,t*height,0)
                let n=simd_normalize(radial+SIMD3(0,0.12+t*0.38,0))
                return GPUVertex(position:p,normal:n,uv:SIMD2(across,t))
            }
            for segment in 0..<3 { for corner in corners {
                vertices.append(vertex(corner.x,(Float(segment)+corner.y)/3))
            } }
        }
        return vertices
    }()

    static func meshes(map: MapDefinition) -> [ZoneMesh] {
        let zones=map.environment.vegetationZones
        guard !zones.isEmpty else { return [] }
        return zones.map { zone in
            let perZone=zone.requiredPlantCount
            let center=(zone.minimum+zone.maximum)*0.5
            let radii=SIMD2<Float>((zone.maximum.x-zone.minimum.x)*0.5,(zone.maximum.z-zone.minimum.z)*0.5)
            let columns=max(2,Int(ceil(sqrt(Float(perZone)*radii.x/radii.y*4 / .pi))))
            let rows=max(2,Int(ceil(Float(perZone)*4 / (.pi*Float(columns)))))
            let step=SIMD2(radii.x*2/Float(columns),radii.y*2/Float(rows))
            var candidates:[(SIMD2<Float>,Float)]=[]
            var rng=Random(state:seed(zone.id))
            for row in 0..<rows { for column in 0..<columns {
                let jitter=SIMD2<Float>((rng.next()-0.5)*0.24,(rng.next()-0.5)*0.24)
                let p=SIMD2(zone.minimum.x,zone.minimum.z)+(SIMD2(Float(column)+0.5,Float(row)+0.5)+jitter)*step
                let normalized=simd_abs((p-SIMD2(center.x,center.z))/radii)
                let distance=zone.elliptical ? simd_length(normalized):max(normalized.x,normalized.y)
                if distance<0.97 { candidates.append((p,distance)) }
            } }
            // Uniform low-discrepancy cells, with a hard shared load-time cap.
            // No quality-dependent dropping and no per-frame random changes.
            if candidates.count>perZone {
                candidates.sort { $0.1<$1.1 }
                candidates=Array(candidates.prefix(perZone))
            }
            // Border cells can be too narrow for an actual plant plus its wind
            // margin. Keep the established grid, then fill only those missing
            // cells from a deterministic interior sequence. Every valid zone
            // receives its exact authored area-based count, independently of
            // how many other zones the map contains.
            candidates.removeAll { min(radii.x,radii.y)*(1-$0.1)-windMargin <= 0.035 }
            let phase=Float(seed(zone.id)&0xffff)/65535*2 * Float.pi
            var candidateIndex=0
            while candidates.count<perZone {
                let t=(Float(candidateIndex)+0.5)/Float(perZone)
                let distance:Float=0.72*sqrt(t)
                let angle=phase+Float(candidateIndex)*2.3999632
                let normalized=SIMD2<Float>(cos(angle),sin(angle))*distance
                let point=SIMD2(center.x,center.z)+normalized*radii
                let metric=zone.elliptical ? distance:max(abs(normalized.x),abs(normalized.y))
                candidates.append((point,metric))
                candidateIndex+=1
            }
            let template=zone.kind == .brush ? brush:grass
            var vertices:[GPUVertex]=[]
            vertices.reserveCapacity(candidates.count*template.count)
            for (point,distance) in candidates {
                let edge=zone.footprintWeight(x:point.x,z:point.y)
                let available=max(0,min(radii.x,radii.y)*(1-distance)-windMargin)
                let radius=min(available,min(step.x,step.y)*(0.66+zone.density*0.20))
                guard radius>0.035,edge>0 else { continue }
                let rotation=simd_quatf(angle:rng.next()*2 * .pi,axis:SIMD3(0,1,0))
                let heightVariation:Float=0.94+rng.next()*0.06
                for vertex in template {
                    let rotated=rotation.act(vertex.position*SIMD3(radius,1,radius))
                    let x=point.x+rotated.x,z=point.y+rotated.z
                    let bottom=zone.bottomHeight(x:x,z:z,terrain:map.terrain),top=zone.topHeight(x:x,z:z,terrain:map.terrain)
                    // Every root and the upper contour follow the same heightfield
                    // as perception. A clump cannot float on a sloping triangle.
                    let y=bottom+vertex.position.y*(top-bottom)*heightVariation
                    let ground=zone.terrainRelative ? map.terrain.normal(x:x,z:z):SIMD3<Float>(0,1,0)
                    let normal=rotation.act(vertex.normal*SIMD3(1/max(radius,0.001),1/max((top-bottom)*heightVariation,0.001),1/max(radius,0.001)))
                    let warped=SIMD3(normal.x+normal.y*ground.x/ground.y,normal.y,normal.z+normal.y*ground.z/ground.y)
                    vertices.append(GPUVertex(position:SIMD3(x,y,z),normal:simd_normalize(warped),uv:vertex.uv))
                }
            }
            return ZoneMesh(id:zone.id,kind:zone.kind,vertices:vertices,plantCount:vertices.count/template.count)
        }
    }
}
