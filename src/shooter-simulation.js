// Renderer-independent combat rules. Metres, seconds, and a fixed 120 Hz step.
export const WEAPONS = {
  rifle: { name: 'AR-4 VANGUARD', label: 'STURMGEWEHR', capacity: 30, reserve: 210, damage: 28, interval: .105, reload: 1.8, spread: .009 },
  sniper: { name: 'M82 SENTINEL', label: 'SCHARFSCHÜTZENGEWEHR', capacity: 5, reserve: 35, damage: 105, interval: 1.1, reload: 2.6, spread: .021 },
};
export const ARENA = { minX: -38, maxX: 38, minZ: -42, maxZ: 42 };
export const EXTRACTION = { x: 0, z: -35, radius: 3.5 };
export const OBSTACLES = [
  { type: 'bunker', x: -22, z: -12, w: 13, d: 13, h: 5.6 },
  { type: 'bunker', x: 24, z: -27, w: 12, d: 14, h: 7.2 },
  { type: 'container', x: -15, z: 14, w: 3.6, d: 11, h: 3.1 },
  { type: 'container', x: 15, z: -5, w: 11, d: 3.6, h: 3.1 },
  { type: 'container', x: -25, z: 26, w: 9, d: 3.6, h: 3.1 },
  { type: 'barrier', x: -3.9, z: 18, w: 5.4, d: .85, h: 1.05 },
  { type: 'barrier', x: 5.5, z: 6, w: 5.8, d: .85, h: 1.05 },
  { type: 'barrier', x: -4, z: -9, w: 5.8, d: .85, h: 1.05 },
  { type: 'barrier', x: 4.5, z: -24, w: 5.4, d: .85, h: 1.05 },
  { type: 'crates', x: 20, z: 19, w: 3.2, d: 2.6, h: 1.9 },
  { type: 'crates', x: -9, z: -25, w: 2.8, d: 2.8, h: 1.3 },
  { type: 'crates', x: 27, z: 7, w: 3, d: 3, h: 1.2 },
  { type: 'crates', x: -29, z: 4, w: 3.2, d: 3.2, h: 1.4 },
  { type: 'barrier', x: -12, z: -35, w: 7, d: .8, h: 1.05 },
  { type: 'barrier', x: 12, z: -35, w: 7, d: .8, h: 1.05 },
  { type: 'barrel', x: 10, z: -1, w: .8, d: .8, h: 1.15 },
  { type: 'barrel', x: -11, z: 11, w: .8, d: .8, h: 1.15 },
  { type: 'barrel', x: 18, z: 17, w: .8, d: .8, h: 1.15 },
  { type: 'barrel', x: -12, z: -22, w: .8, d: .8, h: 1.15 },
];
const SPAWNS = [{ x: 9, z: 1 }, { x: -8, z: 5 }, { x: 25, z: -10 }, { x: -11, z: -17 }, { x: 2, z: -30 }, { x: -30, z: 14 }, { x: 30, z: 21 }, { x: 11, z: -30 }, { x: -28, z: -30 }];
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const distance = (a, b) => Math.hypot(a.x - b.x, a.z - b.z);
export const direction = (yaw, pitch) => ({ x: -Math.sin(yaw) * Math.cos(pitch), y: Math.sin(pitch), z: -Math.cos(yaw) * Math.cos(pitch) });
export function rayBox(origin, dir, box, padding = 0) {
  const min = { x: box.x - box.w / 2 - padding, y: (box.y || 0) - padding, z: box.z - box.d / 2 - padding };
  const max = { x: box.x + box.w / 2 + padding, y: (box.y || 0) + box.h + padding, z: box.z + box.d / 2 + padding };
  let near = 0, far = Infinity, normal = { x: 0, y: 1, z: 0 };
  for (const axis of ['x', 'y', 'z']) {
    if (Math.abs(dir[axis]) < 1e-9) { if (origin[axis] < min[axis] || origin[axis] > max[axis]) return null; continue; }
    const a = (min[axis] - origin[axis]) / dir[axis], b = (max[axis] - origin[axis]) / dir[axis];
    if (Math.min(a, b) > near) { near = Math.min(a, b); normal = { x: 0, y: 0, z: 0 }; normal[axis] = dir[axis] > 0 ? -1 : 1; }
    far = Math.min(far, Math.max(a, b));
    if (near > far || far < 0) return null;
  }
  return { distance: near, normal };
}
function raySphere(origin, dir, center, radius) {
  const x = origin.x - center.x, y = origin.y - center.y, z = origin.z - center.z;
  const b = x * dir.x + y * dir.y + z * dir.z, c = x * x + y * y + z * z - radius * radius, d = b * b - c;
  if (d < 0) return Infinity;
  const t = -b - Math.sqrt(d);
  return t >= 0 ? t : c <= 0 ? 0 : Infinity;
}
export function wallHit(origin, dir, obstacles = OBSTACLES, max = 150, padding = 0) {
  let hit = { distance: max, normal: { x: 0, y: 1, z: 0 }, obstacle: null };
  for (const obstacle of obstacles) {
    const result = rayBox(origin, dir, obstacle, padding);
    if (result && result.distance < hit.distance) hit = { ...result, obstacle };
  }
  if (dir.y < 0 && origin.y > 0) {
    const t = (padding - origin.y) / dir.y;
    if (t >= 0 && t < hit.distance) hit = { distance: t, normal: { x: 0, y: 1, z: 0 }, obstacle: 'ground' };
  }
  return hit;
}
export function clearLine(a, b, obstacles = OBSTACLES) {
  const length = Math.hypot(b.x - a.x, b.y - a.y, b.z - a.z);
  if (length < .001) return true;
  return wallHit(a, { x: (b.x - a.x) / length, y: (b.y - a.y) / length, z: (b.z - a.z) / length }, obstacles, length).distance >= length - .01;
}

