import Foundation
import simd

/// Deterministic combat rules. Rendering and native input remain outside this type.
/// Call exclusively on the game thread; wall-clock deltas are integrated at 120 Hz.
public final class CombatSimulation {
    public let map: MapDefinition
    public let terrain: TerrainProfile
    public let missionKind: MissionKind
    public private(set) var player: PlayerState
    public private(set) var enemies: [EnemyState]
    public private(set) var obstacles: [Obstacle]
    public private(set) var coverDebris: [CoverDebrisState] = []
    public private(set) var grenades: [GrenadeState] = []
    public private(set) var supplies: [SupplyState] = []
    public private(set) var weapons: [WeaponKind: WeaponState] = [
        .rifle: WeaponState(kind: .rifle), .sniper: WeaponState(kind: .sniper)
    ]
    public private(set) var activeWeapon: WeaponKind = .rifle
    public private(set) var grenadeCount = 4
    public private(set) var kills = 0
    public private(set) var score = 0
    public private(set) var wave: Int
    public private(set) var elapsed: Double = 0
    public private(set) var state: MatchState = .active
    public private(set) var isAiming = false
    public private(set) var isSprinting = false
    public private(set) var isMoving = false
    public private(set) var intermission: Float = 1.4
    public private(set) var extractionProgress: Float = 0
    public private(set) var pendingReinforcements = 0
    public var remainingEnemies: Int { aliveCount + pendingReinforcements }
    public var extractionReady: Bool {
        switch missionKind {
        case .waves: return wave == 3 && remainingEnemies == 0
        case .recoverData: return missionPhase == .extract || missionPhase == .completed
        case .secureRadio: return false
        }
    }
    public var aliveCount: Int { enemies.reduce(0) { $0 + ($1.health > 0 ? 1 : 0) } }
    public var eyePosition: SIMD3<Float> { player.position + SIMD3(0, player.height - 0.1, 0) }
    public var isHidden: Bool {
        aliveCount > 0 && !enemies.contains { $0.health > 0 && $0.seesPlayer } && elapsed - lastShot > 1.5
    }
    public var mantleAvailable: Bool { state == .active && climbing == nil && player.grounded && mantleTarget() != nil }
    public var climbProgress: Float? { climbing.map { $0.progress / 0.75 } }
    public var extractionPosition: SIMD3<Float> { groundedPoint(map.extraction) }
    private var insideExtraction: Bool {
        horizontalDistance(player.position, extractionPosition) < map.extractionRadius && player.grounded &&
            abs(player.position.y - extractionPosition.y) < 0.2
    }
    private var radioContested: Bool {
        enemies.contains { $0.health > 0 && horizontalDistance($0.position, map.radioSite) <= 5 }
    }
    private var groundedAtRadio: Bool {
        player.grounded && climbing == nil && abs(player.position.y - groundedPoint(map.radioSite).y) <= 2.5
    }
    public var missionInteractionAvailable: Bool {
        guard state == .active, missionPhase == .collectData || missionPhase == .activateRadio,
              player.grounded, climbing == nil else { return false }
        let target = groundedPoint(missionPhase == .collectData ? map.dataSite : map.radioSite)
        return simd_distance(player.position, target) <= 1.6
    }
    public var missionStatus: MissionStatus {
        let phase: MissionPhase = state == .won ? .completed : missionKind == .waves ? (extractionReady ? .extract : .waves) : missionPhase
        let target: SIMD3<Float>?, radius: Float, progress: Float, required: Float
        var interruption: MissionInterruption?
        switch phase {
        case .waves:
            target = nil; radius = 0; progress = Float(kills); required = 21
        case .collectData, .activateRadio:
            target = groundedPoint(phase == .collectData ? map.dataSite : map.radioSite)
            radius = 1.6; progress = Float(missionProgressTicks)/120; required = phase == .collectData ? 0.8 : 1
            if !player.grounded || climbing != nil { interruption = .notGrounded }
            else if !missionInteractionAvailable { interruption = .outOfRange }
            else if !interactionHeld { interruption = .interactionReleased }
        case .extract:
            target = extractionPosition; radius = map.extractionRadius; progress = extractionProgress; required = 3
            if !player.grounded || climbing != nil { interruption = .notGrounded }
            else if !insideExtraction { interruption = .outOfRange }
        case .holdRadio:
            target = groundedPoint(map.radioSite); radius = 5; progress = Float(missionProgressTicks)/120; required = 45
            if !groundedAtRadio { interruption = .notGrounded }
            else if horizontalDistance(player.position, map.radioSite) > radius { interruption = .outOfRange }
            else if radioContested { interruption = .contested }
        case .completed:
            target = nil; radius = 0; progress = 1; required = 1
        }
        if state != .active { interruption = nil }
        return MissionStatus(kind: missionKind, phase: phase, objectivePosition: target, objectiveRadius: radius,
                             distance: target.map { phase == .holdRadio ? horizontalDistance(player.position, $0) : simd_distance(player.position, $0) },
                             progress: progress, requiredProgress: required, interruption: interruption,
                             interactionAvailable: missionInteractionAvailable)
    }

    let difficulty: Difficulty
    private var seed: UInt64
    private var accumulator: Double = 0
    private var nextID = 100
    private var grenadeCooldown: Float = 0
    private var lastShot: Double = -20
    private var extractionAnnounced = false
    private var missionPhase: MissionPhase
    private var missionStarted = false
    private var missionProgressTicks = 0
    private var interactionHeld = false
    private var reinforcementTimer: Float = 0
    private var reinforcementCursor = 0
    private var deployedThisWave = 0
    private var events: [GameEvent] = []
    private var pendingCoverDebris: [Obstacle] = []
    private var climbing: ClimbState?
    private var brains: [Int: EnemyBrain] = [:]
    private var navigationDirty = true
    // Reuse BFS work buffers. Only the output path is allocated per route request.
    private let navWidth: Int, navDepth: Int
    private let navSpacing: Float = 2
    private var navigation: [Bool]
    private var navigationHeights: [Float]
    private var navigationLinks: [UInt8]
    private var navigationComponents: [Int]
    private var visited: [UInt32]
    private var previous: [Int]
    private var searchGeneration: UInt32 = 0
    private var searchQueue = [Int]()

    public convenience init(map: MapDefinition = .blacksite, difficulty: Difficulty = .normal, seed: UInt64 = 1745,
                            terrainOverride: TerrainProfile? = nil, mission: MissionKind = .waves) {
        let selected = terrainOverride.map { map.withTerrain($0) } ?? map
        self.init(difficulty: difficulty, seed: seed, world: selected.obstacles,
                  startingEnemies: [], startingWave: 0, terrain: selected.terrain, mission: mission, map: selected)
    }

    /// Compatibility for existing callers which explicitly selected a profile.
    public convenience init(difficulty: Difficulty = .normal, seed: UInt64 = 1745, terrain: TerrainProfile,
                            mission: MissionKind = .waves) {
        self.init(map: .blacksite, difficulty: difficulty, seed: seed, terrainOverride: terrain, mission: mission)
    }

    /// Explicit actor heights remain world-space. Omitted actors use the map's
    /// authored start. Legacy isolated worlds retain their flat default profile.
    public init(difficulty: Difficulty = .normal, seed: UInt64 = 1745, world: [Obstacle],
                startingPlayer: PlayerState? = nil, startingEnemies: [EnemyState] = [], startingWave: Int = 0,
                terrain: TerrainProfile? = nil, mission: MissionKind = .waves, map: MapDefinition? = nil) {
        let selected = map ?? MapDefinition.blacksite.withoutVegetation()
        let terrain = terrain ?? (map == nil ? .flat : selected.terrain)
        self.map = selected.withTerrain(terrain)
        self.difficulty = difficulty; self.seed = seed & 0xffff_ffff; self.terrain = terrain; missionKind = mission
        missionPhase = mission == .waves ? .waves : mission == .recoverData ? .collectData : .activateRadio
        navWidth = Int(floor((selected.maximum.x - selected.minimum.x) / navSpacing)) + 1
        navDepth = Int(floor((selected.maximum.z - selected.minimum.z) / navSpacing)) + 1
        let cells = navWidth * navDepth
        navigation = [Bool](repeating: false, count: cells)
        navigationHeights = [Float](repeating: 0, count: cells)
        navigationLinks = [UInt8](repeating: 0, count: cells)
        navigationComponents = [Int](repeating: 0, count: cells)
        visited = [UInt32](repeating: 0, count: cells)
        previous = [Int](repeating: -1, count: cells)
        obstacles = world.map { box in
            var grounded = Obstacle(id: box.id, kind: box.kind,
                                    position: box.position + SIMD3(0, terrain.height(x: box.position.x, z: box.position.z), 0), size: box.size)
            grounded.health = box.health; grounded.destroyed = box.destroyed
            return grounded
        }
        player = startingPlayer ?? selected.playerStart
        if startingPlayer == nil { player.position = self.map.grounded(player.position) }
        enemies = startingEnemies; wave = mission == .waves ? startingWave : 0
        if player.grounded && abs(player.position.y) < 0.001 { player.position.y = terrain.height(x: player.position.x, z: player.position.z) }
        for index in enemies.indices where enemies[index].grounded && abs(enemies[index].position.y) < 0.001 {
            enemies[index].position.y = terrain.height(x: enemies[index].position.x, z: enemies[index].position.z)
        }
        events.reserveCapacity(128); searchQueue.reserveCapacity(navWidth * navDepth)
        grenades.reserveCapacity(8); supplies.reserveCapacity(8)
        coverDebris.reserveCapacity(CoverDebrisState.maximumCount)
        pendingCoverDebris.reserveCapacity(world.count)
        for box in obstacles { nextID = max(nextID, box.id + 1) }
        for enemy in enemies {
            brains[enemy.id] = EnemyBrain(cooldown: 2, sightTimer: Float(enemy.id % 5) * 0.02,
                                         patrolAnchor: enemy.position, patrolYaw: enemy.yaw)
            nextID = max(nextID, enemy.id + 1)
        }
    }

