import Foundation
import simd

/// Deterministic combat rules. Rendering and native input remain outside this type.
/// Call exclusively on the game thread; wall-clock deltas are integrated at 120 Hz.
public final class CombatSimulation {
    public let terrain: TerrainProfile
    public private(set) var player: PlayerState
    public private(set) var enemies: [EnemyState]
    public private(set) var obstacles: [Obstacle]
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
    public var extractionReady: Bool { wave == 3 && aliveCount == 0 }
    public var aliveCount: Int { enemies.reduce(0) { $0 + ($1.health > 0 ? 1 : 0) } }
    public var eyePosition: SIMD3<Float> { player.position + SIMD3(0, player.height - 0.1, 0) }
    public var isHidden: Bool {
        aliveCount > 0 && !enemies.contains { $0.health > 0 && $0.seesPlayer } && elapsed - lastShot > 1.5
    }
    public var mantleAvailable: Bool { state == .active && climbing == nil && player.grounded && mantleTarget() != nil }
    public var climbProgress: Float? { climbing.map { $0.progress / 0.75 } }
    public var extractionPosition: SIMD3<Float> { groundedPoint(GameMap.extraction) }

    let difficulty: Difficulty
    private var seed: UInt64
    private var accumulator: Double = 0
    private var nextID = 100
    private var grenadeCooldown: Float = 0
    private var lastShot: Double = -20
    private var events: [GameEvent] = []
    private var climbing: ClimbState?
    private var brains: [Int: EnemyBrain] = [:]
    private var navigationDirty = true
    // Reuse BFS work buffers. Only the output path is allocated per route request.
    private let navWidth = 39, navDepth = 43
    private var navigation = [Bool](repeating: false, count: 39 * 43)
    private var navigationHeights = [Float](repeating: 0, count: 39 * 43)
    private var visited = [UInt32](repeating: 0, count: 39 * 43)
    private var previous = [Int](repeating: -1, count: 39 * 43)
    private var searchGeneration: UInt32 = 0
    private var searchQueue = [Int]()

    public convenience init(difficulty: Difficulty = .normal, seed: UInt64 = 1745, terrain: TerrainProfile = .battlefield) {
        self.init(difficulty: difficulty, seed: seed, world: GameMap.obstacles,
                  startingPlayer: PlayerState(), startingEnemies: [], startingWave: 0, terrain: terrain)
    }

