import Foundation
import simd
import BlacksiteCore

/// Matches the Metal vertex layout: 0/16/32/40/48, stride 64.
struct SoldierVertex: Hashable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
    var joints: SIMD4<UInt16>
    var weights: SIMD4<Float>
}
struct SoldierMaterial {
    let name: String
    let baseColorData: Data
    let normalData: Data?
}
struct SoldierPrimitive {
    var vertices: [SoldierVertex]
    var indices: [UInt32]
    var material: Int
}
/// Four original mesh samples, named in the normalized +Z-forward bind pose.
/// Fixed fields keep the per-frame contact query free of array allocations.
struct SoldierSolePoints {
    let heelLeft: SIMD3<Float>
    let heelRight: SIMD3<Float>
    let toeLeft: SIMD3<Float>
    let toeRight: SIMD3<Float>
}

enum SoldierAssetError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String { if case let .malformed(message) = self { return "Soldier asset: \(message)" }; return "Soldier asset" }
}

/// glTF skinning remains in the original mesh coordinates. The returned palette
/// already includes the scene hierarchy, model normalization and world placement.
/// Distinct skins keep distinct inverse binds, even when they share joint nodes.
final class SoldierAsset {
    let primitives: [SoldierPrimitive]
    let materials: [SoldierMaterial]
    let paletteCount: Int
    let animationNames: [String]
    private let nodes: [AssetNode]
    private let order: [Int]
    private let descendants: [[Int]]
    private let entries: [PaletteEntry]
    private let clips: [String: AssetClip]
    private let rig: Rig
    private let normalization: simd_float4x4
    private let bindWorld: [simd_float4x4]
    private let bindLocal: [AssetTRS]
    private let headOffset: Float
    private let footMinima: [String: SIMD2<Float>]
    private struct SoleVertices {
        let heelLeft: SoldierVertex
        let heelRight: SoldierVertex
        let toeLeft: SoldierVertex
        let toeRight: SoldierVertex
        func deformed(by palette: [simd_float4x4]) -> SoldierSolePoints {
            SoldierSolePoints(heelLeft: SoldierAsset.skin(heelLeft, palette: palette),
                              heelRight: SoldierAsset.skin(heelRight, palette: palette),
                              toeLeft: SoldierAsset.skin(toeLeft, palette: palette),
                              toeRight: SoldierAsset.skin(toeRight, palette: palette))
        }
    }
    private let soles: (left: SoleVertices, right: SoleVertices)
    private struct PoseBlend { var clip:String;var start:Double;var lastTime:Double;var from:[AssetTRS];var current:[AssetTRS];var fromActivity:Float;var activity:Float;var fromMinimum:SIMD2<Float>;var minimum:SIMD2<Float> }
    private var blends: [Int:PoseBlend] = [:]