    private func groundedPoint(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, terrain.height(x: p.x, z: p.z), p.z) }

    public func drainEvents() -> [GameEvent] {
        let result = events
        events.removeAll(keepingCapacity: true)
        return result
    }

    private func emit(_ event: GameEvent) {
        // A paused renderer must not let undrained effects grow without bound.
        if events.count >= 1024 { events.removeFirst(256) }
        events.append(event)
    }

    private func random() -> Float {
        seed = (1_664_525 &* seed &+ 1_013_904_223) & 0xffff_ffff
        return Float(Double(seed) / 4_294_967_296)
    }

    public func selectWeapon(_ kind: WeaponKind) {
        guard state == .active else { return }
        activeWeapon = kind; isAiming = false
    }

    @discardableResult public func reload() -> Bool {
        guard state == .active, var weapon = weapons[activeWeapon], weapon.reloadRemaining <= 0,
              weapon.ammo < activeWeapon.capacity, weapon.reserve > 0 else { return false }
        weapon.reloadRemaining = activeWeapon.reloadDuration
        weapons[activeWeapon] = weapon; isAiming = false
        emit(GameEvent(kind: .reload, position: eyePosition, weapon: activeWeapon))
        return true
    }

    public func toggleProne() {
        guard state == .active, player.grounded, climbing == nil else { return }
        if player.prone && blocked(player.position, height: 1.72, radius: 0.32) { return }
        player.prone.toggle()
    }

    @discardableResult public func jump() -> Bool {
        guard state == .active, climbing == nil, player.grounded, player.stamina >= 12 else { return false }
        if player.prone { toggleProne(); return false }
        player.verticalVelocity = 6.8; player.grounded = false; player.stamina -= 12
        emit(GameEvent(kind: .jump, position: player.position))
        return true
    }

    @discardableResult public func mantle() -> Bool {
        guard state == .active, climbing == nil, player.grounded, let target = mantleTarget() else { return false }
        climbing = ClimbState(from: player.position, to: target.position, obstacleID: target.obstacleID)
        player.prone = false; player.verticalVelocity = 0; isAiming = false; isSprinting = false
        emit(GameEvent(kind: .climb, position: player.position, endPosition: target.position))
        return true
    }

    private func mantleTarget() -> (position: SIMD3<Float>, obstacleID: Int)? {
        let p = player.position, facing = viewDirection(yaw: player.yaw, pitch: 0)
        for box in obstacles where !box.destroyed && box.kind != .barrel {
            let top = box.maximum.y
            guard top - p.y >= 0.55, top - p.y <= 3.3,
                  box.size.x >= 1.2, box.size.z >= 0.6 else { continue }
            let nearest = SIMD3(clamp(p.x, box.minimum.x, box.maximum.x), p.y,
                                clamp(p.z, box.minimum.z, box.maximum.z))
            let distance = horizontalDistance(p, nearest)
            guard distance > 0.01, distance <= 1.25,
                  simd_dot(nearest - p, facing) / distance >= 0.35 else { continue }
            let insetX = min(0.6, box.size.x * 0.4), insetZ = min(0.6, box.size.z * 0.4)
            let target = SIMD3(clamp(nearest.x + (box.position.x - nearest.x) * 0.35,
                                     box.minimum.x + insetX, box.maximum.x - insetX), top,
                               clamp(nearest.z + (box.position.z - nearest.z) * 0.35,
                                     box.minimum.z + insetZ, box.maximum.z - insetZ))
            if !blocked(target, height: 1.72, radius: 0.32) { return (target, box.id) }
        }
        return nil
    }

    func blocked(_ position: SIMD3<Float>, height: Float = 1.72, radius: Float = 0.32) -> Bool {
        if position.x < map.minimum.x + radius || position.x > map.maximum.x - radius ||
            position.z < map.minimum.z + radius || position.z > map.maximum.z - radius { return true }
        for box in obstacles where !box.destroyed {
            let low = box.minimum, high = box.maximum
            if position.y < high.y - 0.025 && position.y + height > low.y + 0.025 &&
                position.x + radius > low.x && position.x - radius < high.x &&
                position.z + radius > low.z && position.z - radius < high.z { return true }
        }
        return false
    }

    private func moved(_ position: SIMD3<Float>, delta: SIMD3<Float>, height: Float, radius: Float = 0.32, grounded: Bool = false) -> SIMD3<Float> {
        var result = position
        for axis in [0, 2] {
            var candidate = result; candidate[axis] += delta[axis]
            let before = terrain.height(x: result.x, z: result.z), after = terrain.height(x: candidate.x, z: candidate.z)
            if grounded && abs(result.y - before) < 0.2 {
                if after > result.y + 0.01 && terrain.normal(x: candidate.x, z: candidate.z).y < 0.72 { continue }
                if after - before > max(0.12, abs(delta[axis]) * 1.1) { continue }
                if abs(after - before) < 0.3 { candidate.y = after }
            }
            if !blocked(candidate, height: height, radius: radius) { result = candidate }
        }
        return result
    }

    func wallHit(origin: SIMD3<Float>, direction: SIMD3<Float>, maximumDistance: Float = 150,
                 padding: Float = 0, excludingObstacle: Int? = nil) -> RayHit {
        var closest = RayHit(distance: maximumDistance)
        let pad = SIMD3<Float>(repeating: padding)
        for index in obstacles.indices where !obstacles[index].destroyed && index != excludingObstacle {
            let box = obstacles[index]
            if var hit = rayBox(origin: origin, direction: direction, minimum: box.minimum - pad, maximum: box.maximum + pad),
               hit.distance < closest.distance {
                hit.obstacleIndex = index; closest = hit
            }
        }
        if let ground = terrain.rayIntersection(origin: origin, direction: direction, maximumDistance: closest.distance, padding: padding),
           ground.distance < closest.distance {
            closest = RayHit(distance: ground.distance, normal: ground.normal, hitGround: true)
        }
        return closest
    }

    func clearLine(_ from: SIMD3<Float>, _ to: SIMD3<Float>, excludingObstacle: Int? = nil) -> Bool {
        let offset = to - from, length = simd_length(offset)
        if length < 0.001 { return true }
        return wallHit(origin: from, direction: offset / length, maximumDistance: length,
                       excludingObstacle: excludingObstacle).distance >= length - 0.01
    }

    func traceShot(origin: SIMD3<Float>, direction: SIMD3<Float>) -> RayHit {
        var result = wallHit(origin: origin, direction: direction)
        for index in enemies.indices where enemies[index].health > 0 {
            let enemy = enemies[index], pose = EnemyPose(enemy)
            for (height, radius, head) in [(pose.headHeight, Float(0.25), true), (pose.bodyHeight, 0.43 - enemy.crouchAmount * 0.07, false), (0.55 - enemy.crouchAmount * 0.25, 0.34, false)] {
                let distance = raySphere(origin: origin, direction: direction,
                                         center: enemies[index].position + SIMD3(0, height, 0), radius: radius)
                if distance < result.distance { result = RayHit(distance: distance, enemyIndex: index, headshot: head) }
            }
        }
        return result
    }

    @discardableResult func fire() -> Bool {
        guard state == .active, !isSprinting, climbing == nil, var weapon = weapons[activeWeapon],
              weapon.reloadRemaining <= 0, weapon.cooldown <= 0 else { return false }
        guard weapon.ammo > 0 else { reload(); return false }
        weapon.ammo -= 1; weapon.cooldown = activeWeapon.fireInterval; weapons[activeWeapon] = weapon
        lastShot = elapsed
        hearNoise(at: player.position, radius: 38)
        let spread: Float = isAiming ? (activeWeapon == .sniper ? 0.0002 : 0.0017) : (activeWeapon == .sniper ? 0.021 : 0.009)
        let direction = viewDirection(yaw: player.yaw + (random() - 0.5) * spread,
                                      pitch: player.pitch + (random() - 0.5) * spread)
        let eye = eyePosition
        let cameraHit = traceShot(origin: eye, direction: direction)
        let desiredPoint = eye + direction * cameraHit.distance
        let muzzle = eye + SIMD3(cos(player.yaw) * 0.22, -0.17, -sin(player.yaw) * 0.22) + direction * 0.5
        let barrelOffset = muzzle - eye, barrelLength = simd_length(barrelOffset)
        let barrelHit = wallHit(origin: eye, direction: barrelOffset / barrelLength, maximumDistance: barrelLength)
        var hit: RayHit
        var hitPoint: SIMD3<Float>
        if barrelHit.obstacleIndex != nil || barrelHit.hitGround {
            hit = barrelHit; hitPoint = eye + barrelOffset / barrelLength * hit.distance
        } else {
            let offset = desiredPoint - muzzle
            let corrected = simd_length_squared(offset) > 0.000_001 ? simd_normalize(offset) : direction
            hit = traceShot(origin: muzzle, direction: corrected)
            hitPoint = muzzle + corrected * hit.distance
        }
        let surfaceImpact = makeSurfaceImpact(for: hit, at: hitPoint)
        let damage = activeWeapon.damage * (hit.headshot ? 2.4 : 1)
        if let index = hit.enemyIndex { damageEnemy(index: index, amount: damage, headshot: hit.headshot, from: eye) }
        if let index = hit.obstacleIndex { damageCover(index: index, amount: activeWeapon.damage) }
        emit(GameEvent(kind: .shot, position: muzzle, endPosition: hitPoint,
                       amount: hit.enemyIndex != nil ? damage : 0, headshot: hit.headshot, weapon: activeWeapon,
                       surfaceImpact: surfaceImpact))
        return true
    }

    func damageEnemy(index: Int, amount: Float, headshot: Bool = false, from source: SIMD3<Float>? = nil) {
        guard enemies.indices.contains(index), enemies[index].health > 0, amount.isFinite, amount > 0 else { return }
        let id = enemies[index].id
        enemies[index].health = max(0, enemies[index].health - amount)
        if var brain = brains[id] {
            investigate(source ?? player.position, enemy: &enemies[index], brain: &brain)
            brain.hurt = 0.3; brain.suppression = 1.8
            brains[id] = brain
        }
        if enemies[index].health <= 0 {
            kills += 1; let points = headshot ? 150 : 100; score += points
            enemies[index].deathTime = elapsed; enemies[index].windup = 0
            enemies[index].isMoving = false; enemies[index].isRunning = false
            emit(GameEvent(kind: .kill, position: enemies[index].position, amount: Float(points), headshot: headshot, id: id))
            if kills.isMultiple(of: 3) {
                var drop = groundedPoint(enemies[index].position)
                for box in obstacles where !box.destroyed && box.maximum.y <= enemies[index].position.y + 0.05 {
                    if drop.x >= box.minimum.x && drop.x <= box.maximum.x && drop.z >= box.minimum.z && drop.z <= box.maximum.z {
                        drop.y = max(drop.y, box.maximum.y)
                    }
                }
                supplies.append(SupplyState(id: allocateID(), position: drop))
            }
        }
    }

    private func applyCoverDamage(index: Int, amount: Float) -> SIMD3<Float>? {
        guard obstacles.indices.contains(index), !obstacles[index].destroyed,
              obstacles[index].health.isFinite, amount.isFinite, amount > 0 else { return nil }
        obstacles[index].health = max(0, obstacles[index].health - amount)
        guard obstacles[index].health <= 0 else { return nil }
        obstacles[index].destroyed = true; score += 25; navigationDirty = true
        let box = obstacles[index]
        pendingCoverDebris.append(box)
        emit(GameEvent(kind: .coverDestroyed, position: box.position + SIMD3(0, box.size.y * 0.5, 0), id: box.id))
        return box.kind == .barrel ? box.position + SIMD3(0, 0.55, 0) : nil
    }

    func damageCover(index: Int, amount: Float) {
        if let barrel = applyCoverDamage(index: index, amount: amount) { explode(at: barrel) }
        else { finishCoverDestruction() }
    }

    /// Called only when the current damage/blast transaction is complete.
    /// Newly collapsed concrete must not occlude its own chain explosion.
    private func finishCoverDestruction() {
        for box in pendingCoverDebris {
            let lifetime: Double
            switch box.kind {
            case .crate: lifetime = 12
            case .barrel: lifetime = 8
            case .container: lifetime = 15
            case .barrier: lifetime = 20
            case .bunker: continue
            }
            if coverDebris.count >= CoverDebrisState.maximumCount { removeCoverDebris(at: 0) }
            var solidID: Int?
            // A 0.5m block intersects the AI's 0.45m jump probe. Short decorative
            // heaps would block feet while remaining invisible to that probe.
            if box.kind == .barrier && box.size.y >= 0.5 {
                let id = allocateID()
                var base = box.position
                if terrain != .flat && abs(base.y - terrain.height(x: base.x, z: base.z)) <= 0.05 {
                    // Every triangle under this footprint is bounded by these
                    // grid vertices. Extend only grounded remains, once, so a
                    // horizontal rest cannot float above a descending slope.
                    // Raised roof cover must retain its original support level.
                    for z in Int(floor(box.minimum.z))...Int(ceil(box.maximum.z)) {
                        for x in Int(floor(box.minimum.x))...Int(ceil(box.maximum.x)) {
                            base.y = min(base.y, terrain.height(x: Float(x), z: Float(z)))
                        }
                    }
                }
                var solid = Obstacle(id: id, kind: .barrier, position: base,
                                     size: SIMD3(box.size.x, box.position.y + 0.5 - base.y, box.size.z))
                solid.health = .infinity
                obstacles.append(solid); solidID = id; navigationDirty = true
            }
            coverDebris.append(CoverDebrisState(sourceObstacleID: box.id, kind: box.kind, position: box.position,
                                               size: box.size, createdAt: elapsed, lifetime: lifetime, solidObstacleID: solidID))
        }
        pendingCoverDebris.removeAll(keepingCapacity: true)
    }

    private func removeCoverDebris(at index: Int) {
        let debris = coverDebris.remove(at: index)
        if let id = debris.solidObstacleID {
            obstacles.removeAll { $0.id == id }
            navigationDirty = true
        }
    }

    private func updateCoverDebris() {
        for index in coverDebris.indices.reversed() where elapsed - coverDebris[index].createdAt >= coverDebris[index].lifetime {
            removeCoverDebris(at: index)
        }
    }

    func damagePlayer(amount: Float, from: SIMD3<Float>) {
        guard state == .active, amount.isFinite, amount > 0 else { return }
        player.health = max(0, player.health - amount); player.lastHit = elapsed
        emit(GameEvent(kind: .damage, position: from, endPosition: eyePosition, amount: amount))
        if player.health <= 0 { state = .lost; isSprinting = false; emit(GameEvent(kind: .lose, position: player.position)) }
    }

    @discardableResult public func throwGrenade() -> Bool {
        guard state == .active, climbing == nil, grenadeCount > 0, grenadeCooldown <= 0 else { return false }
        let direction = viewDirection(yaw: player.yaw, pitch: clamp(player.pitch + 0.22, -0.9, 1.2))
        let grenade = GrenadeState(id: allocateID(), position: eyePosition, velocity: direction * 16 + SIMD3(0, 2.5, 0))
        grenades.append(grenade); grenadeCount -= 1; grenadeCooldown = 0.7
        emit(GameEvent(kind: .throwGrenade, position: grenade.position, id: grenade.id))
        return true
    }

    func explode(at position: SIMD3<Float>) {
        // Iterative queue prevents deep recursion and ensures every barrel detonates once.
        var pending = [position], next = 0
        while next < pending.count {
            let center = pending[next] + SIMD3<Float>(0, 0.18, 0); next += 1
            hearNoise(at: center, radius: 30)
            for index in enemies.indices where enemies[index].health > 0 {
                let target = EnemyPose(enemies[index]).bodyCenter
                let distance = simd_distance(center, target)
                if distance < 8 && clearLine(center, target) { damageEnemy(index: index, amount: 220 * (1 - distance / 8), from: center) }
            }
            let distance = simd_distance(center, eyePosition)
            if distance < 8 && clearLine(center, eyePosition) { damagePlayer(amount: 145 * (1 - distance / 8), from: center) }
            // Evaluate all cover occlusion before applying this blast's destruction.
            var hits: [(Int, Float)] = []
            for index in obstacles.indices where !obstacles[index].destroyed && obstacles[index].health.isFinite {
                let box = obstacles[index]
                let target = simd_clamp(center, box.minimum, box.maximum)
                let distance = simd_distance(center, target)
                if distance < 8 && clearLine(center, target, excludingObstacle: index) { hits.append((index, 850 * (1 - distance / 8))) }
            }
            for (index, amount) in hits {
                if let barrel = applyCoverDamage(index: index, amount: amount) { pending.append(barrel) }
            }
            emit(GameEvent(kind: .explosion, position: center, amount: 8))
        }
        finishCoverDestruction()
    }

    private func allocateID() -> Int { defer { nextID += 1 }; return nextID }

    public func step(deltaTime: Double, input: GameInput) {
        guard deltaTime.isFinite, deltaTime > 0, state == .active else { return }
        // Suspend/resume never becomes seconds of catch-up work or a physics tunnel.
        accumulator += min(deltaTime, 0.15)
        let fixedDelta = 1.0 / 120.0
        while accumulator + 1e-12 >= fixedDelta {
            tick(Float(fixedDelta), input: input)
            accumulator -= fixedDelta
            if state != .active { accumulator = 0; break }
        }
        accumulator = max(0, accumulator)
    }

    private func tick(_ dt: Float, input: GameInput) {
        guard state == .active else { return }
        elapsed += 1.0 / 120.0
        updateCoverDebris()
        updatePlayer(dt, input: input)
        for kind in WeaponKind.allCases {
            guard var weapon = weapons[kind] else { continue }
            weapon.cooldown = max(0, weapon.cooldown - dt)
            if weapon.reloadRemaining > 0 {
                weapon.reloadRemaining = max(0, weapon.reloadRemaining - dt)
                if weapon.reloadRemaining == 0 {
                    let amount = min(kind.capacity - weapon.ammo, weapon.reserve)
                    weapon.ammo += amount; weapon.reserve -= amount
                }
            }
            weapons[kind] = weapon
        }
        grenadeCooldown = max(0, grenadeCooldown - dt)
        if input.fire { fire() }
        updateGrenades(dt)
        guard state == .active else { return }
        updateEnemies(dt)
        guard state == .active else { return }
        collectSupplies()
        updateReinforcementRetries(dt)
        if missionKind == .waves { updateWaves(dt) }
        else { updateMission(input: input) }
    }

    private func updatePlayer(_ dt: Float, input: GameInput) {
        if input.yaw.isFinite { player.yaw = input.yaw.truncatingRemainder(dividingBy: .pi * 2) }
        if input.pitch.isFinite { player.pitch = clamp(input.pitch, -1.45, 1.45) }
        isAiming = input.aim && (weapons[activeWeapon]?.reloadRemaining ?? 0) <= 0 && climbing == nil
        let forward = input.moveForward.isFinite ? clamp(input.moveForward, -1, 1) : 0
        let right = input.moveRight.isFinite ? clamp(input.moveRight, -1, 1) : 0
        let length = sqrt(forward * forward + right * right)
        if player.stamina <= 1 { player.exhausted = true }
        if player.exhausted && player.stamina >= 25 { player.exhausted = false }
        isSprinting = input.sprint && !player.prone && !isAiming && !player.exhausted &&
            player.stamina > 1 && forward > 0 && length > 0 && climbing == nil
        let speed: Float = player.prone ? 1.65 : isSprinting ? 7.5 : isAiming ? 2.8 : 4.7
        let before = player.position
        if length > 0 && climbing == nil {
            let denominator = max(1, length)
            let delta = SIMD3((-sin(player.yaw) * forward + cos(player.yaw) * right) / denominator, 0,
                              (-cos(player.yaw) * forward - sin(player.yaw) * right) / denominator) * speed * dt
            player.position = moved(player.position, delta: delta, height: player.height, grounded: player.grounded)
        }
        isMoving = horizontalDistance(before, player.position) > 0.0001
        player.height += ((player.prone ? 0.57 : 1.72) - player.height) * min(1, dt * 15)
        player.stamina = clamp(player.stamina + (isSprinting ? -19 : 15) * dt, 0, 100)
        if var climb = climbing {
            if obstacles.contains(where: { $0.id == climb.obstacleID && !$0.destroyed }) {
                climb.progress = min(0.75, climb.progress + dt)
                let t = climb.progress / 0.75, horizontal = clamp((t - 0.3) / 0.7, 0, 1)
                player.position.x = climb.from.x + (climb.to.x - climb.from.x) * horizontal
                player.position.z = climb.from.z + (climb.to.z - climb.from.z) * horizontal
                player.position.y = climb.from.y + (climb.to.y - climb.from.y + 0.12) * sin(min(1, t * 1.6) * .pi / 2)
                player.grounded = false
                if t >= 1 { player.position = climb.to; climbing = nil } else { climbing = climb }
            } else { climbing = nil }
        }
        let oldY = player.position.y
        if climbing == nil {
            player.verticalVelocity -= 17 * dt
            player.position.y += player.verticalVelocity * dt
            var floor = terrain.height(x: player.position.x, z: player.position.z)
            for box in obstacles where !box.destroyed {
                let low = box.minimum, high = box.maximum
                if player.position.x + 0.28 > low.x && player.position.x - 0.28 < high.x &&
                    player.position.z + 0.28 > low.z && player.position.z - 0.28 < high.z && oldY >= high.y - 0.04 {
                    floor = max(floor, high.y)
                }
                // Stop upward motion under overhanging level geometry.
                if player.verticalVelocity > 0 && player.position.x + 0.28 > low.x && player.position.x - 0.28 < high.x &&
                    player.position.z + 0.28 > low.z && player.position.z - 0.28 < high.z &&
                    oldY + player.height <= low.y && player.position.y + player.height > low.y {
                    player.position.y = low.y - player.height; player.verticalVelocity = 0
                }
            }
            if player.position.y <= floor {
                if !player.grounded && player.verticalVelocity < -4 { emit(GameEvent(kind: .land, position: player.position)) }
                player.position.y = floor; player.verticalVelocity = 0; player.grounded = true
            } else { player.grounded = false }
        }
        if elapsed - player.lastHit > 5.5 { player.health = min(100, player.health + dt * 8) }
    }

    private func updateGrenades(_ dt: Float) {
        var index = 0
        while index < grenades.count {
            var grenade = grenades[index]
            grenade.fuse -= dt; grenade.velocity.y -= 13 * dt
            var remaining = dt
            for _ in 0..<3 {
                let speed = simd_length(grenade.velocity)
                if speed < 0.0001 || remaining < 0.0001 { break }
                let direction = grenade.velocity / speed
                let hit = wallHit(origin: grenade.position, direction: direction, maximumDistance: speed * remaining, padding: 0.09)
                grenade.position += direction * max(0, hit.distance - 0.002)
                if hit.obstacleIndex == nil && !hit.hitGround { break }
                remaining -= hit.distance / speed
                grenade.velocity = (grenade.velocity - 1.5 * simd_dot(grenade.velocity, hit.normal) * hit.normal) * 0.72
                grenade.position += hit.normal * 0.004
            }
            if grenade.position.x < -37.91 || grenade.position.x > 37.91 {
                grenade.position.x = clamp(grenade.position.x, -37.91, 37.91); grenade.velocity.x *= -0.45
            }
            if grenade.position.z < -41.91 || grenade.position.z > 41.91 {
                grenade.position.z = clamp(grenade.position.z, -41.91, 41.91); grenade.velocity.z *= -0.45
            }
            grenade.position.y = max(terrain.height(x: grenade.position.x, z: grenade.position.z) + 0.09, grenade.position.y)
            if grenade.fuse <= 0 {
                grenades.remove(at: index); explode(at: grenade.position)
            } else { grenades[index] = grenade; index += 1 }
        }
    }

    private func collectSupplies() {
        supplies.removeAll { pickup in
            guard simd_distance(player.position, pickup.position) < 1.8 else { return false }
            if var rifle = weapons[.rifle] { rifle.reserve = min(300, rifle.reserve + 45); weapons[.rifle] = rifle }
            if var sniper = weapons[.sniper] { sniper.reserve = min(50, sniper.reserve + 5); weapons[.sniper] = sniper }
            emit(GameEvent(kind: .supply, position: pickup.position, id: pickup.id))
            return true
        }
    }

    private func updateReinforcementRetries(_ dt: Float) {
        if pendingReinforcements > 0 {
            reinforcementTimer -= dt
            if reinforcementTimer <= 0 { deployReinforcements(); reinforcementTimer = 0.5 }
        }
    }

    private func updateWaves(_ dt: Float) {
        guard remainingEnemies == 0 else { return }
        if wave < 3 {
            if intermission <= 0 {
                intermission = 7; player.health = min(100, player.health + 25)
                grenadeCount = min(4, grenadeCount + 2)
                if var rifle = weapons[.rifle] { rifle.reserve = min(300, rifle.reserve + 60); weapons[.rifle] = rifle }
                if var sniper = weapons[.sniper] { sniper.reserve = min(50, sniper.reserve + 10); weapons[.sniper] = sniper }
                emit(GameEvent(kind: .waveCleared, position: player.position, count: wave))
            }
            intermission = max(0, intermission - dt)
            if intermission == 0 { spawnWave() }
        } else {
            if !extractionAnnounced {
                extractionAnnounced = true
                emit(GameEvent(kind: .extractionUnlocked, position: extractionPosition, count: wave))
            }
            extractionProgress = insideExtraction ? min(3, extractionProgress + dt) : 0
            if extractionProgress >= 3 {
                state = .won; score += 500; isSprinting = false
                emit(GameEvent(kind: .win, position: player.position, amount: 500))
            }
        }
    }

    /// Invoked after all damage for the fixed step, so dying on the final
    /// objective tick cannot overwrite the loss with a win.
    private func updateMission(input: GameInput) {
        guard state == .active else { return }
        interactionHeld = input.interact
        if !missionStarted {
            missionStarted = true
            emit(GameEvent(kind: .missionPhaseChanged, position: missionStatus.objectivePosition ?? player.position,
                           missionPhase: missionPhase))
            queueMissionReinforcements(missionKind == .recoverData ? 4 : 3)
        }
        switch missionPhase {
        case .collectData, .activateRadio:
            missionProgressTicks = missionInteractionAvailable && input.interact ? missionProgressTicks + 1 : 0
            let required = missionPhase == .collectData ? 96 : 120
            if missionProgressTicks >= required {
                if missionPhase == .collectData {
                    changeMissionPhase(to: .extract)
                    queueMissionReinforcements(3)
                } else {
                    changeMissionPhase(to: .holdRadio)
                    queueMissionReinforcements(2)
                }
            }
        case .extract:
            missionProgressTicks = insideExtraction ? min(360, missionProgressTicks + 1) : 0
            extractionProgress = Float(missionProgressTicks)/120
            if missionProgressTicks == 360 { finishObjectiveMission() }
        case .holdRadio:
            guard groundedAtRadio, horizontalDistance(player.position, map.radioSite) <= 5, !radioContested else { return }
            missionProgressTicks = min(5400, missionProgressTicks + 1)
            if missionProgressTicks == 1800 || missionProgressTicks == 3600 { queueMissionReinforcements(2) }
            if missionProgressTicks == 5400 { finishObjectiveMission() }
        case .waves, .completed:
            break
        }
    }

    private func changeMissionPhase(to next: MissionPhase) {
        guard missionPhase != next else { return }
        missionPhase = next; missionProgressTicks = 0
        emit(GameEvent(kind: .missionPhaseChanged, position: missionStatus.objectivePosition ?? player.position,
                       missionPhase: next))
    }

    private func finishObjectiveMission() {
        guard state == .active else { return }
        state = .won; score += 500; isSprinting = false
        changeMissionPhase(to: .completed)
        emit(GameEvent(kind: .win, position: player.position, amount: 500))
    }

    private func queueMissionReinforcements(_ count: Int) {
        pendingReinforcements += count
        reinforcementTimer = 0.5
        deployReinforcements()
    }

    func spawnWave() {
        guard missionKind == .waves, wave < 3, state == .active, remainingEnemies == 0 else { return }
        wave += 1; intermission = 0
        enemies.removeAll { $0.health <= 0 && elapsed - ($0.deathTime ?? 0) >= 5 }
        let liveIDs = Set(enemies.map(\.id)); brains = brains.filter { liveIDs.contains($0.key) }
        pendingReinforcements = 3 + wave * 2; deployedThisWave = 0
        reinforcementCursor = 0; reinforcementTimer = 0.5
        emit(GameEvent(kind: .waveStarted, amount: Float(pendingReinforcements), count: wave))
        deployReinforcements()
    }

    private func deployReinforcements() {
        guard pendingReinforcements > 0, state == .active else { return }
        rebuildNavigationIfNeeded()
        // The closest walkable ground cell also handles players on container roofs.
        var combatCell: Int?, nearest: Float = .infinity
        for index in navigation.indices where navigationComponents[index] > 0 {
            let point = navigationPoint(index)
            let offset = point - player.position, distance = offset.x * offset.x + offset.z * offset.z
            if distance < nearest && !blocked(point, height: 2, radius: 0.45) { nearest = distance; combatCell = index }
        }
        guard let combatCell else { return }
        let component = navigationComponents[combatCell], candidates = map.spawnCandidates
        // One bounded pass per retry; no random relaxation of the safety rules.
        for attempt in 0..<candidates.count {
            guard pendingReinforcements > 0 else { break }
            let position = groundedPoint(candidates[(reinforcementCursor + attempt) % candidates.count])
            guard horizontalDistance(position, player.position) >= 14,
                  !blocked(position, height: 2, radius: 0.6),
                  terrain.normal(x: position.x, z: position.z).y >= 0.72,
                  !enemies.contains(where: { $0.health > 0 && horizontalDistance($0.position, position) < 1.6 }),
                  let cell = navigationCell(at: position), navigationComponents[cell] == component,
                  reinforcementIsHidden(at: position) else { continue }
            let offset = deployedThisWave
            var enemy = EnemyState(id: allocateID(), position: position, health: missionKind == .waves ? Float(90 + wave * 10) : 100)
            let staging: SIMD3<Float>
            if missionKind == .waves {
                staging = groundedPoint(map.waveStaging[offset % map.waveStaging.count])
            } else {
                // Authored objectives are public tactical destinations. Arrivals
                // do not acquire knowledge of an unseen player's live position.
                let anchor = missionKind == .secureRadio ? map.radioSite : missionPhase == .collectData ? map.dataSite : map.extraction
                let angle = Float(offset) * 2.39996
                let candidate = groundedPoint(anchor + SIMD3(sin(angle)*1.8,0,cos(angle)*1.8))
                staging = !blocked(candidate, height: 1.96, radius: 0.4) ? candidate : groundedPoint(anchor)
            }
            enemy.yaw = atan2(staging.x - position.x, staging.z - position.z)
            enemies.append(enemy)
            // Reinforcements approach a fixed staging area, not an unseen player.
            var brain = EnemyBrain(cooldown: 2 + Float(offset) * 0.35, sightTimer: Float(offset % 5) * 0.02,
                                   patrolAnchor: staging, patrolYaw: enemy.yaw)
            brain.patrolGoal = staging; brain.watchTimer = 0; brain.arriving = true
            brain.side = offset.isMultiple(of: 2) ? -1 : 1
            brains[enemy.id] = brain
            pendingReinforcements -= 1; deployedThisWave += 1
            emit(GameEvent(kind: .reinforcementsArrived, position: position, endPosition: player.position,
                           amount: 1, id: enemy.id, count: wave))
        }
        reinforcementCursor = (reinforcementCursor + 7) % candidates.count
    }

    /// Conservative whole-body visibility: outside the camera's rear plane, or
    /// inside the shadow volume of one solid convex box. Checking all corners
    /// against the same occluder cannot hide a head behind a feet-only ray.
    func reinforcementIsHidden(at position: SIMD3<Float>) -> Bool {
        let center = position + SIMD3<Float>(0, 1.03, 0), extent = SIMD3<Float>(0.85, 1.02, 0.85)
        let facing = viewDirection(yaw: player.yaw, pitch: player.pitch)
        let projectedExtent = abs(facing.x) * extent.x + abs(facing.y) * extent.y + abs(facing.z) * extent.z
        if simd_dot(center - eyePosition, facing) + projectedExtent < -0.1 { return true }
        for box in obstacles where !box.destroyed {
            var hidden = true
            for corner in 0..<8 {
                let point = center + SIMD3<Float>(corner & 1 == 0 ? -extent.x : extent.x,
                                                  corner & 2 == 0 ? -extent.y : extent.y,
                                                  corner & 4 == 0 ? -extent.z : extent.z)
                let offset = point - eyePosition, length = simd_length(offset)
                if length < 0.01 { hidden = false; break }
                guard let hit = rayBox(origin: eyePosition, direction: offset / length,
                                       minimum: box.minimum, maximum: box.maximum), hit.distance < length - 0.05 else {
                    hidden = false; break
                }
            }
            if hidden { return true }
        }
        return false
    }
}