    /// A complete scenario also permits isolated rule tests and visual previews.
    /// Obstacle base y values are offsets above the terrain. Grounded actors
    /// initialized at y=0 settle onto it; explicit nonzero actor heights remain absolute.
    public init(difficulty: Difficulty = .normal, seed: UInt64 = 1745, world: [Obstacle],
                startingPlayer: PlayerState = PlayerState(), startingEnemies: [EnemyState] = [], startingWave: Int = 0,
                terrain: TerrainProfile = .flat) {
        self.difficulty = difficulty; self.seed = seed & 0xffff_ffff; self.terrain = terrain
        obstacles = world.map { box in
            var grounded = Obstacle(id: box.id, kind: box.kind,
                                    position: box.position + SIMD3(0, terrain.height(x: box.position.x, z: box.position.z), 0), size: box.size)
            grounded.health = box.health; grounded.destroyed = box.destroyed
            return grounded
        }
        player = startingPlayer; enemies = startingEnemies; wave = startingWave
        if player.grounded && abs(player.position.y) < 0.001 { player.position.y = terrain.height(x: player.position.x, z: player.position.z) }
        for index in enemies.indices where enemies[index].grounded && abs(enemies[index].position.y) < 0.001 {
            enemies[index].position.y = terrain.height(x: enemies[index].position.x, z: enemies[index].position.z)
        }
        events.reserveCapacity(128); searchQueue.reserveCapacity(navWidth * navDepth)
        grenades.reserveCapacity(8); supplies.reserveCapacity(8)
        for enemy in enemies {
            brains[enemy.id] = EnemyBrain(cooldown: 2, sightTimer: Float(enemy.id % 5) * 0.02)
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
        if position.x < GameMap.minimum.x + radius || position.x > GameMap.maximum.x - radius ||
            position.z < GameMap.minimum.z + radius || position.z > GameMap.maximum.z - radius { return true }
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
        for enemy in enemies where enemy.health > 0 && horizontalDistance(enemy.position, player.position) < 38 {
            guard var brain = brains[enemy.id] else { continue }
            brain.lastKnown = player.position; brain.memory = 7; brain.alert = true
            brains[enemy.id] = brain
        }
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
        let damage = activeWeapon.damage * (hit.headshot ? 2.4 : 1)
        if let index = hit.enemyIndex { damageEnemy(index: index, amount: damage, headshot: hit.headshot) }
        if let index = hit.obstacleIndex { damageCover(index: index, amount: activeWeapon.damage) }
        emit(GameEvent(kind: .shot, position: muzzle, endPosition: hitPoint,
                       amount: hit.enemyIndex != nil ? damage : 0, headshot: hit.headshot, weapon: activeWeapon))
        return true
    }

    func damageEnemy(index: Int, amount: Float, headshot: Bool = false) {
        guard enemies.indices.contains(index), enemies[index].health > 0, amount.isFinite, amount > 0 else { return }
        let id = enemies[index].id
        enemies[index].health = max(0, enemies[index].health - amount)
        if var brain = brains[id] {
            brain.alert = true; brain.hurt = 0.3; brain.suppression = 1.8; brain.lastKnown = player.position; brain.memory = 6
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
        emit(GameEvent(kind: .coverDestroyed, position: box.position + SIMD3(0, box.size.y * 0.5, 0), id: box.id))
        return box.kind == .barrel ? box.position + SIMD3(0, 0.55, 0) : nil
    }

    func damageCover(index: Int, amount: Float) {
        if let barrel = applyCoverDamage(index: index, amount: amount) { explode(at: barrel) }
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
            for index in enemies.indices where enemies[index].health > 0 {
                let target = EnemyPose(enemies[index]).bodyCenter
                let distance = simd_distance(center, target)
                if distance < 8 && clearLine(center, target) { damageEnemy(index: index, amount: 220 * (1 - distance / 8)) }
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
        updateWaves(dt)
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

    private func updateWaves(_ dt: Float) {
        guard aliveCount == 0 else { return }
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
            extractionProgress = horizontalDistance(player.position, extractionPosition) < GameMap.extractionRadius && player.grounded &&
                abs(player.position.y - extractionPosition.y) < 0.2 ? min(3, extractionProgress + dt) : 0
            if extractionProgress >= 3 {
                state = .won; score += 500; isSprinting = false
                emit(GameEvent(kind: .win, position: player.position, amount: 500))
            }
        }
    }

    func spawnWave() {
        guard wave < 3, state == .active else { return }
        wave += 1; intermission = 0
        enemies.removeAll { $0.health <= 0 && elapsed - ($0.deathTime ?? 0) >= 5 }
        let liveIDs = Set(enemies.map(\.id)); brains = brains.filter { liveIDs.contains($0.key) }
        let count = 3 + wave * 2
        let candidates = GameMap.spawns.map(groundedPoint).filter {
            horizontalDistance($0, player.position) > 14 && !blocked($0, height: 1.9, radius: 0.4)
        }
        for offset in 0..<count {
            let base = candidates.isEmpty ? GameMap.spawns[offset % GameMap.spawns.count] : candidates[offset % candidates.count]
            var position: SIMD3<Float>?
            for attempt in 0..<40 {
                let candidate = groundedPoint(base + (attempt == 0 ? .zero : SIMD3((random() - 0.5) * 12, 0, (random() - 0.5) * 12)))
                if !blocked(candidate, height: 1.9, radius: 0.4) && horizontalDistance(candidate, player.position) > 12 &&
                    !enemies.contains(where: { $0.health > 0 && horizontalDistance($0.position, candidate) < 1.2 }) {
                    position = candidate; break
                }
            }
            guard let position else { continue }
            let enemy = EnemyState(id: allocateID(), position: position, health: Float(90 + wave * 10))
            enemies.append(enemy)
            var brain = EnemyBrain(cooldown: 2 + Float(offset) * 0.35, sightTimer: Float(offset % 5) * 0.02)
            brain.side = offset.isMultiple(of: 2) ? -1 : 1
            brains[enemy.id] = brain
        }
        emit(GameEvent(kind: .waveStarted, amount: Float(aliveCount), count: wave))
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
    var memory: Float = 0
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
    func findPath(from: SIMD3<Float>, to: SIMD3<Float>) -> [SIMD3<Float>] {
        if navigationDirty {
            for z in 0..<navDepth {
                for x in 0..<navWidth {
                    let point = groundedPoint(SIMD3(-38 + Float(x) * 2, 0, -42 + Float(z) * 2))
                    navigationHeights[z * navWidth + x] = point.y
                    // Low barriers are traversable with a deliberate vault/jump;
                    // buildings and containers still require a route around them.
                    // Keep the 2.5cm collision tolerance below the 1.12m jump
                    // limit: a 1.20m crate must route around, not become a trap.
                    navigation[z * navWidth + x] = blocked(point + SIMD3(0, 1.09, 0), height: 0.87, radius: 0.48) ||
                        terrain.normal(x: point.x, z: point.z).y < 0.72
                }
            }
            navigationDirty = false
        }
        func gridKey(_ position: SIMD3<Float>) -> Int {
            let x = clamp(Int(((position.x + 38) / 2).rounded()), 0, navWidth - 1)
            let z = clamp(Int(((position.z + 42) / 2).rounded()), 0, navDepth - 1)
            return z * navWidth + x
        }
        let start = gridKey(from), end = gridKey(to)
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
            for (dx, dz) in [(0, -1), (1, 0), (0, 1), (-1, 0)] {
                let nx = x + dx, nz = z + dz
                guard nx >= 0, nx < navWidth, nz >= 0, nz < navDepth else { continue }
                let next = nz * navWidth + nx
                if visited[next] == searchGeneration || navigation[next] || abs(navigationHeights[next] - navigationHeights[current]) > 1.6 { continue }
                visited[next] = searchGeneration; previous[next] = current; searchQueue.append(next)
            }
        }
        var result: [SIMD3<Float>] = [], current = found
        while current != start {
            result.append(SIMD3(-38 + Float(current % navWidth) * 2, navigationHeights[current], -42 + Float(current / navWidth) * 2))
            current = previous[current]
        }
        return result.reversed()
    }

    private func nearestCover(for position: SIMD3<Float>) -> SIMD3<Float>? {
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
                    !clearLine(candidate + SIMD3(0, 0.98, 0), eyePosition) {
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

    private func updateEnemies(_ dt: Float) {
        for index in enemies.indices where enemies[index].health > 0 {
            var enemy = enemies[index]
            guard var brain = brains[enemy.id] else { continue }
            let distance = horizontalDistance(enemy.position, player.position)
            brain.cooldown -= dt; brain.pathTimer -= dt; brain.sightTimer -= dt; brain.coverDecisionTimer -= dt
            brain.hurt = max(0, brain.hurt - dt); brain.suppression = max(0, brain.suppression - dt)
            brain.holdTimer = max(0, brain.holdTimer - dt); brain.jumpCooldown = max(0, brain.jumpCooldown - dt)
            brain.coverTimer = max(0, brain.coverTimer - dt); brain.coverCooldown = max(0, brain.coverCooldown - dt)
            brain.repositionTimer -= dt; enemy.recoil *= exp(-dt * 16)
            if brain.sightTimer <= 0 {
                enemy.seesPlayer = distance < 48 && clearLine(EnemyPose(enemy).eyePosition, eyePosition)
                brain.sightTimer = 0.1
                if enemy.seesPlayer { brain.lastKnown = player.position; brain.memory = 6; brain.alert = true }
            }
            if !enemy.seesPlayer { brain.memory = max(0, brain.memory - dt) }
            if brain.memory == 0 { brain.alert = false }
            if brain.coverDecisionTimer <= 0 || (brain.hurt > 0 && brain.coverCooldown <= 0) {
                brain.coverDecisionTimer = 1.3 + Float(enemy.id % 5) * 0.12
                if brain.alert && brain.coverCooldown <= 0 && (brain.suppression > 0 || (enemy.seesPlayer && distance < 32)) {
                    brain.coverGoal = nearestCover(for: enemy.position)
                    brain.coverTimer = 4.6; brain.coverCooldown = 9; brain.pathTimer = 0
                }
                if let goal = brain.coverGoal, clearLine(goal + SIMD3(0, 0.98, 0), eyePosition) { brain.coverGoal = nil }
            }
            let seekingCover = brain.coverGoal != nil && brain.coverTimer > 0
            let nearCover = seekingCover && horizontalDistance(enemy.position, brain.coverGoal!) < 0.8
            let hurtPause = brain.hurt > 0.05 && enemy.grounded
            let wantCrouch = enemy.grounded && enemy.windup <= 0 &&
                (hurtPause || (nearCover && brain.coverTimer > 1.25) || (brain.suppression > 0 && !seekingCover))
            enemy.crouchAmount += ((wantCrouch ? 1 : 0) - enemy.crouchAmount) * min(1, dt * 10)
            enemy.isMoving = false; enemy.isRunning = false
            if hurtPause && enemy.windup > 0 { enemy.windup = 0; brain.cooldown = max(brain.cooldown, 0.7) }
            if enemy.seesPlayer || enemy.windup > 0 { aim(&enemy, at: eyePosition) }
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
            if brain.alert && enemy.windup <= 0 && brain.holdTimer <= 0 && !hurtPause && !nearCover && state == .active {
                let before = enemy.position
                if !enemy.seesPlayer || distance > 19 || seekingCover {
                    if brain.pathTimer <= 0 {
                        brain.path = findPath(from: enemy.position, to: pursuit); brain.pathIndex = 0
                        brain.pathTimer = 1.2 + random() * 0.6
                    }
                    let next = horizontalDistance(enemy.position, pursuit) < 2.6 ? pursuit :
                        (brain.pathIndex < brain.path.count ? brain.path[brain.pathIndex] : enemy.position)
                    let length = horizontalDistance(enemy.position, next)
                    if length < 0.2 { brain.pathIndex += 1 }
                    else {
                        startUsefulJump(&enemy, brain: &brain, toward: next)
                        enemy.isRunning = enemy.crouchAmount < 0.3 && (seekingCover || distance > 22 || !enemy.seesPlayer)
                        let moveSpeed: Float = enemy.isRunning ? 4.6 + Float(wave) * 0.12 : enemy.crouchAmount > 0.5 ? 1.25 : 2.5
                        let offset = SIMD3<Float>(next.x - enemy.position.x, 0, next.z - enemy.position.z) / length
                        enemy.position = moved(enemy.position, delta: offset * min(length, dt * moveSpeed),
                                               height: EnemyPose(enemy).totalHeight, radius: 0.38, grounded: enemy.grounded)
                        if enemy.isRunning { enemy.yaw = atan2(offset.x, offset.z) }
                    }
                } else if brain.repositionTimer > 0 || distance < 7 {
                    let strafe = brain.side * 1.1 * dt, retreat: Float = distance < 7 ? -1.7 * dt : 0
                    let delta = SIMD3(cos(enemy.yaw) * strafe + sin(enemy.yaw) * retreat, 0,
                                      -sin(enemy.yaw) * strafe + cos(enemy.yaw) * retreat)
                    enemy.position = moved(enemy.position, delta: delta, height: EnemyPose(enemy).totalHeight, radius: 0.38, grounded: enemy.grounded)
                    if horizontalDistance(enemy.position, before) < 0.001 { brain.side *= -1 }
                } else if brain.repositionTimer < -3.3 { brain.repositionTimer = 0.65 + random() * 0.5 }
                enemy.isMoving = horizontalDistance(before, enemy.position) > 0.0001
                enemy.isRunning = enemy.isRunning && enemy.isMoving
                if enemy.isMoving { enemy.walkCycle += dt * (enemy.isRunning ? 12 : 7) }
            }
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