    init(url: URL) throws {
        let source = try GLTFSource(url: url)
        let document = source.document
        let groupURL=url.deletingLastPathComponent().appendingPathComponent("head-materials.json")
        let groups:HeadTriangleMaterials? = FileManager.default.fileExists(atPath:groupURL.path) ? try JSONDecoder().decode(HeadTriangleMaterials.self,from:Data(contentsOf:groupURL)) : nil
        if let groups {
            guard groups.version==1,groups.triangleMaterials.allSatisfy({ document.materials.indices.contains($0) }) else { throw SoldierAssetError.malformed("invalid supplemental material groups") }
        }
        guard !document.nodes.isEmpty, !document.skins.isEmpty else { throw SoldierAssetError.malformed("missing skinned hierarchy") }
        var parents = Array(repeating: -1, count: document.nodes.count)
        for (index,node) in document.nodes.enumerated() {
            for child in node.children ?? [] {
                guard child >= 0, child < parents.count, child != index, parents[child] == -1 else { throw SoldierAssetError.malformed("invalid node parent") }
                parents[child] = index
            }
        }
        var ordered: [Int] = [], visiting = Set<Int>(), visited = Set<Int>()
        func visit(_ node: Int) throws {
            guard !visiting.contains(node) else { throw SoldierAssetError.malformed("cyclic hierarchy") }
            if visited.contains(node) { return }
            visiting.insert(node)
            if parents[node] >= 0 { try visit(parents[node]) }
            visiting.remove(node); visited.insert(node); ordered.append(node)
        }
        for i in document.nodes.indices { try visit(i) }
        let parsedNodes = try document.nodes.enumerated().map { index, value in
            AssetNode(name: value.name ?? "node\(index)", parent: parents[index], rest: try AssetTRS(value))
        }
        var below = [[Int]](repeating: [], count: parsedNodes.count)
        for i in parsedNodes.indices {
            var parent = i
            while parent >= 0 { below[parent].append(i); parent = parents[parent] }
        }
        var palette: [PaletteEntry] = [], offsets: [Int] = []
        for skin in document.skins {
            offsets.append(palette.count)
            let matrices = try skin.inverseBindMatrices.map { try source.floats($0, components: 16) }
            guard matrices == nil || matrices!.count == skin.joints.count * 16 else { throw SoldierAssetError.malformed("inverse-bind count mismatch") }
            for (i,node) in skin.joints.enumerated() {
                guard parsedNodes.indices.contains(node) else { throw SoldierAssetError.malformed("joint outside hierarchy") }
                let inverse = matrices.map { Self.matrix($0, i * 16) } ?? matrix_identity_float4x4
                guard Self.finite(inverse) else { throw SoldierAssetError.malformed("nonfinite inverse bind") }
                palette.append(PaletteEntry(node: node, inverseBind: inverse))
            }
        }
        guard !palette.isEmpty, palette.count <= Int(UInt16.max) else { throw SoldierAssetError.malformed("invalid palette size") }
        var geometry: [SoldierPrimitive] = []
        for node in document.nodes {
            guard let meshIndex = node.mesh else { continue }
            guard document.meshes.indices.contains(meshIndex), let skinIndex = node.skin, document.skins.indices.contains(skinIndex) else { throw SoldierAssetError.malformed("mesh has no valid skin") }
            for primitive in document.meshes[meshIndex].primitives {
                // This exporter duplicated the complete head once per material,
                // losing the FBX face groups. The verified sidecar restores those
                // exact triangle assignments without changing geometry or UVs.
                let duplicate=document.meshes[meshIndex].primitives.contains { other in
                    other.attributes==primitive.attributes && other.indices==primitive.indices && other.material != primitive.material
                }
                let faceGroups:[Int]?
                if duplicate {
                    guard let groups,groups.positionAccessor==primitive.attributes["POSITION"] else { throw SoldierAssetError.malformed("missing source material groups for duplicated mesh") }
                    faceGroups=groups.triangleMaterials
                } else { faceGroups=nil }
                guard primitive.mode ?? 4 == 4, let p = primitive.attributes["POSITION"], let n = primitive.attributes["NORMAL"],
                      let t = primitive.attributes["TEXCOORD_0"], let j = primitive.attributes["JOINTS_0"], let w = primitive.attributes["WEIGHTS_0"] else { throw SoldierAssetError.malformed("incomplete triangle primitive") }
                let positions = try source.floats(p, components: 3), normals = try source.floats(n, components: 3)
                let uvs = try source.floats(t, components: 2), joints = try source.unsigned(j, components: 4), weights = try source.floats(w, components: 4)
                let count = positions.count / 3
                guard normals.count == count * 3, uvs.count == count * 2, joints.count == count * 4, weights.count == count * 4 else { throw SoldierAssetError.malformed("vertex accessor count mismatch") }
                var vertices: [SoldierVertex] = []; vertices.reserveCapacity(count)
                for i in 0..<count {
                    var skinJoints = SIMD4<UInt16>(), skinWeights = SIMD4<Float>()
                    for k in 0..<4 {
                        let value = Int(joints[i * 4 + k])
                        guard value < document.skins[skinIndex].joints.count else { throw SoldierAssetError.malformed("vertex joint outside skin") }
                        skinJoints[k] = UInt16(offsets[skinIndex] + value); skinWeights[k] = max(0, weights[i * 4 + k])
                    }
                    let sum = skinWeights.x + skinWeights.y + skinWeights.z + skinWeights.w
                    guard sum > 0, sum.isFinite else { throw SoldierAssetError.malformed("invalid skin weights") }
                    let normal = SIMD3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2])
                    guard simd_length_squared(normal) > 0.000001, simd_length_squared(normal).isFinite else { throw SoldierAssetError.malformed("zero vertex normal") }
                    vertices.append(SoldierVertex(position: SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]), normal: simd_normalize(normal),
                                                  uv: SIMD2(uvs[i * 2], uvs[i * 2 + 1]), joints: skinJoints, weights: skinWeights / sum))
                }
                var indices = try primitive.indices.map { try source.unsigned($0, components: 1) } ?? (0..<count).map(UInt32.init)
                guard indices.count.isMultiple(of: 3), indices.allSatisfy({ Int($0) < count }) else { throw SoldierAssetError.malformed("invalid triangle indices") }
                if let faceGroups {
                    guard faceGroups.count==indices.count/3 else { throw SoldierAssetError.malformed("supplemental material group count mismatch") }
                    var selected:[UInt32]=[];selected.reserveCapacity(indices.count)
                    for triangle in faceGroups.indices where faceGroups[triangle]==primitive.material {
                        selected.append(contentsOf:indices[(triangle*3)..<(triangle*3+3)])
                    }
                    indices=selected
                    if indices.isEmpty { continue }
                }
                // Reuse only referenced vertices, preserving UV seams, hard
                // normals and skin weights exactly across material boundaries.
                var unique:[SoldierVertex]=[],lookup:[SoldierVertex:UInt32]=[:],remapped:[UInt32]=[]
                unique.reserveCapacity(vertices.count);lookup.reserveCapacity(vertices.count);remapped.reserveCapacity(indices.count)
                for original in indices {
                    let vertex=vertices[Int(original)]
                    if let existing=lookup[vertex] { remapped.append(existing) }
                    else { let index=UInt32(unique.count);unique.append(vertex);lookup[vertex]=index;remapped.append(index) }
                }
                geometry.append(SoldierPrimitive(vertices:unique,indices:remapped,material:primitive.material ?? 1))
            }
        }
        guard !geometry.isEmpty else { throw SoldierAssetError.malformed("empty geometry") }
        var animations: [String: AssetClip] = [:]
        for animation in document.animations ?? [] {
            var tracks: [AssetTrack] = [], duration: Float = 0
            for channel in animation.channels {
                guard let target = channel.target.node, parsedNodes.indices.contains(target), animation.samplers.indices.contains(channel.sampler) else { throw SoldierAssetError.malformed("invalid animation target") }
                guard ["translation", "rotation", "scale"].contains(channel.target.path) else { continue }
                let sampler = animation.samplers[channel.sampler]
                guard sampler.interpolation == nil || ["LINEAR", "STEP"].contains(sampler.interpolation!) else { throw SoldierAssetError.malformed("unsupported animation interpolation") }
                let times = try source.floats(sampler.input, components: 1)
                let width = channel.target.path == "rotation" ? 4 : 3
                let values = try source.floats(sampler.output, components: width)
                guard !times.isEmpty, values.count == times.count * width, times.first! >= 0,
                      zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else { throw SoldierAssetError.malformed("invalid animation timeline") }
                if channel.target.path == "rotation" {
                    for i in stride(from:0,to:values.count,by:4) {
                        let q=SIMD4(values[i],values[i+1],values[i+2],values[i+3]),length=simd_length_squared(q)
                        guard length>0.000001,length.isFinite else { throw SoldierAssetError.malformed("invalid animated quaternion") }
                    }
                }
                duration = max(duration, times.last!)
                tracks.append(AssetTrack(node: target, path: channel.target.path, times: times, values: values, width: width, step: sampler.interpolation == "STEP"))
            }
            animations[(animation.name ?? "clip").lowercased()] = AssetClip(duration: duration, tracks: tracks)
        }
        if animations["walk"] == nil { animations["walk"] = animations["walking"] }
        if animations["run"] == nil { animations["run"] = animations["running"] }
        let skeleton = try Rig(nodes: parsedNodes)
        let rest = parsedNodes.map(\.rest)
        let global = Self.globals(rest, nodes: parsedNodes, order: ordered)
        // Authored node TRS may already contain an animation pose. Recover the
        // actual bind skeleton from each mesh's world transform and inverse bind.
        var bindGlobals=global,known=Set<Int>()
        for node in document.nodes.indices {
            guard let skin=document.nodes[node].skin else { continue }
            guard document.skins.indices.contains(skin) else { throw SoldierAssetError.malformed("node skin out of range") }
            for index in document.skins[skin].joints.indices {
                let entry=palette[offsets[skin]+index]
                guard abs(simd_determinant(entry.inverseBind))>1e-12 else { throw SoldierAssetError.malformed("singular inverse bind") }
                bindGlobals[entry.node]=global[node]*entry.inverseBind.inverse;known.insert(entry.node)
            }
        }
        for node in ordered where !known.contains(node) && parents[node]>=0 { bindGlobals[node]=bindGlobals[parents[node]]*rest[node].matrix }
        let bindingLocal=ordered.reduce(into:rest) { result,node in
            result[node]=AssetTRS(matrix:parents[node]<0 ? bindGlobals[node]:bindGlobals[parents[node]].inverse*bindGlobals[node])
        }
        var minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
        let bindPalette = palette.map { bindGlobals[$0.node] * $0.inverseBind }
        for primitive in geometry { for vertex in primitive.vertices {
            let point = Self.skin(vertex, palette: bindPalette)
            minimum = simd_min(minimum, point); maximum = simd_max(maximum, point)
        } }
        let height = maximum.y - minimum.y
        guard height.isFinite, height > 0.01 else { throw SoldierAssetError.malformed("invalid bind-pose bounds") }
        let forward = Self.position(bindGlobals[skeleton.left.toe]) - Self.position(bindGlobals[skeleton.left.foot]) + Self.position(bindGlobals[skeleton.right.toe]) - Self.position(bindGlobals[skeleton.right.foot])
        let heading = -atan2(forward.x, forward.z)
        let scale = 1.9 / height
        let normalize = Self.rotationY(heading) * Self.scaling(SIMD3(repeating: scale)) * Self.translation(SIMD3(-(minimum.x + maximum.x) * 0.5, -minimum.y, -(minimum.z + maximum.z) * 0.5))
        let normalizedRest = bindGlobals.map { normalize * $0 }
        func soleVertices(_ chain: Rig.Side) throws -> SoleVertices {
            var candidates: [(vertex: SoldierVertex, point: SIMD3<Float>)] = []
            for primitive in geometry { for vertex in primitive.vertices {
                var weight: Float = 0
                for k in 0..<4 {
                    let node = palette[Int(vertex.joints[k])].node
                    if node == chain.foot || node == chain.toe { weight += vertex.weights[k] }
                }
                if weight > 0.5 { candidates.append((vertex, Self.point(normalize, Self.skin(vertex, palette: bindPalette)))) }
            } }
            guard let bottom = candidates.map({ $0.point.y }).min() else { throw SoldierAssetError.malformed("missing sole vertices") }
            // Select actual sole geometry, excluding the ankle and raised toe cap.
            candidates.removeAll { $0.point.y > bottom + 0.008 }
            guard candidates.count >= 4 else { throw SoldierAssetError.malformed("incomplete sole geometry") }
            let lo = candidates.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1.point) }
            let hi = candidates.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1.point) }
            func corner(_ x: Float, _ z: Float) -> SoldierVertex {
                let target = SIMD2(x, z)
                return candidates.min {
                    simd_length_squared(SIMD2($0.point.x, $0.point.z) - target) < simd_length_squared(SIMD2($1.point.x, $1.point.z) - target)
                }!.vertex
            }
            return SoleVertices(heelLeft: corner(lo.x, lo.z), heelRight: corner(hi.x, lo.z),
                                toeLeft: corner(lo.x, hi.z), toeRight: corner(hi.x, hi.z))
        }
        let soleSamples = try (left: soleVertices(skeleton.left), right: soleVertices(skeleton.right))
        var headLow: Float = .infinity, headHigh: Float = -.infinity
        for primitive in geometry { for vertex in primitive.vertices {
            var headWeight: Float = 0
            for k in 0..<4 where palette[Int(vertex.joints[k])].node == skeleton.head { headWeight += vertex.weights[k] }
            if headWeight > 0.5 {
                let y = Self.point(normalize, Self.skin(vertex, palette: bindPalette)).y
                headLow = min(headLow, y); headHigh = max(headHigh, y)
            }
        } }
        let centerOffset = headLow.isFinite ? (headLow + headHigh) * 0.5 - Self.position(normalizedRest[skeleton.head]).y : 0.1
        var minima: [String: SIMD2<Float>] = [:]
        for (name,clip) in animations {
            var floor = SIMD2<Float>(repeating: .infinity)
            for i in 0..<60 {
                let sample = Self.sample(clip, at: Float(i) / 60 * clip.duration, rest: rest)
                let pose = Self.globals(sample, nodes: parsedNodes, order: ordered)
                floor.x = min(floor.x, Self.position(normalize * pose[skeleton.left.foot]).y)
                floor.y = min(floor.y, Self.position(normalize * pose[skeleton.right.foot]).y)
            }
            minima[name] = floor
        }
        materials = try document.materials.enumerated().map { index,material in
            guard let diffuse=material.pbrMetallicRoughness?.baseColorTexture?.index else { throw SoldierAssetError.malformed("missing material texture") }
            return SoldierMaterial(name:material.name ?? "material\(index)",baseColorData:try source.texture(diffuse),normalData:try material.normalTexture.map { try source.texture($0.index) })
        }
        primitives = geometry; paletteCount = palette.count; entries = palette
        nodes = parsedNodes; order = ordered; descendants = below; clips = animations; animationNames = animations.keys.sorted()
        rig = skeleton; normalization = normalize; bindWorld = normalizedRest; bindLocal = bindingLocal; headOffset = centerOffset; footMinima = minima
        soles = soleSamples
    }

    func palette(enemy: EnemyState, time: Double, terrain: TerrainProfile) -> [simd_float4x4] {
        let pose = posedJoints(enemy: enemy, time: time, terrain: terrain)
        return entries.map { pose[$0.node] * $0.inverseBind }
    }

    /// Uses the exact palette already submitted for rendering: eight vertex
    /// transforms, with no animation sampling or full-mesh deformation.
    func soleContactPoints(palette: [simd_float4x4]) -> (left: SoldierSolePoints, right: SoldierSolePoints) {
        (soles.left.deformed(by: palette), soles.right.deformed(by: palette))
    }

    func resetAnimation() { blends.removeAll(keepingCapacity: true) }

    /// Also useful for equipment attachments and pose validation; world coordinates.
    func jointPositions(enemy: EnemyState, time: Double, terrain: TerrainProfile) -> [String: SIMD3<Float>] {
        let pose = posedJoints(enemy: enemy, time: time, terrain: terrain)
        var chosen: [String:Int] = [:]
        for i in nodes.indices {
            if let previous=chosen[nodes[i].name],descendants[previous].count>=descendants[i].count { continue }
            chosen[nodes[i].name]=i
        }
        return chosen.mapValues { Self.position(pose[$0]) }
    }

    private func posedJoints(enemy: EnemyState, time: Double, terrain: TerrainProfile) -> [simd_float4x4] {
        let dead = enemy.health <= 0
        let moving = enemy.isMoving && !dead
        let clipName = moving ? (enemy.isRunning ? "run" : "walk") : "idle"
        let clip = clips[clipName] ?? clips["idle"]
        let phase = moving ? enemy.walkCycle / (2 * .pi) * (clip?.duration ?? 1) : Float((time.isFinite ? time : 0).truncatingRemainder(dividingBy: 10000)) + Float(enemy.id % 11) * 0.17
        let sampled = clip.map { Self.sample($0, at: phase, rest: nodes.map(\.rest)) } ?? nodes.map(\.rest)
        let blendedPose = blended(sampled,clip:clipName,enemyID:enemy.id,time:time)
        var pose = Self.globals(blendedPose.local, nodes: nodes, order: order).map { normalization * $0 }
        // Animation root motion must never fight the simulation's collision body.
        let root = Self.position(pose[rig.hips]), original = Self.position(bindWorld[rig.hips])
        let rootRemoval = SIMD3<Float>(original.x - root.x, 0, original.z - root.z)
        for index in descendants[rig.hips] { pose[index].columns.3 += SIMD4(rootRemoval, 0) }
        let sampledFeet = [Self.position(pose[rig.left.foot]), Self.position(pose[rig.right.foot])]
        let heightOffset = EnemyPose(enemy).headHeight - headOffset - Self.position(pose[rig.head]).y
        for index in descendants[rig.hips] { pose[index].columns.3.y += heightOffset }
        let world = Self.translation(enemy.position) * Self.rotationY(enemy.yaw)
        for i in pose.indices { pose[i] = world * pose[i] }
        let crouch = max(0, min(1, enemy.crouchAmount))
        let footing = enemy.grounded && abs(enemy.position.y - terrain.height(x: enemy.position.x, z: enemy.position.z)) < 0.15
        var footTargets: [(Rig.Side,SIMD3<Float>,SIMD3<Float>)] = []
        var pelvisDrop: Float = 0
        for (side,chain) in [rig.left, rig.right].enumerated() {
            let sign: Float = Self.position(bindWorld[chain.foot]).x < 0 ? -1 : 1
            let minimum = blendedPose.minimum[side]
            let lift = min(0.3, max(0, sampledFeet[side].y - minimum)) * blendedPose.activity
            var foot = dead ? Self.position(bindWorld[chain.foot]) : sampledFeet[side]
            let extent:Float=0.18+0.32*blendedPose.activity
            foot.z = max(-extent,min(extent,foot.z))
            foot.z *= 1 - crouch * 0.72
            foot.x = max(-0.35, min(0.35, foot.x)) + sign * crouch * 0.035
            foot.z = max(-0.5, min(0.5, foot.z)) + sign * crouch * 0.025
            foot.y = Self.position(bindWorld[chain.foot]).y + lift
            if !enemy.grounded && !dead { foot.y += side == 0 ? 0.20 : 0.13; foot.z -= 0.16 }
            var target = Self.point(world, foot)
            let normal = footing ? terrain.normal(x: target.x, z: target.z) : SIMD3<Float>(0, 1, 0)
            if footing { target.y += terrain.height(x: target.x, z: target.z) - enemy.position.y + 0.08 * (1 / max(0.55, normal.y) - 1) }
            footTargets.append((chain,target,normal))
            let upper = Self.position(pose[chain.upper]), knee = Self.position(pose[chain.lower]), ankle = Self.position(pose[chain.foot])
            let reach = (simd_distance(upper,knee) + simd_distance(knee,ankle)) * 0.995
            let dx = upper.x-target.x, dz = upper.z-target.z
            let verticalReach = sqrt(max(0.01,reach*reach-dx*dx-dz*dz))
            pelvisDrop = max(pelvisDrop,upper.y-target.y-verticalReach)
        }
        // Grounded feet take precedence over a clip's hip bounce. Compensate in
        // the short lower spine so the authoritative head and gun stay aligned.
        pelvisDrop = max(0,min(0.14,pelvisDrop))
        for i in descendants[rig.hips] { pose[i].columns.3.y -= pelvisDrop }
        for i in descendants[rig.spine] { pose[i].columns.3.y += pelvisDrop }
        for (chain,target,normal) in footTargets {
            let sign: Float = Self.position(bindWorld[chain.foot]).x < 0 ? -1 : 1
            solve(chain.upper,chain.lower,chain.foot,target:target,pole:Self.vector(world,SIMD3(sign*0.08,0,1)),pose:&pose)
            let desired = simd_quatf(from:SIMD3<Float>(0,1,0),to:normal) * Self.orientation(world * bindWorld[chain.foot])
            orient(chain.foot,to:desired,pose:&pose)
        }
        let authoritative = EnemyPose(enemy).gunTransform
        for (right,chain) in [(true,rig.right), (false,rig.left)] {
            let grip = right ? SIMD3<Float>(0.014,-0.075,0.074) : SIMD3<Float>(-0.016,-0.023,0.305)
            let along = dead ? Self.vector(world,SIMD3<Float>(0,-1,0)) : Self.vector(authoritative, right ? SIMD3(0,-1,0) : SIMD3(1,0,0))
            let normal = dead ? Self.vector(world,SIMD3<Float>(right ? -1:1,0,0)) : Self.vector(authoritative, right ? SIMD3(-1,0,0) : SIMD3(0,1,0))
            let desiredFrame = simd_float3x3(columns: (simd_cross(along,normal), along, normal))
            let hand = chain.hand
            let middle = nodes[chain.middle].rest.translation
            let index = nodes[chain.index].rest.translation, pinky = nodes[chain.pinky].rest.translation
            let localAlong = simd_normalize(middle)
            let across = simd_normalize(index-pinky - localAlong * simd_dot(index-pinky,localAlong))
            let localFrame = simd_float3x3(columns: (across,localAlong,simd_cross(across,localAlong)))
            let handRotation = simd_quatf(desiredFrame * localFrame.transpose)
            let palmOffset = min(0.09, simd_length(middle) * simd_length(SIMD3(bindWorld[hand].columns.0.x,bindWorld[hand].columns.0.y,bindWorld[hand].columns.0.z)) * 0.55)
            let shoulderSide: Float = Self.position(bindWorld[chain.arm]).x < 0 ? -1 : 1
            let target = dead ? Self.point(world,SIMD3(shoulderSide*0.27,0.98,0.035)) : Self.point(authoritative,grip) - along * palmOffset
            solve(chain.arm,chain.forearm,hand,target:target,pole:Self.vector(world,SIMD3(shoulderSide * 0.7,-1,-0.10)),pose:&pose)
            orient(hand,to:handRotation,pose:&pose)
            closeFingers(hand:hand,across:simd_cross(along,normal),relaxed:dead,trigger:right,pose:&pose)
        }
        // A modest head pitch keeps the face aligned while the rifle aims freely.
        rotate(rig.head, by: simd_quatf(angle:-enemy.aimPitch * 0.22,axis:Self.vector(world,SIMD3(1,0,0))),pose:&pose)
        if dead {
            let elapsed = max(0,Float(time - (enemy.deathTime ?? time)))
            let fall = min(1,elapsed * 2.7)
            let transform = Self.translation(enemy.position + SIMD3(0,fall * 0.26,0)) * Self.rotationY(enemy.yaw) * Self.rotationX(fall * .pi / 2) * world.inverse
            for i in pose.indices { pose[i] = transform * pose[i] }
        }
        return pose
    }

    private func blended(_ sample:[AssetTRS],clip:String,enemyID:Int,time:Double)->(local:[AssetTRS],activity:Float,minimum:SIMD2<Float>) {
        let activity:Float=clip=="idle" ? 0:1,minimum=footMinima[clip] ?? .zero
        guard time.isFinite else { return (sample,activity,minimum) }
        guard var blend=blends[enemyID],time>=blend.lastTime,time-blend.lastTime<0.5 else {
            if blends.count>128 { blends=blends.filter { time-$0.value.lastTime<8 } }
            blends[enemyID]=PoseBlend(clip:clip,start:time-1,lastTime:time,from:sample,current:sample,fromActivity:activity,activity:activity,fromMinimum:minimum,minimum:minimum)
            return (sample,activity,minimum)
        }
        if blend.clip != clip { blend.from=blend.current;blend.fromActivity=blend.activity;blend.fromMinimum=blend.minimum;blend.start=time;blend.clip=clip }
        let t=Float(max(0,min(1,(time-blend.start)/0.16))),alpha=t*t*(3-2*t)
        var result=sample
        if alpha<1 {
            for i in result.indices {
                result[i].translation=blend.from[i].translation+(sample[i].translation-blend.from[i].translation)*alpha
                result[i].scale=blend.from[i].scale+(sample[i].scale-blend.from[i].scale)*alpha
                result[i].rotation=simd_slerp(blend.from[i].rotation,sample[i].rotation,alpha)
            }
        }
        blend.activity=blend.fromActivity+(activity-blend.fromActivity)*alpha
        blend.minimum=blend.fromMinimum+(minimum-blend.fromMinimum)*alpha
        blend.current=result;blend.lastTime=time;blends[enemyID]=blend
        return (result,blend.activity,blend.minimum)
    }

    private func closeFingers(hand:Int,across:SIMD3<Float>,relaxed:Bool,trigger:Bool,pose:inout [simd_float4x4]) {
        // Replace locomotion finger keys with a stable grasp. All axes come from
        // the actual palm frame; no Mixamo bone-axis assumption is required.
        for i in order where i != hand && descendants[hand].contains(i) {
            pose[i] = pose[nodes[i].parent] * bindLocal[i].matrix
        }
        let prefix = nodes[hand].name
        for finger in ["Index","Middle","Ring","Pinky"] {
            for segment in 1...3 {
                guard let node = nodes.firstIndex(where: { $0.name == prefix + finger + String(segment) }) else { continue }
                var amount:Float = segment == 1 ? 0.88 : segment == 2 ? 1.12 : 0.48
                if trigger && finger == "Index" { amount *= segment == 1 ? 0.5 : 0.7 }
                if relaxed { amount *= 0.35 }
                rotate(node,by:simd_quatf(angle:amount,axis:across),pose:&pose)
            }
        }
        for segment in 1...3 {
            guard let node = nodes.firstIndex(where: { $0.name == prefix + "Thumb" + String(segment) }) else { continue }
            rotate(node,by:simd_quatf(angle:(segment == 1 ? 0.50:0.72)*(relaxed ? 0.3:1),axis:across),pose:&pose)
        }
    }

    private func solve(_ upper:Int,_ lower:Int,_ end:Int,target:SIMD3<Float>,pole:SIMD3<Float>,pose:inout [simd_float4x4]) {
        let origin = Self.position(pose[upper]), elbow = Self.position(pose[lower]), hand = Self.position(pose[end])
        let a = simd_distance(origin,elbow), b = simd_distance(elbow,hand)
        let delta = target-origin, raw = simd_length(delta)
        guard a > 0.0001, b > 0.0001, raw > 0.0001 else { return }
        let axis = delta/raw, distance = max(abs(a-b)+0.0001,min(a+b-0.0001,raw))
        let along = (a*a-b*b+distance*distance)/(2*distance)
        var bend = pole-axis*simd_dot(pole,axis)
        if simd_length_squared(bend)<0.00001 { bend=simd_cross(axis,abs(axis.y)<0.9 ? SIMD3(0,1,0):SIMD3(1,0,0)) }
        let joint = origin+axis*along+simd_normalize(bend)*sqrt(max(0,a*a-along*along))
        rotate(upper,by:simd_quatf(from:simd_normalize(elbow-origin),to:simd_normalize(joint-origin)),pose:&pose)
        let newElbow = Self.position(pose[lower]), newHand = Self.position(pose[end])
        let reachable = origin+axis*distance
        rotate(lower,by:simd_quatf(from:simd_normalize(newHand-newElbow),to:simd_normalize(reachable-newElbow)),pose:&pose)
    }
    private func orient(_ node:Int,to rotation:simd_quatf,pose:inout [simd_float4x4]) { rotate(node,by:rotation * Self.orientation(pose[node]).inverse,pose:&pose) }
    private func rotate(_ node:Int,by rotation:simd_quatf,pose:inout [simd_float4x4]) {
        let pivot=Self.position(pose[node]),transform=Self.translation(pivot)*simd_float4x4(rotation)*Self.translation(-pivot)
        for index in descendants[node] { pose[index]=transform*pose[index] }
    }
    private static func sample(_ clip:AssetClip,at time:Float,rest:[AssetTRS])->[AssetTRS] {
        var result=rest
        let t=clip.duration>0 ? (time.truncatingRemainder(dividingBy:clip.duration)+clip.duration).truncatingRemainder(dividingBy:clip.duration):0
        for track in clip.tracks {
            var lo=0,hi=track.times.count-1
            while lo+1<hi { let mid=(lo+hi)/2;if track.times[mid]<=t { lo=mid } else { hi=mid } }
            let next=min(lo+1,track.times.count-1)
            let interval=track.times[next]-track.times[lo]
            let amount=track.step || interval<=0 ? 0:max(0,min(1,(t-track.times[lo])/interval))
            func value(_ key:Int)->SIMD4<Float> {
                let i=key*track.width
                return SIMD4(track.values[i],track.values[i+1],track.values[i+2],track.width==4 ? track.values[i+3]:0)
            }
            let a=value(lo),b=value(next)
            if track.path=="rotation" { result[track.node].rotation=simd_slerp(simd_quatf(vector:a).normalized,simd_quatf(vector:b).normalized,amount) }
            else {
                let v=a+(b-a)*amount,vector=SIMD3(v.x,v.y,v.z)
                if track.path=="translation" { result[track.node].translation=vector } else { result[track.node].scale=vector }
            }
        }
        return result
    }
    private static func globals(_ local:[AssetTRS],nodes:[AssetNode],order:[Int])->[simd_float4x4] {
        var result=Array(repeating:matrix_identity_float4x4,count:nodes.count)
        for i in order { let m=local[i].matrix;result[i]=nodes[i].parent<0 ? m:result[nodes[i].parent]*m }
        return result
    }
    static func skin(_ vertex:SoldierVertex,palette:[simd_float4x4])->SIMD3<Float> {
        var point=SIMD4<Float>()
        for k in 0..<4 { point += (palette[Int(vertex.joints[k])]*SIMD4(vertex.position,1))*vertex.weights[k] }
        return SIMD3(point.x,point.y,point.z)
    }
    private static func orientation(_ m:simd_float4x4)->simd_quatf {
        simd_quatf(simd_float3x3(columns:(simd_normalize(SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z)),simd_normalize(SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z)),simd_normalize(SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z)))))
    }
    private static func position(_ m:simd_float4x4)->SIMD3<Float> { SIMD3(m.columns.3.x,m.columns.3.y,m.columns.3.z) }
    private static func point(_ m:simd_float4x4,_ p:SIMD3<Float>)->SIMD3<Float> { let v=m*SIMD4(p,1);return SIMD3(v.x,v.y,v.z) }
    private static func vector(_ m:simd_float4x4,_ p:SIMD3<Float>)->SIMD3<Float> { let v=m*SIMD4(p,0);return SIMD3(v.x,v.y,v.z) }
    private static func translation(_ v:SIMD3<Float>)->simd_float4x4 { var m=matrix_identity_float4x4;m.columns.3=SIMD4(v,1);return m }
    private static func scaling(_ v:SIMD3<Float>)->simd_float4x4 { simd_float4x4(diagonal:SIMD4(v,1)) }
    private static func rotationY(_ a:Float)->simd_float4x4 { simd_float4x4(simd_quatf(angle:a,axis:SIMD3(0,1,0))) }
    private static func rotationX(_ a:Float)->simd_float4x4 { simd_float4x4(simd_quatf(angle:a,axis:SIMD3(1,0,0))) }
    private static func finite(_ m:simd_float4x4)->Bool { (0..<4).allSatisfy { c in (0..<4).allSatisfy { m[c][$0].isFinite } } }
    fileprivate static func matrix(_ values:[Float],_ at:Int)->simd_float4x4 {
        func column(_ n:Int)->SIMD4<Float> { SIMD4(values[at+n],values[at+n+1],values[at+n+2],values[at+n+3]) }
        return simd_float4x4(columns:(column(0),column(4),column(8),column(12)))
    }
}