private struct ClimbState {
    let from: SIMD3<Float>
    let to: SIMD3<Float>
    let obstacleID: Int
    var progress: Float = 0
}

private struct EnemyBrain {
    var cooldown: Float
    var sightTimer: Float
    var hurt: Float = 0
    var alert = false
    var lastKnown: SIMD3<Float>?
    var visualContact = false
    var searchAge: Float = 0
    var searchTimer: Float = 0
    var searchingInPlace = false
    var stuckTime: Float = 0
    var patrolAnchor: SIMD3<Float>
    var patrolYaw: Float
    var patrolGoal: SIMD3<Float>?
    var patrolIndex = 0
    var watchTimer: Float = 2.2
    var arriving = false
    var path: [SIMD3<Float>] = []
    var pathIndex = 0
    var pathTimer: Float = 0
    var side: Float = 1
    var coverGoal: SIMD3<Float>?
    var coverTimer: Float = 0
    var coverCooldown: Float = 0
    var coverDecisionTimer: Float = 0.6
    var suppression: Float = 0
    var holdTimer: Float = 0
    var repositionTimer: Float = 0
    var jumpCooldown: Float = 0
}

extension CombatSimulation {
    private func gridKey(_ position: SIMD3<Float>) -> Int {
        let x = clamp(Int(((position.x - map.minimum.x) / navSpacing).rounded()), 0, navWidth - 1)
        let z = clamp(Int(((position.z - map.minimum.z) / navSpacing).rounded()), 0, navDepth - 1)
        return z * navWidth + x
    }

