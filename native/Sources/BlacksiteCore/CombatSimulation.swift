import Foundation
import simd

/// Deterministic combat rules. Rendering and native input remain outside this type.
/// Call exclusively on the game thread; wall-clock deltas are integrated at 120 Hz.
public final class CombatSimulation {
    public let map: MapDefinition
    public let terrain: TerrainProfile
    public let missionKind: MissionKind
    public let loadout: LoadoutDefinition
    public private(set) var player: PlayerState
    public private(set) var enemies: [EnemyState]
    public private(set) var obstacles: [Obstacle]
    public private(set) var coverDebris: [CoverDebrisState] = []
    var breachOpeningTimes: [Int: Double] = [:]
    public private(set) var reconMarks: [ReconMark] = []
    public private(set) var breachCharges: [BreachChargeState] = []
    public private(set) var breachChargeCount = 0
    private var reconReadyAt: Double = 0
    public private(set) var grenades: [GrenadeState] = []
    public private(set) var smokeGrenades: [SmokeGrenadeState] = []
    public private(set) var smokeVolumes: [SmokeVolumeState] = []
    public private(set) var smokeGrenadeCount = 2
    public private(set) var supplies: [SupplyState] = []
    public private(set) var pendingContactReports: [PendingContactReport] = []
    public private(set) var contactReports: [ContactReport] = []
    public private(set) var devices: [WorldInteractableState] = []
    public private(set) var spotlights: [WorldSpotlightState] = []
    public private(set) var noiseEmitters: [NoiseEmitterState] = []
    public private(set) var decoys: [NoiseDecoyState] = []
    public private(set) var hearingStimuli: [HearingStimulus] = []
    public private(set) var noiseDecoyCount: Int = 2
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
    public private(set) var selectedExtractionID: String?
    public private(set) var pendingReinforcements = 0
    public var remainingEnemies: Int { aliveCount + pendingReinforcements }
    public var extractionReady: Bool {
        switch missionKind {
        case .waves: return wave == 3 && remainingEnemies == 0
        case .recoverData, .operation: return missionPhase == .extract || missionPhase == .completed
        case .secureRadio: return false
        }
    }
    public var aliveCount: Int { enemies.reduce(0) { $0 + ($1.health > 0 ? 1 : 0) } }
    public var eyePosition: SIMD3<Float> { player.position + SIMD3(0, player.height - 0.1, 0) }
    public var isHidden: Bool {
        aliveCount > 0 && !enemies.contains { $0.health > 0 && $0.seesPlayer } && elapsed - lastShot > 1.5
    }
    public var concealmentStatus: ConcealmentStatus {
        let sample = environmentSample(at: player.position)
        let matches = loadout.camouflage.matches(sample.camouflageGround)
        let reason: ConcealmentReason
        if loadout.camouflage == .none { reason = .noSuit }
        else if !player.grounded || climbing != nil { reason = .airborne }
        else if elapsed - lastShot < ConcealmentEvaluation.shotLockoutDuration { reason = .recentShot }
        else if !matches { reason = .unsuitableGround }
        else if let movement = concealmentMotion.reason { reason = movement }
        else if concealmentMotion.settleProgress < 1 { reason = .settling }
        else { reason = .ready }
        let strength: Float = reason == .ready ? (player.prone ? 1 : 0.4) * concealmentMotion.turnStrength : 0
        return ConcealmentStatus(pattern: loadout.camouflage, surfaceMaterial: sample.surfaceMaterial,
            camouflageGround: sample.camouflageGround, matchesGround: matches,
            settleProgress: concealmentMotion.settleProgress, localStrength: strength, reason: reason)
    }
    public var mantleAvailable: Bool { state == .active && climbing == nil && player.grounded && mantleTarget() != nil }
    public var climbProgress: Float? { climbing.map { $0.progress / 0.75 } }
    public var extractionPosition: SIMD3<Float> {
        if let exit = presentedOperationExtraction { return map.grounded(exit.position) }
        return groundedPoint(map.extraction)
    }
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
        guard state == .active, missionPhase == .prepareOperation || missionPhase == .collectData || missionPhase == .activateRadio,
              player.grounded, climbing == nil else { return false }
        let target = groundedPoint(missionPhase == .activateRadio ? map.radioSite : map.dataSite)
        return simd_distance(player.position, target) <= 1.6
    }
    public var missionStatus: MissionStatus {
        let phase: MissionPhase = state == .won ? .completed : missionKind == .waves ? (extractionReady ? .extract : .waves) : missionPhase
        let target: SIMD3<Float>?, radius: Float, progress: Float, required: Float
        var interruption: MissionInterruption?
        switch phase {
        case .waves:
            target = nil; radius = 0; progress = Float(kills); required = 21
        case .prepareOperation, .collectData, .activateRadio:
            target = groundedPoint(phase == .activateRadio ? map.radioSite : map.dataSite)
            radius = 1.6; progress = Float(missionProgressTicks)/120; required = phase == .activateRadio ? 1 : 0.8
            if !player.grounded || climbing != nil { interruption = .notGrounded }
            else if !missionInteractionAvailable { interruption = .outOfRange }
            else if !interactionHeld { interruption = .interactionReleased }
        case .extract:
            if let exit = presentedOperationExtraction {
                let snapshot = extractionSnapshot(exit)
                target = snapshot.position; radius = snapshot.radius; progress = snapshot.progress
                required = snapshot.requiredProgress; interruption = snapshot.interruption
            } else {
                target = extractionPosition; radius = map.extractionRadius; progress = extractionProgress; required = 3
                if !player.grounded || climbing != nil { interruption = .notGrounded }
                else if !insideExtraction { interruption = .outOfRange }
            }
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
                             interactionAvailable: missionInteractionAvailable,
                             extractionID: missionKind == .operation ? (phase == .completed ? selectedExtractionID : phase == .extract ? presentedOperationExtraction?.id : nil) : nil)
    }

    let difficulty: Difficulty
    private var seed: UInt64
    private var accumulator: Double = 0
    private var nextID = 100
    private var nextHearingID = 1
    private var nextContactReportID = 1
    private var escalationReport: ContactReport?
    private var assignedGuardIDs: [Int] = []
    private var alarmReinforcementsCommitted = 0
    private var pendingAlarmReinforcements = 0
    private var playerHeardEscalation = false
    private var deviceInteractionLatch = false
    private var activeDeviceID: Int?
    private var deviceInteractionTicks = 0
    private var deviceInputHeld = false
    private var cachedLightTime: Double = -1
    private var cachedLightFactor: Float = 1
    private var playerStepDistance: Float = 0
    private var decoyCooldown: Float = 0
    private var grenadeCooldown: Float = 0
    private var smokeCooldown: Float = 0
    private var smokeEmitterCycles: [Int: Int] = [:]
    private var lastShot: Double = -20
    private var concealmentMotion = ConcealmentMotion()
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
                            terrainOverride: TerrainProfile? = nil, mission: MissionKind = .waves, loadout: LoadoutDefinition = .init()) {
        let selected = terrainOverride.map { map.withTerrain($0) } ?? map
        self.init(difficulty: difficulty, seed: seed, world: selected.obstacles,
                  startingEnemies: [], startingWave: 0, terrain: selected.terrain, mission: mission, map: selected, loadout: loadout)
    }

    /// Compatibility for existing callers which explicitly selected a profile.
    public convenience init(difficulty: Difficulty = .normal, seed: UInt64 = 1745, terrain: TerrainProfile,
                            mission: MissionKind = .waves, loadout: LoadoutDefinition = .init()) {
        self.init(map: .blacksite, difficulty: difficulty, seed: seed, terrainOverride: terrain, mission: mission, loadout: loadout)
    }

    /// Explicit actor heights remain world-space. Omitted actors use the map's
    /// authored start. Legacy isolated worlds retain their flat default profile.
    public init(difficulty: Difficulty = .normal, seed: UInt64 = 1745, world: [Obstacle],
                startingPlayer: PlayerState? = nil, startingEnemies: [EnemyState] = [], startingWave: Int = 0,
                terrain: TerrainProfile? = nil, mission: MissionKind = .waves, map: MapDefinition? = nil,
                loadout: LoadoutDefinition = .init()) {
        let selected = map ?? MapDefinition.blacksite.withoutVegetation()
        let terrain = terrain ?? (map == nil ? .flat : selected.terrain)
        self.map = selected.withTerrain(terrain)
        // Preserve the nonthrowing legacy initializer. Frontends can reject an
        // unsupported selection using supportsMission; direct callers get the
        // documented data-recovery fallback and an honest effective missionKind.
        let mission = selected.supportsMission(mission) ? mission : .recoverData
        self.difficulty = difficulty; self.seed = seed & 0xffff_ffff; self.terrain = terrain; missionKind = mission
        self.loadout = loadout; grenadeCount = loadout.fragmentationGrenades; noiseDecoyCount = loadout.noiseDecoys
        smokeGrenadeCount = loadout.smokeGrenades; breachChargeCount = loadout.breachCharges
        weapons[.rifle]?.reserve = loadout.rifleReserve; weapons[.sniper]?.reserve = loadout.sniperReserve
        missionPhase = mission == .waves ? .waves : mission == .secureRadio ? .activateRadio : mission == .operation ? .prepareOperation : .collectData
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
        noiseEmitters = selected.environment.noiseEmitters.compactMap { definition in
            if let owner = definition.ownerObstacleID, !obstacles.contains(where: { $0.id == owner && !$0.destroyed }) { return nil }
            return NoiseEmitterState(id: definition.id, position: definition.position + SIMD3(0, terrain.height(x: definition.position.x, z: definition.position.z), 0),
                enabled: definition.enabled, strength: definition.strength, range: definition.range, ownerObstacleID: definition.ownerObstacleID)
        }
        devices = selected.environment.devices.compactMap { definition in
            guard let owner = obstacles.first(where: { $0.id == definition.ownerObstacleID }) else { return nil }
            return WorldInteractableState(id: definition.id, kind: definition.kind, ownerObstacleID: definition.ownerObstacleID,
                interactionPoints: definition.interactionPoints.map { self.map.grounded($0) }, closedPosition: owner.position)
        }
        spotlights = selected.environment.spotlights.map { definition in
            WorldSpotlightState(id: definition.id, position: self.map.grounded(definition.position),
                direction: simd_normalize(definition.direction), range: definition.range, innerCos: definition.innerCos,
                outerCos: definition.outerCos, power: definition.power, color: definition.color, ownerObstacleID: definition.ownerObstacleID)
        }
        synchronizeDestroyedDevices()
        synchronizeDevicePower()
        concealmentMotion.resetPose(player)
        events.reserveCapacity(128); searchQueue.reserveCapacity(navWidth * navDepth)
        grenades.reserveCapacity(8); supplies.reserveCapacity(8)
        smokeGrenades.reserveCapacity(SmokeVolumeState.maximumCount); smokeVolumes.reserveCapacity(SmokeVolumeState.maximumCount)
        coverDebris.reserveCapacity(CoverDebrisState.maximumCount)
        reconMarks.reserveCapacity(ReconMark.maximumCount); breachCharges.reserveCapacity(BreachChargeState.maximumCount)
        hearingStimuli.reserveCapacity(64); decoys.reserveCapacity(NoiseDecoyState.maximumCount)
        pendingContactReports.reserveCapacity(4); contactReports.reserveCapacity(16); assignedGuardIDs.reserveCapacity(2)
        pendingCoverDebris.reserveCapacity(world.count)
        for box in obstacles { nextID = max(nextID, box.id + 1) }
        for emitter in noiseEmitters { nextID = max(nextID, emitter.id + 1) }
        for emitter in selected.environment.smokeEmitters { nextID = max(nextID, emitter.id + 1) }
        for device in devices { nextID = max(nextID, device.id + 1) }
        for light in spotlights { nextID = max(nextID, light.id + 1) }
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
        concealmentMotion.interrupt()
    }

    @discardableResult public func jump() -> Bool {
        guard state == .active, climbing == nil, player.grounded, player.stamina >= 12 else { return false }
        if player.prone { toggleProne(); return false }
        player.verticalVelocity = 6.8; player.grounded = false; player.stamina -= 12
        concealmentMotion.interrupt()
        emit(GameEvent(kind: .jump, position: player.position))
        return true
    }

    @discardableResult public func mantle() -> Bool {
        guard state == .active, climbing == nil, player.grounded, let target = mantleTarget() else { return false }
        climbing = ClimbState(from: player.position, to: target.position, obstacleID: target.obstacleID)
        concealmentMotion.interrupt()
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
                 padding: Float = 0, excludingObstacle: Int? = nil, purpose: WorldRayPurpose = .physical) -> RayHit {
        var closest = RayHit(distance: maximumDistance)
        let pad = SIMD3<Float>(repeating: padding)
        for index in obstacles.indices where !obstacles[index].destroyed && index != excludingObstacle {
            let box = obstacles[index]
            if purpose == .sight && !blocksSight(box) { continue }
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
        concealmentMotion.interrupt()
        let hearing = recordHearing(kind: .gunshot, position: eyePosition, strength: 1, range: 44, source: .player)
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
                       surfaceImpact: surfaceImpact, hearing: hearing))
        return true
    }

    func damageEnemy(index: Int, amount: Float, headshot: Bool = false, from source: SIMD3<Float>? = nil) {
        guard enemies.indices.contains(index), enemies[index].health > 0, amount.isFinite, amount > 0 else { return }
        let id = enemies[index].id
        enemies[index].health = max(0, enemies[index].health - amount)
        if var brain = brains[id] {
            investigate(source ?? player.position, enemy: &enemies[index], brain: &brain)
            brain.hurt = 0.3; brain.suppression = 1.8
            brain.hearingPriority = 3; brain.priorityUntil = elapsed + 6; brain.lastOwnContactTime = elapsed
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
        if let definition = map.breaches.first(where: { $0.ownerObstacleID == box.id }) {
            breachOpeningTimes[box.id] = elapsed
            let snapshot = BreachState(ownerObstacleID: box.id,kind: definition.kind,visibility: definition.visibility,
                damageStage: .destroyed,position: box.position,size: box.size,openedAt: elapsed)
            let point = box.position + SIMD3(0,box.size.y*0.5,0)
            let hearing = recordHearing(kind: .breakage,position: point,
                surface: definition.kind == .glass ? .glass : .metal,strength: 0.9,
                range: definition.kind == .glass ? 20 : 26,source: .world,sourceID: box.id)
            emit(GameEvent(kind: .breachOpened,position: point,id: box.id,hearing: hearing,breach: snapshot))
        }
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
            case .crate, .glass: lifetime = 12
            case .barrel: lifetime = 8
            case .container, .accessPanel: lifetime = 15
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
        synchronizeDestroyedDevices()
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
            let hearing = recordHearing(kind: .explosion, position: center, strength: 1, range: 34, source: .world)
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
            emit(GameEvent(kind: .explosion, position: center, amount: 8, hearing: hearing))
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
        hearingStimuli.removeAll { elapsed - $0.time > 8 }
        let beforePlayer = player
        updatePlayer(dt, input: input)
        updatePlayerFootsteps(from: beforePlayer, dt: dt)
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
        if loadout.camouflage != .none {
            concealmentMotion.observe(player: player, sprinting: isSprinting, climbing: climbing != nil,
                matchesGround: loadout.camouflage.matches(environmentSample(at: player.position).camouflageGround),
                recentShot: elapsed - lastShot < ConcealmentEvaluation.shotLockoutDuration)
        }
        updateGrenades(dt)
        updateClassGadgets(dt)
        updateDecoys(dt)
        updateSmoke(dt)
        guard state == .active else { return }
        updateEnemies(dt)
        guard state == .active else { return }
        updateDevices(dt, input: input)
        updateContactReports()
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
                player.position.y = floor
                if !player.grounded && player.verticalVelocity < -4 {
                    let surface = environmentSample(at: player.position).soundSurface
                    let hearing = recordHearing(kind: .landing, position: player.position + SIMD3(0,0.1,0), surface: surface,
                        strength: min(1, abs(player.verticalVelocity) / 8), range: surface.stepRange * 1.2, source: .player)
                    emit(GameEvent(kind: .land, position: player.position, hearing: hearing))
                }
                player.verticalVelocity = 0; player.grounded = true
            } else { player.grounded = false }
        }
        if elapsed - player.lastHit > 5.5 { player.health = min(100, player.health + dt * 8) }
    }

    private func updateGrenades(_ dt: Float) {
        var index = 0
        while index < grenades.count {
            var grenade = grenades[index]
            grenade.fuse -= dt
            advanceThrowable(position: &grenade.position, velocity: &grenade.velocity, dt: dt)
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
                grenadeCount = min(loadout.fragmentationGrenades, grenadeCount + 2)
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
            queueMissionReinforcements(missionKind == .secureRadio ? 3 : 4)
        }
        switch missionPhase {
        case .prepareOperation:
            if missionInteractionAvailable && input.interact {
                changeMissionPhase(to: .collectData)
                missionProgressTicks = 1
            }
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
            if missionKind == .operation { updateOperationExtraction(); return }
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
            let alarmArrival = pendingAlarmReinforcements > 0
            var enemy = EnemyState(id: allocateID(), position: position, health: missionKind == .waves ? Float(90 + wave * 10) : 100)
            let staging: SIMD3<Float>
            if alarmArrival, let alarm = map.environment.alarm, !alarm.returnGuardPosts.isEmpty {
                let post = groundedPoint(alarm.returnGuardPosts[(alarmReinforcementsCommitted - pendingAlarmReinforcements) % alarm.returnGuardPosts.count])
                staging = hasReachableRoute(from: position, to: post) ? post : groundedPoint(map.waveStaging[offset % map.waveStaging.count])
            } else if missionKind == .waves {
                staging = groundedPoint(map.waveStaging[offset % map.waveStaging.count])
            } else {
                // Authored objectives are public tactical destinations. Arrivals
                // do not acquire knowledge of an unseen player's live position.
                let anchor = missionKind == .secureRadio ? map.radioSite : (missionPhase == .prepareOperation || missionPhase == .collectData) ? map.dataSite : map.extraction
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
            if alarmArrival { pendingAlarmReinforcements -= 1 }
            emit(GameEvent(kind: .reinforcementsArrived, position: position, endPosition: player.position,
                           amount: 1, id: enemy.id, count: wave,
                           contactReport: alarmArrival ? escalationReport : nil,
                           alarmReportID: alarmArrival ? escalationReport?.id : nil))
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
        for box in obstacles where !box.destroyed && blocksSight(box) {
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
    var successfulReports = 0
    var reportCooldownUntil: Double = -20
    var lastReceivedReportID = 0
    var lastOwnContactTime: Double = -20
    var guardPost: SIMD3<Float>?
    var hearingPriority = 0
    var priorityUntil: Double = -20
    var stepDistance: Float = 0
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
        brain.guardPost = nil
        brain.alert = true; brain.lastKnown = target
        brain.searchAge = 0; brain.searchTimer = 0; brain.searchingInPlace = false
        brain.stuckTime = 0; brain.patrolGoal = nil
    }

    private func updateAwareness(_ enemy: inout EnemyState, brain: inout EnemyBrain, dt: Float) {
        if brain.sightTimer <= 0 {
            let offset = eyePosition - EnemyPose(enemy).eyePosition
            let horizontal = sqrt(offset.x * offset.x + offset.z * offset.z)
            let forward = SIMD2<Float>(sin(enemy.yaw), cos(enemy.yaw))
            // Local +Z is forward. A cheap 120-degree cone test precedes raycasts.
            let inCone = horizontal < 0.05 || simd_dot(forward, SIMD2(offset.x, offset.z)) >= horizontal * 0.5
            brain.visualContact = horizontal < 48 && inCone && sightLine(EnemyPose(enemy).eyePosition, eyePosition)
            let smoke = brain.visualContact && !smokeVolumes.isEmpty ? playerSmokeVisibility(from: EnemyPose(enemy).eyePosition,eyeLineIsClear: true) : SmokeVisibilitySample(opticalDepth: 0)
            if smoke.opaque { brain.visualContact = false }
            brain.sightTimer = 0.1
            if brain.visualContact {
                let reaction: Float = (difficulty == .easy ? 0.8 : difficulty == .hard ? 0.4 : 0.6) *
                    (horizontal < 8 ? 0.7 : 1) * (player.prone ? 1.25 : 1)
                var recognition: Float = 1
                if enemy.detectionProgress < 1 {
                    recognition = vegetationRecognitionFactor(from: EnemyPose(enemy).eyePosition, eyeLineIsClear: true)
                    if loadout.camouflage != .none {
                        recognition = ConcealmentEvaluation(status: concealmentStatus, observerDistance: simd_length(offset))
                            .combinedRecognition(vegetation: recognition)
                    }
                    if cachedLightTime != elapsed {
                        cachedLightFactor = lightSample(at: eyePosition).recognitionMultiplier
                        cachedLightTime = elapsed
                    }
                    recognition = max(ConcealmentEvaluation.minimumCombinedRecognition, recognition * cachedLightFactor * smoke.transmission)
                }
                enemy.detectionProgress = min(1, enemy.detectionProgress + 0.1 / reaction * recognition)
                if enemy.detectionProgress >= 1 {
                    if enemy.awareness != .engaged {
                        emit(GameEvent(kind: .enemyAlert, position: enemy.position, id: enemy.id))
                    }
                    enemy.awareness = .engaged; enemy.seesPlayer = true
                    brain.hearingPriority = 3; brain.priorityUntil = elapsed + 6
                    brain.lastOwnContactTime = elapsed; brain.guardPost = nil
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
            // A newly opaque cloud cancels stale perception immediately; the
            // normal 10Hz cadence still handles recognition in thin/clear air.
            if brain.visualContact && !smokeVolumes.isEmpty &&
                smokeVisibility(from: EnemyPose(enemy).eyePosition,to: eyePosition).opaque &&
                playerSmokeVisibility(from: EnemyPose(enemy).eyePosition).opaque {
                brain.sightTimer = 0
            }
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
            let reporting = pendingContactReports.contains { $0.enemyID == enemy.id }
            if reporting { enemy.windup = 0 }
            let wantCrouch = enemy.grounded && enemy.windup <= 0 &&
                (hurtPause || (nearCover && brain.coverTimer > 1.25) || (brain.suppression > 0 && !seekingCover))
            enemy.crouchAmount += ((wantCrouch ? 1 : 0) - enemy.crouchAmount) * min(1, dt * 10)
            enemy.isMoving = false; enemy.isRunning = false
            if hurtPause && enemy.windup > 0 { enemy.windup = 0; brain.cooldown = max(brain.cooldown, 0.7) }
            // Only a current visual observation may follow the real player.
            if brain.visualContact { aim(&enemy, at: eyePosition) }
            let pose = EnemyPose(enemy)
            let needsMuzzleCheck = enemy.seesPlayer && ((enemy.windup > 0 && enemy.windup <= dt) || (enemy.windup <= 0 && brain.cooldown <= 0))
            let muzzleClear = needsMuzzleCheck && clearLine(pose.eyePosition, pose.gunRoot) && clearLine(pose.gunRoot, pose.muzzlePosition) && sightLine(pose.muzzlePosition, eyePosition) &&
                !smokeVisibility(from: pose.muzzlePosition,to: eyePosition).opaque
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
                        let hearing = recordHearing(kind: .gunshot, position: pose.muzzlePosition, strength: 1, range: 44, source: .enemy, sourceID: enemy.id)
                        let offset = target-pose.muzzlePosition, length = simd_length(offset)
                        let direction = offset/max(0.001,length)
                        let obstruction = wallHit(origin: pose.muzzlePosition,direction: direction,maximumDistance: length)
                        let stopped = obstruction.distance < length-0.01
                        let impactPoint = stopped ? pose.muzzlePosition+direction*obstruction.distance : target
                        let surface = stopped ? makeSurfaceImpact(for: obstruction,at: impactPoint) : nil
                        // The very shot that opens a pane ends there. Only a
                        // later shot may cross the newly navigable aperture.
                        if let owner = obstruction.obstacleIndex,
                           obstacles[owner].kind == .glass || obstacles[owner].kind == .accessPanel {
                            damageCover(index: owner,amount: damage)
                        }
                        emit(GameEvent(kind: .enemyShot, position: pose.muzzlePosition, endPosition: impactPoint,
                                       amount: hit && !stopped ? damage : 0, id: enemy.id, surfaceImpact: surface, hearing: hearing))
                        if hit && !stopped { damagePlayer(amount: damage, from: pose.muzzlePosition) }
                        enemy.recoil = 1; brain.holdTimer = 0.32
                    }
                    brain.cooldown = 1.1 + random() * 1.7
                }
            } else if !reporting && enemy.seesPlayer && enemy.grounded && distance < 42 && brain.cooldown <= 0 &&
                        !wantCrouch && enemy.crouchAmount < 0.35 && muzzleClear {
                enemy.windup = 0.65
            }
            let pursuit = seekingCover ? brain.coverGoal! : (brain.lastKnown ?? enemy.position)
            let before = enemy.position, wasGrounded = enemy.grounded
            if enemy.windup <= 0 && brain.holdTimer <= 0 && !hurtPause && !nearCover && state == .active {
                if let post = brain.guardPost, !enemy.seesPlayer && !brain.visualContact {
                    if horizontalDistance(enemy.position, post) > 0.8 {
                        moveEnemy(&enemy, brain: &brain, toward: post, running: true, dt: dt)
                    } else {
                        brain.patrolAnchor = post; brain.searchingInPlace = false; brain.searchAge = 0
                        brain.stuckTime = 0; enemy.awareness = .watching; brain.alert = false
                        enemy.yaw += dt * 0.65
                    }
                } else if !brain.alert {
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
            if wasGrounded && enemy.grounded {
                emitFootsteps(distance: simd_distance(before, enemy.position), accumulated: &brain.stepDistance,
                    position: enemy.position, speed: simd_distance(before, enemy.position) / dt,
                    lowPosture: enemy.crouchAmount > 0.6, source: .enemy, sourceID: enemy.id)
            } else { brain.stepDistance = 0 }
            let aimTarget: Float = enemy.windup > 0 || brain.holdTimer > 0 ? 1 : enemy.seesPlayer && !enemy.isRunning ? 0.65 : 0
            enemy.aimBlend += (aimTarget - enemy.aimBlend) * min(1, dt * 12)
            if enemy.seesPlayer && !enemy.isRunning { aim(&enemy, at: eyePosition) }
            else { enemy.aimPitch += ((enemy.isRunning ? -0.38 : -0.22) - enemy.aimPitch) * min(1, dt * 8) }
            enemies[index] = enemy; brains[enemy.id] = brain
            if state != .active { return }
        }
    }
}

extension CombatSimulation {
    @discardableResult public func setNoiseEmitterEnabled(id: Int, enabled: Bool) -> Bool {
        guard state == .active, let index = noiseEmitters.firstIndex(where: { $0.id == id }),
              noiseEmitters[index].enabled != enabled else { return false }
        if enabled, let owner = noiseEmitters[index].ownerObstacleID,
           !obstacles.contains(where: { $0.id == owner && !$0.destroyed }) { return false }
        noiseEmitters[index].enabled = enabled
        emit(GameEvent(kind: .noiseEmitterChanged, position: noiseEmitters[index].position,
                       id: id, noiseEmitter: noiseEmitters[index]))
        return true
    }

    @discardableResult public func throwNoiseDecoy() -> Bool {
        guard state == .active, climbing == nil, noiseDecoyCount > 0,
              decoys.count < NoiseDecoyState.maximumCount, decoyCooldown <= 0 else { return false }
        let direction = viewDirection(yaw: player.yaw, pitch: player.pitch)
        let decoy = NoiseDecoyState(id: allocateID(), position: eyePosition, velocity: direction * 12 + SIMD3(0,2.5,0))
        decoys.append(decoy); noiseDecoyCount -= 1; decoyCooldown = 0.7
        emit(GameEvent(kind: .decoyThrown, position: decoy.position, id: decoy.id))
        return true
    }

    private func updatePlayerFootsteps(from before: PlayerState, dt: Float) {
        guard before.grounded, player.grounded, climbing == nil else { playerStepDistance = 0; return }
        let distance = simd_distance(before.position, player.position)
        emitFootsteps(distance: distance, accumulated: &playerStepDistance, position: player.position,
                      speed: distance / dt, lowPosture: player.prone, source: .player)
    }

    private func emitFootsteps(distance: Float, accumulated: inout Float, position: SIMD3<Float>, speed: Float,
                               lowPosture: Bool, source: NoiseSource, sourceID: Int? = nil) {
        guard distance.isFinite, distance > 0.000_05, distance < 0.3 else { return }
        let stride: Float = lowPosture ? 0.95 : 1.65
        accumulated += distance
        guard accumulated >= stride else { return }
        accumulated -= stride
        let surface: SurfaceSound = standingOnGlassShards(at: position) ? .glass : environmentSample(at: position).soundSurface
        let strength = clamp(0.25 + speed / 10, 0.25, 1) * (lowPosture ? 0.32 : 1)
        let hearing = recordHearing(kind: .footstep, position: position + SIMD3(0,0.1,0), surface: surface,
            strength: strength, range: surface.stepRange, source: source, sourceID: sourceID)
        emit(GameEvent(kind: .footstep, position: hearing.position, amount: strength,
                       id: hearing.id, hearing: hearing))
    }

    /// A finite diagnostic history; events and AI receive the same immutable value.
    /// Friendly footsteps/shots are audible to the player but are not hostile clues.
    private func recordHearing(kind: HearingKind, position: SIMD3<Float>, surface: SurfaceSound? = nil,
                               strength: Float, range: Float, source: NoiseSource, sourceID: Int? = nil) -> HearingStimulus {
        let stimulus = HearingStimulus(id: nextHearingID, kind: kind, position: position, surface: surface,
            time: elapsed, strength: strength, range: range, source: source, sourceID: sourceID)
        nextHearingID += 1
        if hearingStimuli.count >= 64 { hearingStimuli.removeFirst() }
        hearingStimuli.append(stimulus)
        guard source != .enemy else { return stimulus }
        let priority = kind == .gunshot || kind == .explosion ? 3 : kind == .decoy || kind == .breakage ? 2 : 1
        for index in enemies.indices where enemies[index].health > 0 {
            let ear = EnemyPose(enemies[index]).eyePosition
            guard simd_distance(ear, position) < range,
                  acousticSample(for: stimulus, listener: ear).audible,
                  var brain = brains[enemies[index].id] else { continue }
            enemies[index].lastHeard = HearingObservation(position: position, kind: kind, time: elapsed)
            guard !enemies[index].seesPlayer,
                  priority >= brain.hearingPriority || elapsed >= brain.priorityUntil else { continue }
            investigate(position, enemy: &enemies[index], brain: &brain)
            brain.hearingPriority = priority
            brain.priorityUntil = elapsed + (priority == 3 ? 6 : priority == 2 ? 2.5 : 0.7)
            brains[enemies[index].id] = brain
        }
        return stimulus
    }

    private func advanceThrowable(position: inout SIMD3<Float>, velocity: inout SIMD3<Float>, dt: Float) {
        velocity.y -= 13 * dt
        var remaining = dt
        for _ in 0..<3 {
            let speed = simd_length(velocity)
            if speed < 0.0001 || remaining < 0.0001 { break }
            let direction = velocity / speed
            let hit = wallHit(origin: position, direction: direction, maximumDistance: speed * remaining, padding: 0.09)
            position += direction * max(0, hit.distance - 0.002)
            if hit.obstacleIndex == nil && !hit.hitGround { break }
            remaining -= hit.distance / speed
            velocity = (velocity - 1.5 * simd_dot(velocity, hit.normal) * hit.normal) * 0.72
            position += hit.normal * 0.004
        }
        let low = map.minimum + SIMD3<Float>(repeating: 0.09)
        let high = map.maximum - SIMD3<Float>(repeating: 0.09)
        if position.x < low.x || position.x > high.x {
            position.x = clamp(position.x, low.x, high.x); velocity.x *= -0.45
        }
        if position.z < low.z || position.z > high.z {
            position.z = clamp(position.z, low.z, high.z); velocity.z *= -0.45
        }
        position.y = max(terrain.height(x: position.x, z: position.z) + 0.09, position.y)
    }

    private func updateDecoys(_ dt: Float) {
        decoyCooldown = max(0, decoyCooldown - dt)
        var index = 0
        while index < decoys.count {
            var decoy = decoys[index]
            decoy.age += dt
            if decoy.age >= decoy.lifetime { decoys.remove(at: index); continue }
            advanceThrowable(position: &decoy.position, velocity: &decoy.velocity, dt: dt)
            if decoy.emittedPulses < 6 && decoy.age >= 0.7 + Float(decoy.emittedPulses) * 2 {
                decoy.emittedPulses += 1
                let hearing = recordHearing(kind: .decoy, position: decoy.position, strength: 0.85,
                    range: 24, source: .world, sourceID: decoy.id)
                emit(GameEvent(kind: .decoyPulse, position: decoy.position, id: decoy.id, hearing: hearing))
            }
            decoys[index] = decoy; index += 1
        }
    }
}

extension CombatSimulation {
    public var deviceInteractionAvailable: Bool { deviceInteractionStatus?.interactionAvailable == true }
    /// Retains ownership of E for a reachable device while its motor is moving,
    /// blocked, destroyed or waiting for the user to release a completed press.
    public var deviceContextAvailable: Bool {
        guard let status = deviceInteractionStatus else { return false }
        return status.distance <= 1.6 && status.interruption != .occluded
    }
    public var deviceInteractionStatus: DeviceInteractionStatus? {
        guard state == .active, !missionInteractionAvailable else { return nil }
        var nearest: (index: Int, point: SIMD3<Float>, distance: Float)?
        for index in devices.indices {
            for point in devices[index].interactionPoints {
                let distance = simd_distance(player.position, point)
                if distance <= 3.5 && distance < (nearest?.distance ?? .infinity) { nearest = (index, point, distance) }
            }
        }
        guard let nearest else { return nil }
        let device = devices[nearest.index]
        let owner = obstacles.firstIndex { $0.id == device.ownerObstacleID }
        let visible = clearLine(eyePosition, nearest.point + SIMD3(0, 1, 0), excludingObstacle: owner)
        let reason: DeviceInterruption?
        if !visible { reason = .occluded }
        else if device.destroyed { reason = .destroyed }
        else if device.blockedByActor { reason = .blockedByActor }
        else if device.isMoving { reason = .moving }
        else if !player.grounded || climbing != nil { reason = .notGrounded }
        else if nearest.distance > 1.6 { reason = .outOfRange }
        else if deviceInteractionLatch { reason = .releaseRequired }
        else if !deviceInputHeld { reason = .interactionReleased }
        else { reason = nil }
        let manual = device.kind == .serviceGate && !device.powered
        let action: DeviceAction
        if device.kind == .generator { action = device.enabled ? .disableGenerator : .enableGenerator }
        else if device.gateProgress > 0 && device.gateProgress < 1 || device.isMoving {
            action = device.targetOpen ? .openGate : .closeGate
        } else { action = device.gateProgress >= 1 ? .closeGate : .openGate }
        return DeviceInteractionStatus(id: device.id, kind: device.kind, action: action, enabled: device.enabled,
            powered: device.powered, manual: manual, position: nearest.point, distance: nearest.distance,
            progress: device.interactionProgress, requiredProgress: Float(loadout.deviceInteractionTicks(manual: manual))/120, gateProgress: device.gateProgress,
            isMoving: device.isMoving, blockedByActor: device.blockedByActor, destroyed: device.destroyed,
            interactionAvailable: reason == nil || reason == .interactionReleased, interruption: reason)
    }

    private func synchronizeDestroyedDevices() {
        var changed = false
        for index in devices.indices where !devices[index].destroyed {
            guard let owner = obstacles.first(where: { $0.id == devices[index].ownerObstacleID }), owner.destroyed else { continue }
            devices[index].destroyed = true; devices[index].enabled = false; devices[index].powered = false
            devices[index].interactionProgress = 0; devices[index].isMoving = false; devices[index].blockedByActor = false
            if devices[index].kind == .serviceGate {
                devices[index].gateProgress = 1; devices[index].targetOpen = true
                invalidateDeviceNavigation()
            }
            if activeDeviceID == devices[index].id { activeDeviceID = nil; deviceInteractionTicks = 0 }
            emit(GameEvent(kind: .deviceDestroyed, position: owner.position, id: devices[index].id, device: devices[index]))
            changed = true
        }
        // Destruction is resolved before same-tick perception. Machine/lamp
        // state changes only on a power transition, preserving diagnostic mutes.
        if changed { synchronizeDevicePower() }
    }

    private func synchronizeDevicePower() {
        for definition in map.environment.devices where definition.kind == .generator {
            let enabled = devices.first(where: { $0.id == definition.id }).map { $0.enabled && !$0.destroyed } ?? false
            for id in definition.noiseEmitterIDs { setNoiseEmitterEnabled(id: id, enabled: enabled) }
            for index in spotlights.indices where definition.lightIDs.contains(spotlights[index].id) {
                spotlights[index].enabled = enabled
            }
        }
        for index in devices.indices where devices[index].kind == .serviceGate && !devices[index].destroyed {
            let definition = map.environment.devices.first { $0.id == devices[index].id }
            let powered = definition?.generatorID.flatMap { id in devices.first { $0.id == id } }.map { $0.enabled && !$0.destroyed } ?? false
            let lostMotorPower = devices[index].powered && !powered && devices[index].isMoving && !devices[index].manualMotion
            devices[index].powered = powered
            if lostMotorPower {
                devices[index].isMoving = false; devices[index].blockedByActor = false
                emit(GameEvent(kind: .gateStopped, position: devices[index].interactionPoints[0], id: devices[index].id, device: devices[index]))
            }
        }
        cachedLightTime = -1
    }

    private func updateDevices(_ dt: Float, input: GameInput) {
        deviceInputHeld = input.interact
        if !input.interact { deviceInteractionLatch = false }
        // Holding E through the end of an objective cannot also activate a
        // nearby device. Release starts a new, explicit contextual action.
        if missionInteractionAvailable && input.interact { deviceInteractionLatch = true }
        if input.interact, !deviceInteractionLatch,
           let status = deviceInteractionStatus, status.interactionAvailable,
           let index = devices.firstIndex(where: { $0.id == status.id }) {
            if activeDeviceID != status.id { resetDeviceInteraction(); activeDeviceID = status.id }
            deviceInteractionTicks += 1
            devices[index].interactionProgress = Float(deviceInteractionTicks) / 120
            if deviceInteractionTicks >= loadout.deviceInteractionTicks(manual: status.manual) {
                deviceInteractionLatch = true
                if devices[index].kind == .generator {
                    devices[index].enabled.toggle(); devices[index].powered = devices[index].enabled
                    synchronizeDevicePower()
                } else {
                    devices[index].targetOpen = status.action == .openGate
                    devices[index].isMoving = true; devices[index].blockedByActor = false
                    devices[index].manualMotion = status.manual
                }
                resetDeviceInteraction()
                emit(GameEvent(kind: .deviceActivated, position: status.position, id: status.id, device: devices[index]))
            }
        } else { resetDeviceInteraction() }
        for index in devices.indices where devices[index].kind == .serviceGate && devices[index].isMoving && !devices[index].destroyed {
            advanceGate(index: index, dt: dt)
        }
    }

    private func resetDeviceInteraction() {
        if let id = activeDeviceID, let index = devices.firstIndex(where: { $0.id == id }) { devices[index].interactionProgress = 0 }
        activeDeviceID = nil; deviceInteractionTicks = 0
    }

    private func advanceGate(index: Int, dt: Float) {
        guard let definition = map.environment.devices.first(where: { $0.id == devices[index].id }),
              let ownerIndex = obstacles.firstIndex(where: { $0.id == devices[index].ownerObstacleID && !$0.destroyed }) else { return }
        let old = obstacles[ownerIndex]
        let rate: Float = devices[index].manualMotion ? 0.25 : 0.5
        let progress = clamp(devices[index].gateProgress + (devices[index].targetOpen ? 1 : -1) * rate * dt, 0, 1)
        var next = Obstacle(id: old.id, kind: old.kind,
            position: devices[index].closedPosition + definition.openOffset * progress, size: old.size)
        next.health = old.health
        let low = simd_min(old.minimum, next.minimum) - SIMD3<Float>(repeating: 0.006)
        let high = simd_max(old.maximum, next.maximum) + SIMD3<Float>(repeating: 0.006)
        func overlaps(_ position: SIMD3<Float>, height: Float, radius: Float) -> Bool {
            position.x + radius > low.x && position.x - radius < high.x &&
            position.z + radius > low.z && position.z - radius < high.z &&
            position.y + height > low.y && position.y < high.y
        }
        let blocked = overlaps(player.position, height: player.height, radius: 0.32) || enemies.contains {
            $0.health > 0 && overlaps($0.position, height: EnemyPose($0).totalHeight, radius: 0.38)
        }
        if blocked {
            if !devices[index].blockedByActor {
                devices[index].blockedByActor = true
                emit(GameEvent(kind: .gateBlocked, position: old.position, id: devices[index].id, device: devices[index]))
            }
            return
        }
        devices[index].blockedByActor = false; devices[index].gateProgress = progress
        obstacles[ownerIndex] = next
        refreshSmokeClips()
        if !navigationDirty && gateChangesNavigation(old: old, new: next) { invalidateDeviceNavigation() }
        if progress == 0 || progress == 1 {
            devices[index].isMoving = false
            emit(GameEvent(kind: .gateStopped, position: next.position, id: devices[index].id, device: devices[index]))
        }
    }

    private func invalidateDeviceNavigation() {
        navigationDirty = true
        for id in brains.keys {
            brains[id]?.pathTimer = 0; brains[id]?.path.removeAll(keepingCapacity: true)
        }
    }

    /// Only a change to an affected cell or swept link invalidates the cached
    /// graph. This also handles a gate on sloping/custom terrain; no hard-coded
    /// open-fraction threshold and no full graph rebuild on every motor tick.
    private func gateChangesNavigation(old: Obstacle, new: Obstacle) -> Bool {
        let minX = clamp(Int(floor((old.minimum.x - 2.5 - map.minimum.x) / navSpacing)), 0, navWidth - 1)
        let maxX = clamp(Int(ceil((old.maximum.x + 2.5 - map.minimum.x) / navSpacing)), 0, navWidth - 1)
        let minZ = clamp(Int(floor((old.minimum.z - 2.5 - map.minimum.z) / navSpacing)), 0, navDepth - 1)
        let maxZ = clamp(Int(ceil((old.maximum.z + 2.5 - map.minimum.z) / navSpacing)), 0, navDepth - 1)
        func blocksCell(_ box: Obstacle, _ point: SIMD3<Float>) -> Bool {
            point.y + 1.09 < box.maximum.y - 0.025 && point.y + 1.96 > box.minimum.y + 0.025 &&
            point.x + 0.48 > box.minimum.x && point.x - 0.48 < box.maximum.x &&
            point.z + 0.48 > box.minimum.z && point.z - 0.48 < box.maximum.z
        }
        func blocksLink(_ box: Obstacle, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            let offset = b - a, distance = simd_length(offset)
            return rayBox(origin: a + SIMD3(0,1.09,0), direction: offset / distance,
                minimum: box.minimum - SIMD3(0.48,0.87,0.48), maximum: box.maximum + SIMD3(0.48,-0.025,0.48))
                .map { $0.distance <= distance } ?? false
        }
        for z in minZ...maxZ { for x in minX...maxX {
            let key = z * navWidth + x, point = navigationPoint(key)
            if blocksCell(old, point) != blocksCell(new, point) { return true }
            if x + 1 < navWidth, blocksLink(old, point, navigationPoint(key+1)) != blocksLink(new, point, navigationPoint(key+1)) { return true }
            if z + 1 < navDepth, blocksLink(old, point, navigationPoint(key+navWidth)) != blocksLink(new, point, navigationPoint(key+navWidth)) { return true }
        } }
        return false
    }
}

extension CombatSimulation {
    public var alarmStatus: AlarmStatus {
        AlarmStatus(radioPowered: alarmRadioPowered, escalated: escalationReport != nil,
            assignedGuardIDs: assignedGuardIDs, reinforcementsCommitted: alarmReinforcementsCommitted,
            playerHeardEscalation: playerHeardEscalation)
    }
    private var alarmRadioPowered: Bool {
        guard let alarm = map.environment.alarm,
              let source = devices.first(where: { $0.id == alarm.radioDeviceID }) else { return false }
        return source.enabled && source.powered && !source.destroyed
    }
    private func inRadioRange(_ point: SIMD3<Float>) -> Bool {
        guard let alarm = map.environment.alarm else { return false }
        return simd_distance(point, map.grounded(alarm.radioPosition)) <= alarm.radioRange
    }
    private func reportSnapshot(_ pending: PendingContactReport, channel: ContactReportChannel) -> ContactReport {
        ContactReport(id: pending.id, enemyID: pending.enemyID, contactPosition: pending.contactPosition,
            contactTime: pending.contactTime, transmittedAt: elapsed, expiresAt: pending.contactTime + 20, channel: channel)
    }
    private func appendReport(_ report: ContactReport) {
        if contactReports.count >= 16 { contactReports.removeFirst() }
        contactReports.append(report)
    }

    private func updateContactReports() {
        guard map.environment.alarm != nil else { return }
        contactReports.removeAll { $0.expiresAt <= elapsed }
        var index = 0
        while index < pendingContactReports.count {
            var pending = pendingContactReports[index]
            guard let enemyIndex = enemies.firstIndex(where: { $0.id == pending.enemyID }),
                  var brain = brains[pending.enemyID] else { pendingContactReports.remove(at: index); continue }
            let enemy = enemies[enemyIndex], source = EnemyPose(enemy).eyePosition
            if enemy.health <= 0 || !enemy.seesPlayer || !brain.visualContact || brain.hurt > 0 ||
                !sightLine(source, eyePosition) {
                let report = reportSnapshot(pending, channel: pending.radioAtStart && !pending.radioCancelled ? .radio : .localShout)
                emit(GameEvent(kind: .contactReportInterrupted, position: source, id: pending.enemyID, contactReport: report))
                brain.reportCooldownUntil = elapsed + 2
                brains[pending.enemyID] = brain
                pendingContactReports.remove(at: index)
                continue
            }
            if pending.radioAtStart && !pending.radioCancelled && (!alarmRadioPowered || !inRadioRange(source)) {
                pending.radioCancelled = true
                let hearing = recordHearing(kind: .radio, position: source, strength: 0.5, range: 12, source: .enemy, sourceID: enemy.id)
                emit(GameEvent(kind: .contactReportInterrupted, position: source, id: enemy.id,
                    hearing: hearing, contactReport: reportSnapshot(pending, channel: .radio)))
            }
            pending.ticks += 1
            if pending.ticks < 144 { pendingContactReports[index] = pending; index += 1; continue }
            pendingContactReports.remove(at: index)
            brain.successfulReports += 1; brain.reportCooldownUntil = elapsed + 12
            brains[pending.enemyID] = brain
            let local = reportSnapshot(pending, channel: .localShout)
            let shout = recordHearing(kind: .shout, position: source, strength: 1, range: 22, source: .enemy, sourceID: enemy.id)
            appendReport(local)
            emit(GameEvent(kind: .contactReportTransmitted, position: source, id: enemy.id, hearing: shout, contactReport: local))
            deliverContactReport(local, hearing: shout)
            if pending.radioAtStart && !pending.radioCancelled && alarmRadioPowered && inRadioRange(source) {
                let radio = reportSnapshot(pending, channel: .radio)
                let hearing = recordHearing(kind: .radio, position: source, strength: 0.85, range: 16, source: .enemy, sourceID: enemy.id)
                appendReport(radio)
                emit(GameEvent(kind: .contactReportTransmitted, position: source, id: enemy.id, hearing: hearing, contactReport: radio))
                deliverContactReport(radio, hearing: hearing)
                escalateAlarm(radio, source: source, hearing: hearing)
            }
        }
        for enemy in enemies where enemy.health > 0 && enemy.seesPlayer {
            guard pendingContactReports.count < 4,
                  let brain = brains[enemy.id], brain.visualContact, brain.hurt <= 0,
                  brain.successfulReports < 2, elapsed >= brain.reportCooldownUntil,
                  !pendingContactReports.contains(where: { $0.enemyID == enemy.id }) else { continue }
            let source = EnemyPose(enemy).eyePosition
            let pending = PendingContactReport(id: nextContactReportID, enemyID: enemy.id,
                contactPosition: player.position, contactTime: elapsed, radioAtStart: alarmRadioPowered && inRadioRange(source))
            nextContactReportID += 1; pendingContactReports.append(pending)
            let hearing = recordHearing(kind: pending.radioAtStart ? .radio : .shout, position: source,
                strength: 0.7, range: pending.radioAtStart ? 16 : 20, source: .enemy, sourceID: enemy.id)
            emit(GameEvent(kind: .contactReportStarted, position: source, id: enemy.id, hearing: hearing,
                contactReport: reportSnapshot(pending, channel: pending.radioAtStart ? .radio : .localShout)))
        }
    }

    private func deliverContactReport(_ report: ContactReport, hearing: HearingStimulus) {
        guard report.expiresAt > elapsed else { return }
        for index in enemies.indices where enemies[index].health > 0 && enemies[index].id != report.enemyID {
            let ear = EnemyPose(enemies[index]).eyePosition
            let delivered = report.channel == .radio ? (alarmRadioPowered && inRadioRange(ear)) : acousticSample(for: hearing, listener: ear).audible
            guard delivered, var brain = brains[enemies[index].id], report.id > brain.lastReceivedReportID else { continue }
            brain.lastReceivedReportID = report.id
            // Receiving a message never becomes visual confirmation or grants
            // firing permission. Recent own sight/damage and loud combat clues win.
            if !enemies[index].seesPlayer && elapsed - brain.lastOwnContactTime >= 6 &&
                (brain.hearingPriority < 3 || elapsed >= brain.priorityUntil) {
                enemies[index].lastContactReport = report
                let assignedPost = brain.guardPost
                investigate(report.contactPosition, enemy: &enemies[index], brain: &brain)
                // A newer message updates knowledge, not an existing route order.
                // Real personal contact or a directly heard distraction can still
                // interrupt that order through the ordinary investigate path.
                brain.guardPost = assignedPost
                brain.hearingPriority = 2; brain.priorityUntil = elapsed + 8
            }
            brains[enemies[index].id] = brain
        }
    }

    private func escalateAlarm(_ report: ContactReport, source: SIMD3<Float>, hearing: HearingStimulus) {
        guard escalationReport == nil, report.channel == .radio, let alarm = map.environment.alarm else { return }
        escalationReport = report
        playerHeardEscalation = acousticSample(for: hearing, listener: eyePosition).audible
        // At most two currently uninvolved, informed guards receive a fixed
        // route order. The original fighter and fresh direct witnesses keep
        // their existing combat behaviour and are never reassigned mid-fight.
        for rawPost in alarm.returnGuardPosts {
            let post = map.grounded(rawPost)
            guard assignedGuardIDs.count < 2, !blocked(post, height: 1.96, radius: 0.4) else { continue }
            let candidates = enemies.indices.filter { index in
                let enemy = enemies[index]
                guard enemy.health > 0, enemy.id != report.enemyID, !enemy.seesPlayer,
                      !assignedGuardIDs.contains(enemy.id), enemy.lastContactReport?.id == report.id,
                      let brain = brains[enemy.id] else { return false }
                return elapsed - brain.lastOwnContactTime >= 6 && brain.hurt <= 0
            }.sorted { simd_distance_squared(enemies[$0].position, post) < simd_distance_squared(enemies[$1].position, post) }
            guard let index = candidates.first(where: { hasReachableRoute(from: enemies[$0].position, to: post) }),
                  var brain = brains[enemies[index].id] else { continue }
            brain.guardPost = post; brain.patrolAnchor = post; brain.pathTimer = 0
            brain.searchingInPlace = false; brain.searchAge = 0; brain.stuckTime = 0
            brains[enemies[index].id] = brain; assignedGuardIDs.append(enemies[index].id)
        }
        alarmReinforcementsCommitted = alarm.reinforcementCount
        pendingAlarmReinforcements += alarm.reinforcementCount
        emit(GameEvent(kind: .alarmEscalated, position: source, id: report.enemyID, hearing: hearing, contactReport: report,
                       alarmReportID: report.id))
        queueMissionReinforcements(alarm.reinforcementCount)
    }
}

extension CombatSimulation {
    public var operationStatus: OperationStatus? {
        guard missionKind == .operation, let operation = map.operation else { return nil }
        let preparations = operation.preparations.map { definition -> OperationPreparationStatus in
            guard let device = devices.first(where: { $0.id == definition.deviceID }) else {
                return OperationPreparationStatus(kind: definition.kind, deviceID: definition.deviceID, completed: false, unavailable: true)
            }
            let completed = definition.kind == .disableRadio ? (!device.enabled || device.destroyed) : (device.gateProgress >= 1 || device.destroyed)
            return OperationPreparationStatus(kind: definition.kind, deviceID: definition.deviceID, completed: completed, unavailable: device.destroyed && !completed)
        }
        return OperationStatus(preparations: preparations, extractions: operation.extractions.map(extractionSnapshot),
                               selectedExtractionID: selectedExtractionID)
    }

    private var presentedOperationExtraction: ExtractionDefinition? {
        guard missionKind == .operation, let exits = map.operation?.extractions else { return nil }
        if extractionReady, let active = exits.first(where: { operationExitInterruption($0) == nil }) { return active }
        if let selected = exits.first(where: { $0.id == selectedExtractionID }), !operationExitBlocked(selected) { return selected }
        let available = exits.filter { !operationExitBlocked($0) }
        return (available.isEmpty ? exits : available).min {
            horizontalDistance(player.position, $0.position) < horizontalDistance(player.position, $1.position)
        }
    }
    private func operationExitBlocked(_ exit: ExtractionDefinition) -> Bool {
        blocked(map.grounded(exit.position), height: 1.72, radius: 0.32)
    }
    private func operationExitInterruption(_ exit: ExtractionDefinition) -> MissionInterruption? {
        if operationExitBlocked(exit) { return .blocked }
        if !player.grounded || climbing != nil || abs(player.position.y - terrain.height(x: player.position.x, z: player.position.z)) >= 0.2 {
            return .notGrounded
        }
        if horizontalDistance(player.position, exit.position) >= exit.radius { return .outOfRange }
        return nil
    }
    private func extractionSnapshot(_ exit: ExtractionDefinition) -> ExtractionSnapshot {
        let position = map.grounded(exit.position), reason = operationExitInterruption(exit)
        return ExtractionSnapshot(id: exit.id, title: exit.title, detail: exit.detail, position: position, radius: exit.radius,
            requiredProgress: exit.holdDuration, progress: selectedExtractionID == exit.id ? extractionProgress : 0,
            distance: simd_distance(player.position, position), routeKind: exit.routeKind,
            unlocked: extractionReady, blocked: reason == .blocked,
            active: state == .active && missionPhase == .extract && reason == nil, interruption: reason)
    }
    private func updateOperationExtraction() {
        guard let exits = map.operation?.extractions,
              let exit = exits.first(where: { operationExitInterruption($0) == nil }) else {
            missionProgressTicks = 0; extractionProgress = 0; return
        }
        if selectedExtractionID != exit.id {
            selectedExtractionID = exit.id; missionProgressTicks = 0; extractionProgress = 0
            emit(GameEvent(kind: .extractionSelected, position: map.grounded(exit.position), extractionID: exit.id))
        }
        let requiredTicks = Int((exit.holdDuration * 120).rounded(.up))
        missionProgressTicks = min(requiredTicks, missionProgressTicks + 1)
        extractionProgress = min(exit.holdDuration, Float(missionProgressTicks) / 120)
        if missionProgressTicks == requiredTicks { finishObjectiveMission() }
    }
}

extension CombatSimulation {
    @discardableResult public func throwSmokeGrenade() -> Bool {
        // Emitter slots stay reserved between cycles, so a timed source cannot
        // evict a player's cloud or exceed the actual four-volume optical cap.
        let reserved = map.environment.smokeEmitters.count + smokeGrenades.count + smokeVolumes.filter { $0.sourceEmitterID == nil }.count
        guard state == .active, climbing == nil, smokeGrenadeCount > 0,
              smokeCooldown <= 0, reserved < SmokeVolumeState.maximumCount else { return false }
        let direction = viewDirection(yaw: player.yaw,pitch: clamp(player.pitch+0.18,-0.9,1.2))
        let grenade = SmokeGrenadeState(id: allocateID(),position: eyePosition,velocity: direction*13+SIMD3(0,2.5,0))
        smokeGrenades.append(grenade); smokeGrenadeCount -= 1; smokeCooldown = 0.7
        emit(GameEvent(kind: .throwSmoke,position: grenade.position,id: grenade.id))
        return true
    }

    private func activateSmoke(id: Int, kind: SmokeKind, origin: SIMD3<Float>, radii: SIMD3<Float>,
                               density: Float, lifetime: Float, sourceEmitterID: Int? = nil) {
        guard smokeVolumes.count < SmokeVolumeState.maximumCount else { return }
        var volume = SmokeVolumeState(id: id,kind: kind,position: origin+SIMD3(0,1.3,0),radii: radii,
            origin: origin,density: density,lifetime: lifetime,createdAt: elapsed,sourceEmitterID: sourceEmitterID)
        volume.constrain(to: obstacles,terrain: terrain)
        smokeVolumes.append(volume)
        emit(GameEvent(kind: .smokeActivated,position: origin,id: id,smoke: volume))
    }

    private func updateSmoke(_ dt: Float) {
        smokeCooldown = max(0,smokeCooldown-dt)
        var index = 0
        while index < smokeVolumes.count {
            smokeVolumes[index].age = Float(elapsed-smokeVolumes[index].createdAt)
            if elapsed + 0.0000001 >= smokeVolumes[index].createdAt + Double(smokeVolumes[index].lifetime) {
                let expired = smokeVolumes.remove(at: index)
                emit(GameEvent(kind: .smokeDissipated,position: expired.position,id: expired.id,smoke: expired))
            } else { index += 1 }
        }
        index = 0
        while index < smokeGrenades.count {
            var grenade = smokeGrenades[index]
            advanceThrowable(position: &grenade.position,velocity: &grenade.velocity,dt: dt)
            grenade.remainingTicks -= 1
            if grenade.remainingTicks <= 0 {
                smokeGrenades.remove(at: index)
                activateSmoke(id: grenade.id,kind: .smoke,origin: grenade.position,radii: SIMD3(3,2,3),density: 2.2,lifetime: 10)
            } else { smokeGrenades[index] = grenade; index += 1 }
        }
        for source in map.environment.smokeEmitters {
            guard elapsed + 0.0000001 >= Double(source.startDelay) else { continue }
            let cycle = Int(floor((elapsed-Double(source.startDelay)+0.0000001)/Double(source.interval)))
            guard smokeEmitterCycles[source.id] != cycle else { continue }
            smokeEmitterCycles[source.id] = cycle
            if let power = source.powerDeviceID,
               !devices.contains(where: { $0.id == power && $0.enabled && !$0.destroyed }) { continue }
            activateSmoke(id: allocateID(),kind: source.kind,origin: map.grounded(source.position),radii: source.radii,
                density: source.density,lifetime: source.lifetime,sourceEmitterID: source.id)
        }
        refreshSmokeClips()
    }

    private func refreshSmokeClips() {
        for index in smokeVolumes.indices { smokeVolumes[index].constrain(to: obstacles,terrain: terrain) }
    }
}


extension CombatSimulation {
    /// Render historical points only while the player can still see that point.
    /// Never query the target's current pose, health, awareness or position here.
    public var visibleReconMarks: [ReconMark] {
        reconMarks.filter { elapsed < $0.expiresAt && sightLine(eyePosition,$0.position) &&
            !smokeVisibility(from: eyePosition,to: $0.position).opaque }
    }

    @discardableResult public func useClassGadget() -> Bool {
        guard state == .active, climbing == nil, !isSprinting else { return false }
        switch loadout.operatorClass {
        case .assault: return throwSmokeGrenade()
        case .recon: return observeContact()
        case .engineer: return placeBreachCharge()
        }
    }

    private func observeContact() -> Bool {
        guard isAiming, elapsed+1e-9 >= reconReadyAt else { return false }
        let origin = eyePosition, direction = viewDirection(yaw: player.yaw,pitch: player.pitch)
        var closest = wallHit(origin: origin,direction: direction,maximumDistance: 70,purpose: .sight).distance
        var targetID: Int?
        for enemy in enemies where enemy.health > 0 {
            let pose = EnemyPose(enemy)
            for (height,radius) in [(pose.headHeight,Float(0.25)),(pose.bodyHeight,0.43-enemy.crouchAmount*0.07),(pose.hipHeight,Float(0.34))] {
                let distance = raySphere(origin: origin,direction: direction,center: enemy.position+SIMD3(0,height,0),radius: radius)
                if distance < closest { closest = distance; targetID = enemy.id }
            }
        }
        guard let targetID else { return false }
        let point = origin+direction*closest
        guard !smokeVisibility(from: origin,to: point).opaque else { return false }
        let mark = ReconMark(id: allocateID(),targetID: targetID,position: point,createdAt: elapsed)
        reconMarks.removeAll { $0.targetID == targetID || elapsed >= $0.expiresAt }
        if reconMarks.count >= ReconMark.maximumCount { reconMarks.removeFirst() }
        reconMarks.append(mark); reconReadyAt = elapsed+0.75
        emit(GameEvent(kind: .reconMarked,position: point,id: mark.id,mark: mark))
        return true
    }

    private func placeBreachCharge() -> Bool {
        guard player.grounded, breachChargeCount > 0, breachCharges.count < BreachChargeState.maximumCount else { return false }
        let direction = viewDirection(yaw: player.yaw,pitch: player.pitch)
        let hit = wallHit(origin: eyePosition,direction: direction,maximumDistance: 2.001)
        guard hit.distance <= 2, abs(hit.normal.y) < 0.1, let index = hit.obstacleIndex,
              map.breaches.contains(where: { $0.ownerObstacleID == obstacles[index].id }),
              !obstacles[index].destroyed else { return false }
        let surface = eyePosition+direction*hit.distance, owner = obstacles[index]
        let horizontal = abs(hit.normal.x) > 0.5 ? surface.z : surface.x
        let low = abs(hit.normal.x) > 0.5 ? owner.minimum.z : owner.minimum.x
        let high = abs(hit.normal.x) > 0.5 ? owner.maximum.z : owner.maximum.x
        guard horizontal >= low+0.07, horizontal <= high-0.07,
              surface.y >= owner.minimum.y+0.05, surface.y <= owner.maximum.y-0.05 else { return false }
        let point = surface+hit.normal*0.05
        let charge = BreachChargeState(id: allocateID(),ownerObstacleID: obstacles[index].id,
            position: point,normal: hit.normal,createdAt: elapsed)
        breachCharges.append(charge); breachChargeCount -= 1
        emit(GameEvent(kind: .breachChargePlaced,position: point,id: charge.id,charge: charge))
        return true
    }

    private func updateClassGadgets(_ dt: Float) {
        reconMarks.removeAll { elapsed+1e-9 >= $0.expiresAt }
        var index = 0
        while index < breachCharges.count {
            var charge = breachCharges[index]
            if charge.attached && !obstacles.contains(where: { $0.id == charge.ownerObstacleID && !$0.destroyed }) {
                charge.attached = false
            }
            if !charge.attached {
                // Preserve the same physical centre during detachment. The
                // swept flight is conservative; the final thin housing rests
                // 1mm above its actual support, including elevated roofs.
                if charge.resting {
                    let support = wallHit(origin: charge.position,direction: SIMD3(0,-1,0),maximumDistance: 0.2)
                    if !(support.hitGround || support.obstacleIndex != nil) || support.distance*support.normal.y > 0.033 { charge.resting = false }
                }
                if !charge.resting {
                    advanceThrowable(position: &charge.position,velocity: &charge.velocity,dt: dt)
                    let support = wallHit(origin: charge.position,direction: SIMD3(0,-1,0),maximumDistance: 0.12)
                    if support.distance < 0.11 && abs(charge.velocity.y) < 0.55 && simd_length(charge.velocity) < 0.8 {
                        let contact = charge.position-SIMD3(0,support.distance,0)
                        charge.normal = support.normal; charge.position = contact+support.normal*0.031
                        charge.velocity = .zero; charge.resting = true
                    }
                }
            }
            charge.remainingTicks -= 1
            if charge.remainingTicks <= 0 {
                breachCharges.remove(at: index)
                emit(GameEvent(kind: .breachChargeDetonated,position: charge.position,id: charge.id,charge: charge))
                explode(at: charge.position)
            } else { breachCharges[index] = charge; index += 1 }
        }
    }
}