private struct HeadTriangleMaterials:Decodable {
    let version:Int
    let positionAccessor:Int
    let triangleMaterials:[Int]
}
private struct AssetNode { let name:String;let parent:Int;let rest:AssetTRS }
private struct PaletteEntry { let node:Int;let inverseBind:simd_float4x4 }
private struct AssetClip { let duration:Float;let tracks:[AssetTrack] }
private struct AssetTrack { let node:Int;let path:String;let times:[Float];let values:[Float];let width:Int;let step:Bool }
private struct AssetTRS {
    var translation:SIMD3<Float>;var rotation:simd_quatf;var scale:SIMD3<Float>
    var matrix:simd_float4x4 { var m=simd_float4x4(rotation);m.columns.0 *= scale.x;m.columns.1 *= scale.y;m.columns.2 *= scale.z;m.columns.3=SIMD4(translation,1);return m }
    init(matrix m:simd_float4x4) {
        translation=SIMD3(m.columns.3.x,m.columns.3.y,m.columns.3.z)
        let a=SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z),b=SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z),c=SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z)
        scale=SIMD3(simd_length(a),simd_length(b),simd_length(c))
        rotation=simd_quatf(simd_float3x3(columns:(a/scale.x,b/scale.y,c/scale.z))).normalized
    }
    init(_ node:GLTFDocument.Node)throws {
        func triple(_ a:[Float]?,_ fallback:SIMD3<Float>)throws->SIMD3<Float> {
            guard let a else { return fallback };guard a.count==3,a.allSatisfy(\.isFinite) else { throw SoldierAssetError.malformed("invalid node vector") };return SIMD3(a[0],a[1],a[2])
        }
        translation=try triple(node.translation,.zero);scale=try triple(node.scale,SIMD3(repeating:1))
        let q=node.rotation ?? [0,0,0,1]
        guard q.count==4,q.allSatisfy(\.isFinite),scale.x>0,scale.y>0,scale.z>0 else { throw SoldierAssetError.malformed("invalid node transform") }
        let vector=SIMD4<Float>(q[0],q[1],q[2],q[3]);guard simd_length_squared(vector)>0.000001,simd_length_squared(vector).isFinite else { throw SoldierAssetError.malformed("invalid quaternion") }
        rotation=simd_quatf(vector:vector).normalized
        if let values=node.matrix {
            guard values.count==16,values.allSatisfy(\.isFinite) else { throw SoldierAssetError.malformed("invalid node matrix") }
            let m=SoldierAsset.matrix(values,0)
            translation=SIMD3(m.columns.3.x,m.columns.3.y,m.columns.3.z)
            let a=SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z),b=SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z),c=SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z)
            scale=SIMD3(simd_length(a),simd_length(b),simd_length(c))
            guard scale.x>0,scale.y>0,scale.z>0 else { throw SoldierAssetError.malformed("singular node matrix") }
            rotation=simd_quatf(simd_float3x3(columns:(a/scale.x,b/scale.y,c/scale.z))).normalized
        }
    }
}
private struct Rig {
    struct Side { let arm:Int,forearm:Int,hand:Int,middle:Int,index:Int,pinky:Int,upper:Int,lower:Int,foot:Int,toe:Int }
    let hips:Int,spine:Int,head:Int,left:Side,right:Side
    init(nodes:[AssetNode])throws {
        func find(_ suffix:String)throws->Int {
            guard let i=nodes.firstIndex(where: { $0.name.lowercased().replacingOccurrences(of:"^mixamorig[0-9]*:?",with:"",options:.regularExpression)==suffix.lowercased() }) else { throw SoldierAssetError.malformed("missing rig joint \(suffix)") };return i
        }
        func side(_ s:String)throws->Side {
            try Side(arm:find(s+"Arm"),forearm:find(s+"ForeArm"),hand:find(s+"Hand"),middle:find(s+"HandMiddle1"),index:find(s+"HandIndex1"),pinky:find(s+"HandPinky1"),upper:find(s+"UpLeg"),lower:find(s+"Leg"),foot:find(s+"Foot"),toe:find(s+"ToeBase"))
        }
        hips=try find("Hips");spine=try find("Spine");head=try find("Head");left=try side("Left");right=try side("Right")
    }
}