    private func navigationPoint(_ index: Int) -> SIMD3<Float> {
        SIMD3(map.minimum.x + Float(index % navWidth) * navSpacing, navigationHeights[index], map.minimum.z + Float(index / navWidth) * navSpacing)
    }

    private func navigationSegmentIsOpen(from: SIMD3<Float>, to: SIMD3<Float>) -> Bool {
        guard abs(from.y - to.y) <= 1.6 else { return false }
        let middle = (from + to) * 0.5
        guard terrain.normal(x: middle.x, z: middle.z).y >= 0.72 else { return false }
        let offset = to - from, length = simd_length(offset)
        if length < 0.001 { return true }
        // Sweep the standing body above the deliberately jumpable 1.12m layer.
        // Unlike testing only raster cells this also catches walls between cells.
        for box in obstacles where !box.destroyed {
            if let hit = rayBox(origin: from + SIMD3(0, 1.09, 0), direction: offset / length,
                                minimum: box.minimum - SIMD3(0.48, 0.87, 0.48),
                                maximum: box.maximum + SIMD3(0.48, -0.025, 0.48)), hit.distance <= length {
                return false
            }
        }
        return true
    }

    private func rebuildNavigationIfNeeded() {
        guard navigationDirty else { return }
        for index in navigation.indices {
            let point = groundedPoint(SIMD3(map.minimum.x + Float(index % navWidth) * navSpacing, 0, map.minimum.z + Float(index / navWidth) * navSpacing))
            navigationHeights[index] = point.y
            navigation[index] = blocked(point + SIMD3(0, 1.09, 0), height: 0.87, radius: 0.48) ||
                terrain.normal(x: point.x, z: point.z).y < 0.72
            navigationLinks[index] = 0; navigationComponents[index] = 0
        }
        for index in navigation.indices where !navigation[index] {
            for (offset, forward, backward) in [(1, UInt8(2), UInt8(8)), (navWidth, UInt8(4), UInt8(1))] {
                let next = index + offset
                guard next < navigation.count, (offset != 1 || index % navWidth < navWidth - 1), !navigation[next],
                      navigationSegmentIsOpen(from: navigationPoint(index), to: navigationPoint(next)) else { continue }
                navigationLinks[index] |= forward; navigationLinks[next] |= backward
            }
        }
        var component = 0
        for start in navigation.indices where !navigation[start] && navigationComponents[start] == 0 {
            component += 1; searchQueue.removeAll(keepingCapacity: true)
            searchQueue.append(start); navigationComponents[start] = component
            var cursor = 0
            while cursor < searchQueue.count {
                let current = searchQueue[cursor]; cursor += 1
                for (bit, offset) in [(UInt8(1), -navWidth), (UInt8(2), 1), (UInt8(4), navWidth), (UInt8(8), -1)] {
                    guard navigationLinks[current] & bit != 0 else { continue }
                    let next = current + offset
                    if navigationComponents[next] == 0 { navigationComponents[next] = component; searchQueue.append(next) }
                }
            }
        }
        navigationDirty = false
    }