export class ShooterSimulation {
  constructor({ difficulty = 'normal', seed = 1745, obstacles = OBSTACLES } = {}) {
    this.difficulty = difficulty; this.seed = seed;
    this.obstacles = obstacles.map((b, index) => ({ ...b, id: `cover-${index}`, health: b.type === 'bunker' ? Infinity : b.type === 'container' ? 700 : b.type === 'barrier' ? 280 : b.type === 'barrel' ? 55 : 110, destroyed: false }));
    this.player = { x: 0, y: 0, z: 32, vy: 0, height: 1.72, prone: false, grounded: true, health: 100, stamina: 100, yaw: 0, pitch: 0, lastHit: -20 };
    this.weapons = Object.fromEntries(Object.entries(WEAPONS).map(([id, w]) => [id, { ammo: w.capacity, reserve: w.reserve, cooldown: 0, reload: 0 }]));
    this.weapon = 'rifle'; this.aiming = false; this.grenades = 4; this.grenadeCooldown = 0;
    this.projectiles = []; this.enemies = []; this.events = []; this.time = 0; this.score = 0; this.kills = 0; this.shots = 0; this.hits = 0;
    this.wave = 0; this.intermission = 1.4; this.state = 'active'; this.extractionProgress = 0; this.nextId = 1; this.accumulator = 0;
    this.moving = false; this.sprinting = false; this.pickups = [];
  }
  random() { this.seed = (Math.imul(1664525, this.seed) + 1013904223) >>> 0; return this.seed / 4294967296; }
  get eye() { const p = this.player; return { x: p.x, y: p.y + p.height - .1, z: p.z }; }
  get alive() { return this.enemies.filter(e => e.health > 0); }
  get hidden() { return this.alive.length > 0 && this.alive.every(e => !e.seesPlayer) && this.time - (this.lastShot ?? -10) > 1.5; }
  get cover() { return this.obstacles.filter(b => !b.destroyed); }
  emit(type, data = {}) { this.events.push({ ...data, type }); }
  switchWeapon(id) { if (!WEAPONS[id] || this.state !== 'active') return; this.weapon = id; this.aiming = false; }
  reload() {
    const w = this.weapons[this.weapon], spec = WEAPONS[this.weapon];
    if (this.state !== 'active' || w.reload > 0 || w.ammo >= spec.capacity || w.reserve <= 0) return false;
    w.reload = spec.reload; this.aiming = false; this.emit('reload'); return true;
  }
  toggleProne() {
    if (this.state !== 'active' || !this.player.grounded) return;
    const p = this.player;
    if (p.prone && this.blocked(p.x, p.y, p.z, 1.72, .3)) return;
    p.prone = !p.prone; this.emit('stance');
  }
  jump() {
    const p = this.player;
    if (this.state !== 'active' || this.climbing || !p.grounded || p.stamina < 12) return false;
    if (p.prone) { this.toggleProne(); return false; }
    p.vy = 6.8; p.grounded = false; p.stamina -= 12; this.emit('jump'); return true;
  }
  blocked(x, y, z, height = 1.72, radius = .32) {
    if (x < ARENA.minX + radius || x > ARENA.maxX - radius || z < ARENA.minZ + radius || z > ARENA.maxZ - radius) return true;
    return this.cover.some(b => y < (b.y || 0) + b.h - .025 && y + height > (b.y || 0) + .025 && x + radius > b.x - b.w / 2 && x - radius < b.x + b.w / 2 && z + radius > b.z - b.d / 2 && z - radius < b.z + b.d / 2);
  }
  mantleTarget() {
    const p = this.player, facing = direction(p.yaw, 0);
    for (const b of this.cover) {
      if (b.h - p.y < .55 || b.h - p.y > 3.3) continue;
      const x = clamp(p.x, b.x - b.w / 2, b.x + b.w / 2), z = clamp(p.z, b.z - b.d / 2, b.z + b.d / 2);
      const d = Math.hypot(p.x - x, p.z - z);
      if (d > 1.25 || d < .01 || ((x - p.x) * facing.x + (z - p.z) * facing.z) / d < .35) continue;
      const target = { x: clamp(x + (b.x - x) * .35, b.x - b.w / 2 + .6, b.x + b.w / 2 - .6), y: b.h, z: clamp(z + (b.z - z) * .35, b.z - b.d / 2 + .6, b.z + b.d / 2 - .6) };
      if (!this.blocked(target.x, target.y, target.z, 1.72)) return { ...target, obstacle: b };
    }
    return null;
  }
  mantle() {
    if (this.state !== 'active' || this.climbing || !this.player.grounded) return false;
    const target = this.mantleTarget(); if (!target) return false;
    this.climbing = { from: { ...this.player }, to: target, progress: 0, duration: .75 };
    this.player.prone = false; this.player.vy = 0; this.aiming = false; this.emit('climb'); return true;
  }
  move(body, dx, dz, height = 1.72, radius = .32) {
    if (!this.blocked(body.x + dx, body.y || 0, body.z, height, radius)) body.x += dx;
    if (!this.blocked(body.x, body.y || 0, body.z + dz, height, radius)) body.z += dz;
  }
  traceShot(origin, dir) {
    let result = wallHit(origin, dir, this.cover);
    for (const enemy of this.alive) {
      for (const [height, radius, head] of [[1.73, .25, true], [1.18, .43, false], [.55, .34, false]]) {
        const t = raySphere(origin, dir, { x: enemy.x, y: height, z: enemy.z }, radius);
        if (t < result.distance) result = { distance: t, enemy, head };
      }
    }
    return { ...result, point: { x: origin.x + dir.x * result.distance, y: origin.y + dir.y * result.distance, z: origin.z + dir.z * result.distance } };
  }
  fire() {
    if (this.state !== 'active' || this.sprinting || this.climbing) return false;
    const w = this.weapons[this.weapon], spec = WEAPONS[this.weapon];
    if (w.reload > 0 || w.cooldown > 0) return false;
    if (!w.ammo) { this.reload(); return false; }
    w.ammo--; w.cooldown = spec.interval; this.shots++; this.lastShot = this.time;
    for (const e of this.alive) if (distance(e, this.player) < 38) { e.lastKnown = { x: this.player.x, z: this.player.z }; e.memory = 7; e.alert = true; }
    const spread = this.aiming ? (this.weapon === 'sniper' ? .0002 : .0017) : spec.spread;
    const dir = direction(this.player.yaw + (this.random() - .5) * spread, this.player.pitch + (this.random() - .5) * spread);
    const cameraHit = this.traceShot(this.eye, dir);
    // Check the actual muzzle-to-target segment so nearby cover also blocks a shot.
    const muzzle = { x: this.eye.x + Math.cos(this.player.yaw) * .22 + dir.x * .5, y: this.eye.y - .17 + dir.y * .5, z: this.eye.z - Math.sin(this.player.yaw) * .22 + dir.z * .5 };
    const eye = this.eye, barrelLength = Math.hypot(muzzle.x - eye.x, muzzle.y - eye.y, muzzle.z - eye.z);
    const barrelDirection = { x: (muzzle.x - eye.x) / barrelLength, y: (muzzle.y - eye.y) / barrelLength, z: (muzzle.z - eye.z) / barrelLength };
    const barrelHit = wallHit(eye, barrelDirection, this.cover, barrelLength);
    let hit;
    if (barrelHit.obstacle) {
      // A muzzle inside cover still hits its near surface. Retain that object
      // for damage; this round must stop even if it destroys the cover.
      hit = { ...barrelHit, point: { x: eye.x + barrelDirection.x * barrelHit.distance, y: eye.y + barrelDirection.y * barrelHit.distance, z: eye.z + barrelDirection.z * barrelHit.distance } };
    } else {
      const length = Math.hypot(cameraHit.point.x - muzzle.x, cameraHit.point.y - muzzle.y, cameraHit.point.z - muzzle.z);
      hit = this.traceShot(muzzle, length > 1e-9 ? { x: (cameraHit.point.x - muzzle.x) / length, y: (cameraHit.point.y - muzzle.y) / length, z: (cameraHit.point.z - muzzle.z) / length } : dir);
    }
    if (hit.enemy) { this.hits++; this.damageEnemy(hit.enemy, spec.damage * (hit.head ? 2.4 : 1), hit.head); }
    if (hit.obstacle && hit.obstacle !== 'ground') this.damageCover(hit.obstacle, spec.damage);
    this.emit('shot', { weapon: this.weapon, from: muzzle, to: hit.point, hit: !!hit.enemy, head: !!hit.head });
    return true;
  }
  damageEnemy(enemy, damage, head = false) {
    if (enemy.health <= 0) return;
    enemy.health -= damage; enemy.alert = true; enemy.hurt = .18;
    if (enemy.health <= 0) {
      this.kills++; const points = head ? 150 : 100; this.score += points; enemy.deadAt = this.time;
      this.emit('kill', { head, points, x: enemy.x, z: enemy.z });
      if (this.kills % 3 === 0) this.pickups.push({ x: enemy.x, z: enemy.z, id: this.nextId++ });
    }
  }
  damageCover(obstacle, damage) {
    if (obstacle.destroyed || !Number.isFinite(obstacle.health)) return;
    obstacle.health -= damage;
    this.emit('cover-hit', { id: obstacle.id, x: obstacle.x, y: obstacle.h * .5, z: obstacle.z });
    if (obstacle.health <= 0) {
      obstacle.destroyed = true; this.score += 25; this.emit('destroy', { ...obstacle });
      if (obstacle.type === 'barrel') this.explode({ x: obstacle.x, y: .55, z: obstacle.z });
    }
  }
  throwGrenade() {
    if (this.state !== 'active' || this.climbing || this.grenades <= 0 || this.grenadeCooldown > 0) return false;
    const dir = direction(this.player.yaw, clamp(this.player.pitch + .22, -.9, 1.2)), eye = this.eye;
    const g = { id: this.nextId++, ...eye, vx: dir.x * 16, vy: dir.y * 16 + 2.5, vz: dir.z * 16, fuse: 2.8 };
    this.projectiles.push(g); this.grenades--; this.grenadeCooldown = .7; this.emit('throw'); return true;
  }
  explode(g) {
    const center = { x: g.x, y: g.y + .18, z: g.z };
    for (const e of this.alive) {
      const target = { x: e.x, y: 1.05, z: e.z }, d = Math.hypot(e.x - center.x, target.y - center.y, e.z - center.z);
      if (d < 8 && clearLine(center, target, this.cover)) this.damageEnemy(e, 220 * (1 - d / 8));
    }
    const p = this.eye, d = Math.hypot(p.x - center.x, p.y - center.y, p.z - center.z);
    if (d < 8 && clearLine(center, p, this.cover)) this.damagePlayer(145 * (1 - d / 8), center);
    const damagedCover = this.cover.filter(b => Number.isFinite(b.health)).map(b => {
      const target = { x: clamp(center.x, b.x - b.w / 2, b.x + b.w / 2), y: clamp(center.y, 0, b.h), z: clamp(center.z, b.z - b.d / 2, b.z + b.d / 2) };
      const dist = Math.hypot(target.x - center.x, target.y - center.y, target.z - center.z);
      return { b, dist, visible: dist < 8 && clearLine(center, target, this.cover.filter(other => other !== b)) };
    });
    for (const { b, dist, visible } of damagedCover) if (visible) this.damageCover(b, 850 * (1 - dist / 8));
    this.emit('explosion', { ...center });
  }
  damagePlayer(amount, from) {
    if (this.state !== 'active') return;
    const p = this.player; p.health = Math.max(0, p.health - amount); p.lastHit = this.time;
    this.emit('damage', { amount, from });
    if (p.health <= 0) { this.state = 'lost'; this.emit('lose'); }
  }
  spawnWave() {
    this.wave++; this.intermission = 0;
    this.enemies = this.enemies.filter(e => e.health > 0 || this.time - e.deadAt < 5);
    const count = 3 + this.wave * 2;
    for (let i = 0; i < count; i++) {
      // Reinforcements never materialize next to the player or inside cover.
      const candidates = SPAWNS.map((p, index) => ({ ...p, index })).filter(p => distance(p, this.player) > 14 && !this.blocked(p.x, 0, p.z, 1.9, .4));
      const point = candidates.length ? candidates[i % candidates.length] : SPAWNS[i % SPAWNS.length];
      let position = { x: point.x, z: point.z };
      for (let attempt = 0; attempt < 20; attempt++) {
        const candidate = { x: point.x + (attempt ? (this.random() - .5) * 8 : 0), z: point.z + (attempt ? (this.random() - .5) * 8 : 0) };
        if (!this.blocked(candidate.x, 0, candidate.z, 1.9, .4) && this.alive.every(e => distance(e, candidate) > 1.2) && distance(candidate, this.player) > 12) { position = candidate; break; }
      }
      this.enemies.push({ ...position, id: this.nextId++, y: 0, health: 90 + this.wave * 10, yaw: 0, cooldown: 2 + i * .35, windup: 0, alert: false, path: [], pathTimer: 0, stride: 0, hurt: 0, moving: false, side: i % 2 ? 1 : -1 });
    }
    this.emit('wave', { wave: this.wave, count });
  }
  findPath(from, to) {
    // A small navigation grid routes soldiers around containers and buildings.
    const size = 39, cell = 2, min = -38;
    const grid = p => ({ x: clamp(Math.round((p.x - min) / cell), 0, size - 1), z: clamp(Math.round((p.z - min) / cell), 0, size - 1) });
    const start = grid(from), end = grid(to), key = p => p.z * size + p.x;
    const queue = [start], visited = new Set([key(start)]), previous = new Map(); let found = start, best = Infinity;
    for (let index = 0; index < queue.length; index++) {
      const p = queue[index], d = Math.abs(p.x - end.x) + Math.abs(p.z - end.z);
      if (d < best) { found = p; best = d; } if (d === 0) break;
      for (const [dx, dz] of [[0, -1], [1, 0], [0, 1], [-1, 0]]) {
        const next = { x: p.x + dx, z: p.z + dz }, k = key(next);
        if (next.x < 0 || next.x >= size || next.z < 0 || next.z >= size || visited.has(k) || this.blocked(min + next.x * cell, 0, min + next.z * cell, 1.9, .48)) continue;
        visited.add(k); previous.set(k, p); queue.push(next);
      }
    }
    const path = []; let p = found;
    while (p && key(p) !== key(start)) { path.unshift({ x: min + p.x * cell, z: min + p.z * cell }); p = previous.get(key(p)); }
    return path;
  }
  updateEnemies(dt) {
    for (const e of this.alive) {
      const p = this.player, dist = distance(e, p); e.hurt = Math.max(0, e.hurt - dt); e.cooldown -= dt; e.pathTimer -= dt;
      const origin = { x: e.x, y: 1.68, z: e.z }, visible = dist < 48 && clearLine(origin, this.eye, this.cover);
      e.seesPlayer = visible;
      if (visible) { e.lastKnown = { x: p.x, z: p.z }; e.memory = 6; e.alert = true; }
      else e.memory = Math.max(0, (e.memory || 0) - dt);
      if (!e.memory) e.alert = false;
      let pursuit = e.lastKnown || p;
      e.coverCooldown = Math.max(0, (e.coverCooldown || 0) - dt);
      e.coverTimer = Math.max(0, (e.coverTimer || 0) - dt);
      if (e.hurt > 0 && e.health < 65 && !e.coverCooldown) {
        const hidingSpots = this.cover.filter(b => b.h > 1.9).flatMap(b => [
          { x: b.x - b.w / 2 - .65, z: b.z }, { x: b.x + b.w / 2 + .65, z: b.z },
          { x: b.x, z: b.z - b.d / 2 - .65 }, { x: b.x, z: b.z + b.d / 2 + .65 },
        ]).filter(t => distance(e, t) < 12 && !this.blocked(t.x, 0, t.z, 1.9, .4) && !clearLine({ ...t, y: 1.68 }, this.eye, this.cover));
        hidingSpots.sort((a, b) => distance(e, a) - distance(e, b));
        e.coverGoal = hidingSpots[0]; e.coverTimer = 5; e.coverCooldown = 12; e.pathTimer = 0;
      }
      if (e.coverGoal && e.coverTimer > 0) pursuit = e.coverGoal;
      e.yaw = Math.atan2(pursuit.x - e.x, pursuit.z - e.z); e.moving = false;
      if (e.windup > 0) {
        e.windup -= dt;
        if (e.windup <= 0 && visible && this.state === 'active') {
          const accuracy = (this.difficulty === 'easy' ? .31 : this.difficulty === 'hard' ? .8 : .56) * (p.prone ? .52 : 1) * (this.sprinting ? .6 : 1) * (p.grounded ? 1 : .65);
          const hit = this.random() < accuracy;
          const target = { ...this.eye };
          if (!hit) { target.x += (this.random() > .5 ? 1 : -1) * (1 + this.random()); target.y += .5; }
          this.emit('enemy-shot', { from: origin, to: target });
          if (hit) this.damagePlayer(this.difficulty === 'easy' ? 6 : this.difficulty === 'hard' ? 13 : 9, origin);
          e.cooldown = 1.1 + this.random() * 1.7;
        }
      } else if (visible && dist < 42 && e.cooldown <= 0) { e.windup = .65; this.emit('enemy-aim', { id: e.id }); }
      if (!e.alert || e.windup > 0) continue;
      if (!visible || dist > 19 || (e.coverGoal && e.coverTimer > 0)) {
        if (e.pathTimer <= 0) { e.path = this.findPath(e, pursuit); e.pathTimer = 1.2 + this.random() * .6; }
        const target = e.path[0];
        if (target) {
          const length = distance(e, target);
          if (length < .2) e.path.shift();
          else { const speed = Math.min(length, dt * (2.5 + this.wave * .23)); this.move(e, (target.x - e.x) / length * speed, (target.z - e.z) / length * speed, 1.9, .38); e.moving = true; }
        }
      } else {
        const before = { x: e.x, z: e.z };
        const strafe = e.side * .85 * dt, retreat = dist < 9 ? -1.6 * dt : 0;
        this.move(e, Math.cos(e.yaw) * strafe + Math.sin(e.yaw) * retreat, -Math.sin(e.yaw) * strafe + Math.cos(e.yaw) * retreat, 1.9, .38);
        e.moving = distance(e, before) > .001;
        if (!e.moving) e.side *= -1;
      }
      if (e.moving) e.stride += dt * 8;
    }
  }
  tick(dt, input) {
    if (this.state !== 'active') return;
    this.time += dt; const p = this.player;
    p.yaw = input.yaw ?? p.yaw; p.pitch = clamp(input.pitch ?? p.pitch, -1.45, 1.45);
    this.aiming = !!input.aim && !this.weapons[this.weapon].reload && !this.climbing;
    const forward = input.forward || 0, side = input.side || 0, length = Math.hypot(forward, side);
    this.moving = length > 0;
    if (p.stamina <= 1) p.exhausted = true;
    if (p.exhausted && p.stamina >= 25) p.exhausted = false;
    this.sprinting = !!input.sprint && !p.prone && !this.aiming && !p.exhausted && p.stamina > 1 && forward > 0 && length > 0 && !this.climbing;
    const speed = p.prone ? 1.65 : this.sprinting ? 7.5 : this.aiming ? 2.8 : 4.7;
    if (length && !this.climbing) this.move(p, (-Math.sin(p.yaw) * forward + Math.cos(p.yaw) * side) / length * speed * dt, (-Math.cos(p.yaw) * forward - Math.sin(p.yaw) * side) / length * speed * dt, p.height);
    p.height += ((p.prone ? .57 : 1.72) - p.height) * Math.min(1, dt * 15);
    p.stamina = clamp(p.stamina + (this.sprinting ? -19 : 15) * dt, 0, 100);
    if (this.climbing) {
      const c = this.climbing; c.progress = Math.min(c.duration, c.progress + dt);
      const t = c.progress / c.duration, vertical = Math.min(1, t * 1.6), horizontal = clamp((t - .3) / .7, 0, 1);
      p.x = c.from.x + (c.to.x - c.from.x) * horizontal; p.z = c.from.z + (c.to.z - c.from.z) * horizontal; p.y = c.from.y + (c.to.y - c.from.y + .12) * Math.sin(vertical * Math.PI / 2); p.grounded = false;
      if (t >= 1 || c.to.obstacle.destroyed) { p.y = c.to.y; this.climbing = null; }
    }
    const oldY = p.y; if (!this.climbing) { p.vy -= 17 * dt; p.y += p.vy * dt; }
    let floor = 0;
    for (const b of this.cover) if (p.x + .28 > b.x - b.w / 2 && p.x - .28 < b.x + b.w / 2 && p.z + .28 > b.z - b.d / 2 && p.z - .28 < b.z + b.d / 2 && oldY >= (b.y || 0) + b.h - .04) floor = Math.max(floor, (b.y || 0) + b.h);
    if (p.y <= floor) { if (!p.grounded && p.vy < -4) this.emit('land'); p.y = floor; p.vy = 0; p.grounded = true; } else p.grounded = false;
    if (this.time - p.lastHit > 5.5) p.health = Math.min(100, p.health + dt * 8);
    for (const [id, w] of Object.entries(this.weapons)) {
      w.cooldown = Math.max(0, w.cooldown - dt);
      if (w.reload > 0) {
        w.reload = Math.max(0, w.reload - dt);
        if (!w.reload) { const amount = Math.min(WEAPONS[id].capacity - w.ammo, w.reserve); w.ammo += amount; w.reserve -= amount; this.emit('reload-complete'); }
      }
    }
    this.grenadeCooldown = Math.max(0, this.grenadeCooldown - dt);
    if (input.fire) this.fire();
    for (const g of this.projectiles) {
      g.fuse -= dt; g.vy -= 13 * dt;
      let remaining = dt;
      for (let bounce = 0; bounce < 3 && remaining > .0001; bounce++) {
        const speed = Math.hypot(g.vx, g.vy, g.vz), dir = { x: g.vx / speed, y: g.vy / speed, z: g.vz / speed };
        const hit = wallHit(g, dir, this.cover, speed * remaining, .09), travel = Math.max(0, hit.distance - .002);
        g.x += dir.x * travel; g.y += dir.y * travel; g.z += dir.z * travel;
        if (!hit.obstacle) break;
        remaining -= hit.distance / speed;
        const dot = g.vx * hit.normal.x + g.vy * hit.normal.y + g.vz * hit.normal.z;
        g.vx = (g.vx - 1.5 * dot * hit.normal.x) * .72; g.vy = (g.vy - 1.5 * dot * hit.normal.y) * .72; g.vz = (g.vz - 1.5 * dot * hit.normal.z) * .72;
        g.x += hit.normal.x * .004; g.y += hit.normal.y * .004; g.z += hit.normal.z * .004;
      }
      g.x = clamp(g.x, ARENA.minX, ARENA.maxX); g.z = clamp(g.z, ARENA.minZ, ARENA.maxZ); g.y = Math.max(.09, g.y);
      if (g.fuse <= 0) this.explode(g);
    }
    this.projectiles = this.projectiles.filter(g => g.fuse > 0);
    if (this.state !== 'active') return;
    this.updateEnemies(dt);
    if (this.state !== 'active') return;
    this.pickups = this.pickups.filter(pack => {
      if (distance(p, pack) > 1.8) return true;
      this.weapons.rifle.reserve = Math.min(300, this.weapons.rifle.reserve + 45); this.weapons.sniper.reserve = Math.min(50, this.weapons.sniper.reserve + 5); this.emit('supply'); return false;
    });
    if (!this.alive.length && this.wave < 3) {
      if (!this.intermission) { this.intermission = 7; p.health = Math.min(100, p.health + 25); this.grenades = Math.min(4, this.grenades + 2); this.weapons.rifle.reserve += 60; this.weapons.sniper.reserve += 10; this.emit('wave-clear'); }
      this.intermission -= dt;
      if (this.intermission <= 0) this.spawnWave();
    }
    if (this.wave === 3 && !this.alive.length) {
      if (!this.extractionAnnounced) { this.extractionAnnounced = true; this.emit('extract'); }
      this.extractionProgress = distance(p, EXTRACTION) < EXTRACTION.radius ? this.extractionProgress + dt : 0;
      if (this.extractionProgress >= 3) { this.state = 'won'; this.score += 500; this.emit('win'); }
    }
  }
  step(dt, input = {}) {
    this.accumulator += Math.max(0, Math.min(dt, .15));
    while (this.accumulator >= 1 / 120) { this.tick(1 / 120, input); this.accumulator -= 1 / 120; }
  }
}