private struct GLTFDocument:Decodable {
    struct Node:Decodable { var name:String?;var children:[Int]?;var translation:[Float]?;var rotation:[Float]?;var scale:[Float]?;var matrix:[Float]?;var mesh:Int?;var skin:Int? }
    struct Skin:Decodable { var inverseBindMatrices:Int?;var joints:[Int] }
    struct Mesh:Decodable { var primitives:[Primitive] }
    struct Primitive:Decodable { var attributes:[String:Int];var indices:Int?;var material:Int?;var mode:Int? }
    struct Accessor:Decodable { var bufferView:Int?;var byteOffset:Int?;var componentType:Int;var count:Int;var type:String;var normalized:Bool?;var sparse:Sparse? }
    struct Sparse:Decodable { var count:Int }
    struct BufferView:Decodable { var buffer:Int;var byteOffset:Int?;var byteLength:Int;var byteStride:Int? }
    struct Buffer:Decodable { var uri:String?;var byteLength:Int }
    struct Image:Decodable { var bufferView:Int?;var uri:String? }
    struct Texture:Decodable { var source:Int }
    struct TextureInfo:Decodable { var index:Int }
    struct PBR:Decodable { var baseColorTexture:TextureInfo? }
    struct Material:Decodable { var name:String?;var pbrMetallicRoughness:PBR?;var normalTexture:TextureInfo? }
    struct Animation:Decodable {
        struct Sampler:Decodable { var input:Int;var output:Int;var interpolation:String? }
        struct Target:Decodable { var node:Int?;var path:String }
        struct Channel:Decodable { var sampler:Int;var target:Target }
        var name:String?;var channels:[Channel];var samplers:[Sampler]
    }
    var nodes:[Node];var skins:[Skin];var meshes:[Mesh];var accessors:[Accessor];var bufferViews:[BufferView];var buffers:[Buffer];var images:[Image];var textures:[Texture];var materials:[Material];var animations:[Animation]?
}
private final class GLTFSource {
    let document:GLTFDocument
    private let buffers:[Data]
    private let directory:URL
    init(url:URL)throws {
        let data=try Data(contentsOf:url),root=url.deletingLastPathComponent()
        var json=data,binary:Data?
        if data.count>=4,Self.u32(data,0)==0x46546c67 {
            guard data.count>=20,Self.u32(data,4)==2,Int(Self.u32(data,8))==data.count else { throw SoldierAssetError.malformed("invalid GLB header") }
            var offset=12;var foundJSON=false
            while offset<data.count {
                guard offset<=data.count-8 else { throw SoldierAssetError.malformed("truncated GLB chunk") }
                let size=Int(Self.u32(data,offset)),type=Self.u32(data,offset+4);offset+=8
                guard size<=data.count-offset else { throw SoldierAssetError.malformed("GLB chunk exceeds file") }
                if type==0x4e4f534a { guard !foundJSON else { throw SoldierAssetError.malformed("duplicate JSON chunk") };json=data.subdata(in:offset..<offset+size);foundJSON=true }
                else if type==0x004e4942 { binary=data.subdata(in:offset..<offset+size) }
                offset+=size
            }
            guard foundJSON else { throw SoldierAssetError.malformed("missing GLB JSON") }
        }
        let parsed=try JSONDecoder().decode(GLTFDocument.self,from:json)
        var loaded:[Data]=[]
        for buffer in parsed.buffers {
            let value:Data
            if let uri=buffer.uri { value=try Self.read(uri,relativeTo:root) }
            else if let binary { value=binary } else { throw SoldierAssetError.malformed("missing binary buffer") }
            guard buffer.byteLength>=0,value.count>=buffer.byteLength else { throw SoldierAssetError.malformed("truncated binary buffer") }
            loaded.append(value)
        }
        document=parsed;buffers=loaded;directory=root
    }
    func floats(_ index:Int,components:Int)throws->[Float] {
        let layout=try accessor(index,components:components)
        var result:[Float]=[];result.reserveCapacity(layout.count*components)
        let data=buffers[layout.buffer]
        for row in 0..<layout.count { for component in 0..<components {
            let offset=layout.offset+row*layout.stride+component*layout.componentSize
            let value:Float
            switch layout.type {
            case 5126:value=Float(bitPattern:Self.u32(data,offset))
            case 5121:value=Float(data[offset])/(layout.normalized ? 255:1)
            case 5123:value=Float(Self.u16(data,offset))/(layout.normalized ? 65535:1)
            case 5125:value=Float(Self.u32(data,offset))
            case 5120:let raw=Float(Int8(bitPattern:data[offset]));value=layout.normalized ? max(-1,raw/127):raw
            case 5122:let raw=Float(Int16(bitPattern:Self.u16(data,offset)));value=layout.normalized ? max(-1,raw/32767):raw
            default:throw SoldierAssetError.malformed("unsupported accessor type")
            }
            guard value.isFinite else { throw SoldierAssetError.malformed("nonfinite accessor") };result.append(value)
        } }
        return result
    }
    func unsigned(_ index:Int,components:Int)throws->[UInt32] {
        let layout=try accessor(index,components:components)
        guard [5121,5123,5125].contains(layout.type),!layout.normalized else { throw SoldierAssetError.malformed("invalid integer accessor") }
        let data=buffers[layout.buffer];var result:[UInt32]=[];result.reserveCapacity(layout.count*components)
        for row in 0..<layout.count { for component in 0..<components {
            let offset=layout.offset+row*layout.stride+component*layout.componentSize
            result.append(layout.type==5121 ? UInt32(data[offset]):layout.type==5123 ? UInt32(Self.u16(data,offset)):Self.u32(data,offset))
        } };return result
    }
    func texture(_ index:Int)throws->Data {
        guard document.textures.indices.contains(index),document.images.indices.contains(document.textures[index].source) else { throw SoldierAssetError.malformed("invalid texture source") }
        let image=document.images[document.textures[index].source]
        if let view=image.bufferView { return try viewData(view) }
        if let uri=image.uri { return try Self.read(uri,relativeTo:directory) }
        throw SoldierAssetError.malformed("empty image")
    }
    private struct Layout { let buffer:Int,offset:Int,count:Int,stride:Int,componentSize:Int,type:Int;let normalized:Bool }
    private func accessor(_ index:Int,components:Int)throws->Layout {
        guard document.accessors.indices.contains(index) else { throw SoldierAssetError.malformed("accessor out of range") }
        let a=document.accessors[index],sizes=["SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4,"MAT4":16]
        guard sizes[a.type]==components,a.count>=0,a.count<10_000_000,a.sparse==nil,let v=a.bufferView,document.bufferViews.indices.contains(v) else { throw SoldierAssetError.malformed("invalid or unsupported accessor") }
        let view=document.bufferViews[v],componentSize=[5120:1,5121:1,5122:2,5123:2,5125:4,5126:4][a.componentType] ?? 0
        let stride=view.byteStride ?? components*componentSize,local=a.byteOffset ?? 0,base=view.byteOffset ?? 0
        guard componentSize>0,stride>=components*componentSize,stride<=4096,local>=0,local<=view.byteLength,base>=0,view.byteLength>=0,
              buffers.indices.contains(view.buffer),base<=buffers[view.buffer].count,view.byteLength<=buffers[view.buffer].count-base else { throw SoldierAssetError.malformed("invalid buffer view") }
        let end=local+(a.count==0 ? 0:(a.count-1)*stride+components*componentSize)
        guard end<=view.byteLength else { throw SoldierAssetError.malformed("accessor exceeds buffer view") }
        return Layout(buffer:view.buffer,offset:base+local,count:a.count,stride:stride,componentSize:componentSize,type:a.componentType,normalized:a.normalized ?? false)
    }
    private func viewData(_ index:Int)throws->Data {
        guard document.bufferViews.indices.contains(index) else { throw SoldierAssetError.malformed("image view out of range") }
        let view=document.bufferViews[index],start=view.byteOffset ?? 0
        guard buffers.indices.contains(view.buffer),start>=0,view.byteLength>=0,start<=buffers[view.buffer].count,view.byteLength<=buffers[view.buffer].count-start else { throw SoldierAssetError.malformed("image outside buffer") }
        return buffers[view.buffer].subdata(in:start..<start+view.byteLength)
    }
    private static func read(_ uri:String,relativeTo directory:URL)throws->Data {
        if uri.hasPrefix("data:"),let comma=uri.firstIndex(of:","),uri[..<comma].hasSuffix(";base64"),let data=Data(base64Encoded:String(uri[uri.index(after:comma)...])) { return data }
        guard !uri.contains(":") else { throw SoldierAssetError.malformed("external URL scheme unsupported") }
        return try Data(contentsOf:directory.appendingPathComponent(uri.removingPercentEncoding ?? uri))
    }
    private static func u16(_ data:Data,_ offset:Int)->UInt16 { data.withUnsafeBytes { UInt16(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt16.self)) } }
    private static func u32(_ data:Data,_ offset:Int)->UInt32 { data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self)) } }
}