    private func navigationCell(at position: SIMD3<Float>) -> Int? {
        let point = groundedPoint(position), key = gridKey(point)
        guard !blocked(point, height: 1.96, radius: 0.38), terrain.normal(x: point.x, z: point.z).y >= 0.72 else { return nil }
        var result: Int?, best: Float = .infinity
        for dz in -1...1 { for dx in -1...1 {
            let x = key % navWidth + dx, z = key / navWidth + dz
            guard x >= 0, x < navWidth, z >= 0, z < navDepth else { continue }
            let index = z * navWidth + x
            guard !navigation[index] else { continue }
            let candidate = navigationPoint(index), distance = simd_distance_squared(point, candidate)
            if distance < best && navigationSegmentIsOpen(from: point, to: candidate) { best = distance; result = index }
        } }
        return result
    }

    /// Unlike findPath's useful partial routes, this proves both endpoints share
    /// a connected walkable region, including the swept links between grid cells.
    func hasReachableRoute(from: SIMD3<Float>, to: SIMD3<Float>) -> Bool {
        rebuildNavigationIfNeeded()
        guard let start = navigationCell(at: from), let end = navigationCell(at: to) else { return false }
        return navigationComponents[start] == navigationComponents[end]
    }

    func findPath(from: SIMD3<Float>, to: SIMD3<Float>) -> [SIMD3<Float>] {
        rebuildNavigationIfNeeded()
        let start = navigationCell(at: from) ?? gridKey(from), end = gridKey(to)
        searchGeneration &+= 1
        if searchGeneration == 0 { visited = [UInt32](repeating: 0, count: navWidth * navDepth); searchGeneration = 1 }
        searchQueue.removeAll(keepingCapacity: true); searchQueue.append(start); visited[start] = searchGeneration
        var found = start, best = Int.max, index = 0
        while index < searchQueue.count {
            let current = searchQueue[index]; index += 1
            let x = current % navWidth, z = current / navWidth
            let distance = abs(x - end % navWidth) + abs(z - end / navWidth)
            if distance < best { found = current; best = distance }
            if distance == 0 { break }
            for (bit, offset) in [(UInt8(1), -navWidth), (UInt8(2), 1), (UInt8(4), navWidth), (UInt8(8), -1)] {
                guard navigationLinks[current] & bit != 0 else { continue }
                let next = current + offset
                if visited[next] == searchGeneration { continue }
                visited[next] = searchGeneration; previous[next] = current; searchQueue.append(next)
            }
        }
        var result: [SIMD3<Float>] = [], current = found
        while current != start {
            result.append(SIMD3(map.minimum.x + Float(current % navWidth) * navSpacing, navigationHeights[current], map.minimum.z + Float(current / navWidth) * navSpacing))
            current = previous[current]
        }
        if let first = result.last, !navigationSegmentIsOpen(from: groundedPoint(from), to: first) {
            // Keep the proven connector when a replacement start cell is needed
            // beside cover; jumping straight to its neighbour could cut a corner.
            result.append(navigationPoint(start))
        }
        return result.reversed()
    }

    private func nearestCover(for position: SIMD3<Float>, threat: SIMD3<Float>) -> SIMD3<Float>? {
        var result: SIMD3<Float>?, best: Float = 13
        for box in obstacles where !box.destroyed && box.size.y > 0.8 {
            let candidates = [SIMD3(box.minimum.x - 0.75, 0, box.position.z),
                              SIMD3(box.maximum.x + 0.75, 0, box.position.z),
                              SIMD3(box.position.x, 0, box.minimum.z - 0.75),
                              SIMD3(box.position.x, 0, box.maximum.z + 0.75)]
            for raw in candidates {
                let candidate = groundedPoint(raw), distance = horizontalDistance(position, candidate)
                if distance < best && !blocked(candidate, height: 1.96, radius: 0.4) &&
                    terrain.normal(x: candidate.x, z: candidate.z).y >= 0.72 &&
                    !clearLine(candidate + SIMD3(0, 0.98, 0), threat) {
                    result = candidate; best = distance
                }
            }
        }
        return result
    }

    /// Solve the offset shoulder frame rather than aiming from the body's centre.
    private func aim(_ enemy: inout EnemyState, at target: SIMD3<Float>) {
        for _ in 0..<4 {
            let offset = target - EnemyPose(enemy).gunRoot
            let horizontal = max(0.001, sqrt(offset.x * offset.x + offset.z * offset.z))
            enemy.yaw = atan2(offset.x, offset.z)
            enemy.aimPitch = clamp(atan2(offset.y, horizontal), -1.45, 1.45)
        }
    }

    private func startUsefulJump(_ enemy: inout EnemyState, brain: inout EnemyBrain, toward target: SIMD3<Float>) {
        guard enemy.grounded, brain.jumpCooldown <= 0, enemy.crouchAmount < 0.35 else { return }
        let horizontal = SIMD3<Float>(target.x - enemy.position.x, 0, target.z - enemy.position.z)
        guard simd_length_squared(horizontal) > 0.16 else { return }
        let direction = simd_normalize(horizontal)
        let landing = groundedPoint(enemy.position + direction * 2.8)
        guard abs(landing.y - enemy.position.y) < 0.75,
              !blocked(landing, height: 1.96, radius: 0.38),
              terrain.normal(x: landing.x, z: landing.z).y >= 0.72 else { return }
        var useful = false
        let lowProbe = enemy.position + SIMD3(0, 0.45, 0)
        for box in obstacles where !box.destroyed && box.maximum.y - enemy.position.y > 0.3 && box.maximum.y - enemy.position.y <= 1.12 {
            if let hit = rayBox(origin: lowProbe, direction: direction,
                                minimum: box.minimum - SIMD3(0.38, 0, 0.38), maximum: box.maximum + SIMD3(0.38, 0, 0.38)),
               hit.distance < 1.25 {
                useful = true; break
            }
        }
        let middle = groundedPoint(enemy.position + direction * 1.3)
        if middle.y < enemy.position.y - 0.4 && landing.y > middle.y + 0.3 { useful = true }
        if useful {
            enemy.verticalVelocity = 6.6; enemy.grounded = false; enemy.crouchAmount = 0
            brain.jumpCooldown = 4.5 + Float(enemy.id % 4) * 0.65
        }
    }

    private func applyGravity(_ enemy: inout EnemyState, dt: Float) {
        let oldY = enemy.position.y
        enemy.verticalVelocity -= 17 * dt; enemy.position.y += enemy.verticalVelocity * dt
        var floor = terrain.height(x: enemy.position.x, z: enemy.position.z)
        for box in obstacles where !box.destroyed {
            let low = box.minimum, high = box.maximum
            guard enemy.position.x + 0.3 > low.x, enemy.position.x - 0.3 < high.x,
                  enemy.position.z + 0.3 > low.z, enemy.position.z - 0.3 < high.z else { continue }
            if oldY >= high.y - 0.04 { floor = max(floor, high.y) }
            let height = EnemyPose(enemy).totalHeight
            if enemy.verticalVelocity > 0 && oldY + height <= low.y && enemy.position.y + height > low.y {
                enemy.position.y = low.y - height; enemy.verticalVelocity = 0
            }
        }
        if enemy.position.y <= floor {
            enemy.position.y = floor; enemy.verticalVelocity = 0; enemy.grounded = true
        } else { enemy.grounded = false }
    }

    private func investigate(_ source: SIMD3<Float>, enemy: inout EnemyState, brain: inout EnemyBrain) {
        guard !enemy.seesPlayer else { return }
        let target = groundedPoint(source)
        // Automatic fire at one location must not trigger a BFS for every bullet.
        if enemy.awareness == .watching || brain.searchingInPlace ||
            brain.lastKnown.map({ horizontalDistance($0, target) > 2 }) != false { brain.pathTimer = 0 }
        enemy.awareness = .investigating; enemy.windup = 0
        brain.alert = true; brain.lastKnown = target
        brain.searchAge = 0; brain.searchTimer = 0; brain.searchingInPlace = false
        brain.stuckTime = 0; brain.patrolGoal = nil
    }

    private func hearNoise(at source: SIMD3<Float>, radius: Float) {
        for index in enemies.indices where enemies[index].health > 0 && horizontalDistance(enemies[index].position, source) < radius {
            guard var brain = brains[enemies[index].id] else { continue }
            investigate(source, enemy: &enemies[index], brain: &brain)
            brains[enemies[index].id] = brain
        }
    }

    private func updateAwareness(_ enemy: inout EnemyState, brain: inout EnemyBrain, dt: Float) {
        if brain.sightTimer <= 0 {
            let offset = eyePosition - EnemyPose(enemy).eyePosition
            let horizontal = sqrt(offset.x * offset.x + offset.z * offset.z)
            let forward = SIMD2<Float>(sin(enemy.yaw), cos(enemy.yaw))
            // Local +Z is forward. A cheap 120-degree cone test precedes raycasts.
            let inCone = horizontal < 0.05 || simd_dot(forward, SIMD2(offset.x, offset.z)) >= horizontal * 0.5
            brain.visualContact = horizontal < 48 && inCone && clearLine(EnemyPose(enemy).eyePosition, eyePosition)
            brain.sightTimer = 0.1
            if brain.visualContact {
                let reaction: Float = (difficulty == .easy ? 0.8 : difficulty == .hard ? 0.4 : 0.6) *
                    (horizontal < 8 ? 0.7 : 1) * (player.prone ? 1.25 : 1)
                let recognition = enemy.detectionProgress >= 1 ? 1 : vegetationRecognitionFactor(
                    from: EnemyPose(enemy).eyePosition, eyeLineIsClear: true)
                enemy.detectionProgress = min(1, enemy.detectionProgress + 0.1 / reaction * recognition)
                if enemy.detectionProgress >= 1 {
                    if enemy.awareness != .engaged {
                        emit(GameEvent(kind: .enemyAlert, position: enemy.position, id: enemy.id))
                    }
                    enemy.awareness = .engaged; enemy.seesPlayer = true
                    brain.lastKnown = player.position; brain.searchAge = 0; brain.searchingInPlace = false
                    brain.stuckTime = 0
                }
            } else {
                enemy.detectionProgress = max(0, enemy.detectionProgress - 0.2)
                if enemy.seesPlayer || enemy.awareness == .engaged {
                    enemy.awareness = .searching; enemy.detectionProgress = 0
                    enemy.windup = 0; brain.holdTimer = 0; brain.pathTimer = 0
                    brain.searchAge = 0; brain.searchingInPlace = false; brain.stuckTime = 0
                }
                enemy.seesPlayer = false
            }
        }
        brain.alert = enemy.awareness != .watching
        if brain.alert && !enemy.seesPlayer {
            brain.searchAge += dt
            if !brain.searchingInPlace && (brain.lastKnown.map { horizontalDistance(enemy.position, $0) < 1.1 } == true ||
                                          brain.stuckTime > 4 || brain.searchAge > 30) {
                brain.searchingInPlace = true; brain.searchTimer = 4
                brain.coverGoal = nil; enemy.awareness = .searching
            }
            if brain.searchingInPlace {
                brain.searchTimer -= dt
                if brain.searchTimer <= 0 && !brain.visualContact {
                    enemy.awareness = .watching; brain.alert = false; brain.lastKnown = nil
                    brain.searchingInPlace = false; brain.patrolAnchor = enemy.position
                    brain.patrolYaw = enemy.yaw; brain.patrolGoal = nil; brain.watchTimer = 1.2
                    brain.coverGoal = nil; brain.path.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    private func turn(_ enemy: inout EnemyState, toward yaw: Float, dt: Float) {
        let difference = atan2(sin(yaw - enemy.yaw), cos(yaw - enemy.yaw))
        enemy.yaw += clamp(difference, -2.8 * dt, 2.8 * dt)
    }

    private func moveEnemy(_ enemy: inout EnemyState, brain: inout EnemyBrain, toward goal: SIMD3<Float>,
                           running: Bool, dt: Float) {
        if brain.pathTimer <= 0 {
            brain.path = findPath(from: enemy.position, to: goal); brain.pathIndex = 0
            brain.pathTimer = 1.2 + random() * 0.6
        }
        let next = horizontalDistance(enemy.position, goal) < 2.6 ? goal :
            (brain.pathIndex < brain.path.count ? brain.path[brain.pathIndex] : enemy.position)
        let length = horizontalDistance(enemy.position, next)
        if length < 0.2 { brain.pathIndex += 1; return }
        startUsefulJump(&enemy, brain: &brain, toward: next)
        enemy.isRunning = running && enemy.crouchAmount < 0.3
        let speed: Float = enemy.isRunning ? 4.6 + Float(wave) * 0.12 : enemy.crouchAmount > 0.5 ? 1.25 : 2.5
        let direction = SIMD3<Float>(next.x - enemy.position.x, 0, next.z - enemy.position.z) / length
        enemy.position = moved(enemy.position, delta: direction * min(length, dt * speed),
                               height: EnemyPose(enemy).totalHeight, radius: 0.38, grounded: enemy.grounded)
        if !enemy.seesPlayer || enemy.isRunning { turn(&enemy, toward: atan2(direction.x, direction.z), dt: dt) }
    }

    private func patrol(_ enemy: inout EnemyState, brain: inout EnemyBrain, dt: Float) {
        guard !brain.visualContact else { return }
        if let goal = brain.patrolGoal, horizontalDistance(enemy.position, goal) < 0.7 || brain.stuckTime > 3 {
            brain.patrolGoal = nil; brain.watchTimer = 2.2 + Float(enemy.id % 4) * 0.3
            brain.stuckTime = 0; brain.arriving = false
        }
        if brain.patrolGoal == nil {
            // Guards scan while pausing between short routes, including behind them.
            brain.stuckTime = 0
            enemy.yaw += dt * 0.65
            brain.watchTimer -= dt
            if brain.watchTimer <= 0 {
                for _ in 0..<6 {
                    brain.patrolIndex += 1
                    let angle = brain.patrolYaw + Float(brain.patrolIndex) * 2.39996
                    let candidate = groundedPoint(brain.patrolAnchor + SIMD3(sin(angle) * 5, 0, cos(angle) * 5))
                    guard !blocked(candidate, height: 1.96, radius: 0.4), terrain.normal(x: candidate.x, z: candidate.z).y >= 0.72 else { continue }
                    let path = findPath(from: enemy.position, to: candidate)
                    guard let end = path.last, horizontalDistance(end, candidate) < 2 else { continue }
                    brain.patrolGoal = candidate; brain.path = path; brain.pathIndex = 0; brain.pathTimer = 1.5
                    break
                }
                if brain.patrolGoal == nil { brain.watchTimer = 1 }
            }
        }
        if let goal = brain.patrolGoal { moveEnemy(&enemy, brain: &brain, toward: goal, running: brain.arriving, dt: dt) }
    }

    private func updateEnemies(_ dt: Float) {
        for index in enemies.indices where enemies[index].health > 0 {
            var enemy = enemies[index]
            guard var brain = brains[enemy.id] else { continue }
            brain.cooldown -= dt; brain.pathTimer -= dt; brain.sightTimer -= dt; brain.coverDecisionTimer -= dt
            brain.hurt = max(0, brain.hurt - dt); brain.suppression = max(0, brain.suppression - dt)
            brain.holdTimer = max(0, brain.holdTimer - dt); brain.jumpCooldown = max(0, brain.jumpCooldown - dt)
            brain.coverTimer = max(0, brain.coverTimer - dt); brain.coverCooldown = max(0, brain.coverCooldown - dt)
            brain.repositionTimer -= dt; enemy.recoil *= exp(-dt * 16)
            updateAwareness(&enemy, brain: &brain, dt: dt)
            let distance = horizontalDistance(enemy.position, brain.lastKnown ?? enemy.position)
            let threat = (brain.lastKnown ?? enemy.position) + SIMD3<Float>(0, 1.6, 0)
            if brain.coverDecisionTimer <= 0 || (brain.hurt > 0 && brain.coverCooldown <= 0) {
                brain.coverDecisionTimer = 1.3 + Float(enemy.id % 5) * 0.12
                if brain.alert && brain.coverCooldown <= 0 && (brain.suppression > 0 || (enemy.seesPlayer && distance < 32)) {
                    brain.coverGoal = nearestCover(for: enemy.position, threat: threat)
                    brain.coverTimer = 4.6; brain.coverCooldown = 9; brain.pathTimer = 0
                }
                if let goal = brain.coverGoal, clearLine(goal + SIMD3(0, 0.98, 0), threat) { brain.coverGoal = nil }
            }
            let seekingCover = brain.coverGoal != nil && brain.coverTimer > 0
            let nearCover = seekingCover && horizontalDistance(enemy.position, brain.coverGoal!) < 0.8
            let hurtPause = brain.hurt > 0.05 && enemy.grounded
            let wantCrouch = enemy.grounded && enemy.windup <= 0 &&
                (hurtPause || (nearCover && brain.coverTimer > 1.25) || (brain.suppression > 0 && !seekingCover))
            enemy.crouchAmount += ((wantCrouch ? 1 : 0) - enemy.crouchAmount) * min(1, dt * 10)
            enemy.isMoving = false; enemy.isRunning = false
            if hurtPause && enemy.windup > 0 { enemy.windup = 0; brain.cooldown = max(brain.cooldown, 0.7) }
            // Only a current visual observation may follow the real player.
            if brain.visualContact { aim(&enemy, at: eyePosition) }
            let pose = EnemyPose(enemy)
            let needsMuzzleCheck = enemy.seesPlayer && ((enemy.windup > 0 && enemy.windup <= dt) || (enemy.windup <= 0 && brain.cooldown <= 0))
            let muzzleClear = needsMuzzleCheck && clearLine(pose.eyePosition, pose.gunRoot) && clearLine(pose.gunRoot, pose.muzzlePosition) && clearLine(pose.muzzlePosition, eyePosition)
            if enemy.windup > 0 {
                enemy.windup = max(0, enemy.windup - dt)
                if enemy.windup == 0 {
                    if enemy.seesPlayer && enemy.grounded && muzzleClear && state == .active {
                        enemy.aimBlend = 1
                        let baseAccuracy: Float = difficulty == .easy ? 0.31 : difficulty == .hard ? 0.8 : 0.56
                        let accuracy = baseAccuracy * (player.prone ? 0.52 : 1) * (isSprinting ? 0.6 : 1) * (player.grounded ? 1 : 0.65)
                        let hit = random() < accuracy
                        var target = eyePosition
                        if !hit { target.x += (random() > 0.5 ? 1 : -1) * (1 + random()); target.y += 0.5 }
                        let damage: Float = difficulty == .easy ? 6 : difficulty == .hard ? 13 : 9
                        emit(GameEvent(kind: .enemyShot, position: pose.muzzlePosition, endPosition: target, amount: hit ? damage : 0, id: enemy.id))
                        if hit { damagePlayer(amount: damage, from: pose.muzzlePosition) }
                        enemy.recoil = 1; brain.holdTimer = 0.32
                    }
                    brain.cooldown = 1.1 + random() * 1.7
                }
            } else if enemy.seesPlayer && enemy.grounded && distance < 42 && brain.cooldown <= 0 &&
                        !wantCrouch && enemy.crouchAmount < 0.35 && muzzleClear {
                enemy.windup = 0.65
            }
            let pursuit = seekingCover ? brain.coverGoal! : (brain.lastKnown ?? enemy.position)
            let before = enemy.position
            if enemy.windup <= 0 && brain.holdTimer <= 0 && !hurtPause && !nearCover && state == .active {
                if !brain.alert {
                    patrol(&enemy, brain: &brain, dt: dt)
                } else if brain.searchingInPlace && !enemy.seesPlayer {
                    if !brain.visualContact { enemy.yaw += dt * 1.15 }
                } else if !enemy.seesPlayer || distance > 19 || seekingCover {
                    moveEnemy(&enemy, brain: &brain, toward: pursuit,
                              running: seekingCover || distance > 22 || !enemy.seesPlayer, dt: dt)
                } else if brain.repositionTimer > 0 || distance < 7 {
                    let strafe = brain.side * 1.1 * dt, retreat: Float = distance < 7 ? -1.7 * dt : 0
                    let delta = SIMD3(cos(enemy.yaw) * strafe + sin(enemy.yaw) * retreat, 0,
                                      -sin(enemy.yaw) * strafe + cos(enemy.yaw) * retreat)
                    enemy.position = moved(enemy.position, delta: delta, height: EnemyPose(enemy).totalHeight, radius: 0.38, grounded: enemy.grounded)
                    if horizontalDistance(enemy.position, before) < 0.001 { brain.side *= -1 }
                } else if brain.repositionTimer < -3.3 { brain.repositionTimer = 0.65 + random() * 0.5 }
            }
            enemy.isMoving = horizontalDistance(before, enemy.position) > 0.0001
            enemy.isRunning = enemy.isRunning && enemy.isMoving
            if enemy.isMoving { enemy.walkCycle += dt * (enemy.isRunning ? 12 : 7); brain.stuckTime = 0 }
            else if !nearCover && !hurtPause && !enemy.seesPlayer && !brain.searchingInPlace { brain.stuckTime += dt }
            applyGravity(&enemy, dt: dt)
            let aimTarget: Float = enemy.windup > 0 || brain.holdTimer > 0 ? 1 : enemy.seesPlayer && !enemy.isRunning ? 0.65 : 0
            enemy.aimBlend += (aimTarget - enemy.aimBlend) * min(1, dt * 12)
            if enemy.seesPlayer && !enemy.isRunning { aim(&enemy, at: eyePosition) }
            else { enemy.aimPitch += ((enemy.isRunning ? -0.38 : -0.22) - enemy.aimPitch) * min(1, dt * 8) }
            enemies[index] = enemy; brains[enemy.id] = brain
            if state != .active { return }
        }
    }
}
