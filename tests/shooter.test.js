import test from 'node:test';
import assert from 'node:assert/strict';
import { ShooterSimulation, WEAPONS, EXTRACTION, OBSTACLES, clearLine, direction } from '../src/shooter-simulation.js';

function advance(sim, seconds, input = {}) { for (let t = 0; t < seconds - 1e-7; t += 1 / 120) sim.step(1 / 120, input); }
function quiet(options = {}) { const sim = new ShooterSimulation({ obstacles: [], seed: 45, ...options }); sim.intermission = 999; return sim; }
function enemy(sim, x = 0, z = 22) {
  const e = { x, y: 0, z, id: 400 + sim.enemies.length, health: 100, yaw: 0, cooldown: 999, windup: 0, path: [], pathTimer: 0, stride: 0, hurt: 0, side: 1 }; sim.enemies.push(e); return e;
}
test('normalised walking, sprint, prone movement, jumping and gravity remain frame-rate independent', () => {
  const a = quiet(), b = quiet();
  advance(a, 1, { forward: 1 }); advance(b, 1, { forward: 1, side: 1 });
  assert.ok(Math.abs(Math.hypot(a.player.x, a.player.z - 32) - Math.hypot(b.player.x, b.player.z - 32)) < .001);
  const sprint = quiet(); advance(sprint, 1, { forward: 1, sprint: true }); assert.ok(sprint.player.z < a.player.z); assert.ok(sprint.player.stamina < 100);
  const prone = quiet(); prone.toggleProne(); advance(prone, 1, { forward: 1, sprint: true }); assert.ok(prone.player.z > a.player.z); assert.ok(prone.player.height < .58);
  assert.equal(prone.jump(), false); assert.equal(prone.player.prone, false);
  assert.equal(a.jump(), true); assert.equal(a.jump(), false); advance(a, .3); assert.ok(a.player.y > 1); advance(a, 1); assert.equal(a.player.y, 0); assert.equal(a.player.grounded, true);
  const slow = quiet(), fast = quiet(); for (let i = 0; i < 30; i++) slow.step(1 / 30, { forward: 1 }); for (let i = 0; i < 144; i++) fast.step(1 / 144, { forward: 1 }); assert.ok(Math.abs(slow.player.z - fast.player.z) < .05);
});
test('shots stop at hard cover, headshots deal extra damage, and ammo plus reload are finite', () => {
  const sim = quiet(); const e = enemy(sim); sim.player.pitch = 0; sim.aiming = true;
  assert.equal(sim.fire(), true); assert.ok(e.health < 100); const health = e.health; assert.equal(sim.fire(), false); assert.equal(e.health, health);
  sim.reload(); assert.equal(sim.fire(), false); advance(sim, 2); assert.equal(sim.weapons.rifle.ammo, 30); assert.equal(sim.weapons.rifle.reserve, 209);
  sim.switchWeapon('sniper'); sim.aiming = true; sim.player.yaw = Math.atan2(-e.x, sim.player.z - e.z); sim.player.pitch = Math.atan2(1.73 - sim.eye.y, Math.hypot(e.x, sim.player.z - e.z)); sim.fire(); assert.equal(sim.kills, 1); assert.ok(sim.score >= 150);
  const wall = quiet({ obstacles: [{ type: 'bunker', x: 0, z: 27, w: 4, d: 1, h: 3 }] }); const protectedEnemy = enemy(wall); wall.fire(); assert.equal(protectedEnemy.health, 100);
  wall.player.z = 27.83; wall.player.pitch = -.3; wall.weapons.rifle.cooldown = 0; wall.fire(); assert.equal(protectedEnemy.health, 100);
});
test('a scoped sniper hits distant targets along camera yaw and pitch', () => {
  const sim = quiet(), target = enemy(sim, 16, -12); sim.player.y = 3.1; sim.switchWeapon('sniper'); sim.aiming = true;
  sim.player.yaw = Math.atan2(-16, 44); sim.player.pitch = Math.atan2(1.73 - sim.eye.y, Math.hypot(16, 44));
  assert.equal(sim.fire(), true); assert.equal(sim.kills, 1); assert.equal(sim.weapons.sniper.ammo, 4);
  const dir = direction(sim.player.yaw, sim.player.pitch); assert.ok(dir.x > 0 && dir.y < 0 && dir.z < 0);
});
test('point-blank shots damage the first cover and cannot hit enemies through its destruction', () => {
  const sim = quiet({ obstacles: OBSTACLES });
  Object.assign(sim.player, { x: 20, z: 20.63 });
  sim.switchWeapon('sniper'); sim.aiming = true;
  const cover = sim.obstacles.find(box => box.type === 'crates' && box.x === 20);
  const target = enemy(sim, 20, 17); target.windup = 999;
  assert.equal(sim.blocked(sim.player.x, sim.player.y, sim.player.z), false);

  assert.equal(sim.fire(), true);
  assert.equal(cover.health, 5);
  assert.equal(sim.weapons.sniper.ammo, 4);
  assert.equal(target.health, 100);
  const shot = sim.events.find(event => event.type === 'shot');
  assert.ok(Math.abs(shot.to.z - (cover.z + cover.d / 2)) < 1e-6);

  advance(sim, 1.2);
  assert.equal(sim.fire(), true);
  assert.equal(cover.destroyed, true);
  assert.equal(sim.weapons.sniper.ammo, 3);
  assert.equal(target.health, 100);
  assert.equal(sim.events.filter(event => event.type === 'destroy').length, 1);

  advance(sim, 1.2);
  assert.equal(sim.fire(), true);
  assert.ok(target.health < 100);
});
test('grenades bounce, only explode after 2.8 simulation seconds, and can damage the player', () => {
  const sim = quiet(); sim.throwGrenade(); const grenade = sim.projectiles[0];
  assert.equal(sim.grenades, 3); assert.equal(sim.throwGrenade(), false);
  advance(sim, 2.79); assert.equal(sim.projectiles.length, 1); assert.ok(grenade.y >= .09); assert.equal(sim.events.filter(e => e.type === 'explosion').length, 0);
  advance(sim, .03); assert.equal(sim.projectiles.length, 0); assert.equal(sim.events.filter(e => e.type === 'explosion').length, 1);
  const health = sim.player.health; sim.explode({ x: sim.player.x, y: .1, z: sim.player.z }); assert.ok(sim.player.health < health);
  const wall = quiet({ obstacles: [{ type: 'bunker', x: 0, z: 29, w: 6, d: 1, h: 4 }] }); wall.explode({ x: 0, y: .1, z: 27 }); assert.equal(wall.player.health, 100);
});
test('grenades cannot tunnel through thin cover at high speed', () => {
  const sim = quiet({ obstacles: [{ type: 'bunker', x: 0, z: 30, w: 4, d: .2, h: 4 }] }); sim.throwGrenade(); advance(sim, .25);
  assert.ok(sim.projectiles[0].z > 30.1); assert.ok(sim.projectiles[0].vz > 0);
});
test('destroyed cover disappears from collision, ballistics and navigation and resets for new games', () => {
  const props = [{ type: 'crates', x: 0, z: 28, w: 4, d: 2, h: 2 }], sim = quiet({ obstacles: props }); const cover = sim.obstacles[0];
  assert.equal(sim.blocked(0, 0, 28), true); assert.equal(clearLine(sim.eye, { x: 0, y: 1.62, z: 24 }, sim.cover), false);
  for (let i = 0; i < 5; i++) { sim.weapons.rifle.cooldown = 0; sim.fire(); }
  assert.equal(cover.destroyed, true); assert.equal(sim.blocked(0, 0, 28), false); assert.equal(clearLine(sim.eye, { x: 0, y: 1.62, z: 24 }, sim.cover), true);
  assert.equal(sim.events.filter(e => e.type === 'destroy').length, 1); assert.equal(quiet({ obstacles: props }).obstacles[0].destroyed, false); assert.equal(props[0].destroyed, undefined);
  const container = quiet({ obstacles: [{ type: 'container', x: 0, z: 28, w: 4, d: 2, h: 3.1 }] }); container.explode({ x: 0, y: .1, z: 29.2 }); assert.equal(container.obstacles[0].destroyed, true);
});
test('explosions respect intervening cover before destroying it and cannot chain through buildings', () => {
  const sim = quiet({ obstacles: [{ type: 'crates', x: 0, z: 28, w: 5, d: 1, h: 2 }, { type: 'crates', x: 0, z: 25, w: 2, d: 1, h: 2 }] }); const e = enemy(sim, 0, 26);
  sim.explode({ x: 0, y: .15, z: 29 }); assert.equal(e.health, 100); assert.equal(sim.obstacles[0].destroyed, true); assert.equal(sim.obstacles[1].health, 110);
});
test('container mantle interpolates to the roof, locks firing, supports walking and dropping back down', () => {
  const sim = quiet({ obstacles: [{ type: 'container', x: 0, z: 28, w: 4, d: 6, h: 3.1 }] }); sim.player.z = 31.8;
  assert.ok(sim.mantleTarget()); assert.equal(sim.mantle(), true); assert.equal(sim.fire(), false); assert.equal(sim.throwGrenade(), false);
  advance(sim, .3); assert.ok(sim.player.y > 0 && sim.player.y < 3.3); assert.ok(sim.climbing);
  advance(sim, .6); assert.equal(sim.climbing, null); assert.equal(sim.player.y, 3.1); assert.equal(sim.player.grounded, true);
  advance(sim, .3, { forward: 1 }); assert.equal(sim.player.y, 3.1);
  advance(sim, 2, { side: 1 }); advance(sim, 1); assert.equal(sim.player.y, 0);
});
test('destruction under a player on a container causes a fall, and explosive barrels chain once each', () => {
  const sim = quiet({ obstacles: [{ type: 'container', x: 0, z: 28, w: 4, d: 6, h: 3.1 }] }); Object.assign(sim.player, { x: 0, y: 3.1, z: 28 });
  sim.damageCover(sim.obstacles[0], 1000); advance(sim, 1); assert.equal(sim.player.y, 0); assert.equal(sim.player.grounded, true);
  const barrels = quiet({ obstacles: [{ type: 'barrel', x: 10, z: 10, w: .8, d: .8, h: 1.15 }, { type: 'barrel', x: 12, z: 10, w: .8, d: .8, h: 1.15 }] });
  barrels.damageCover(barrels.obstacles[0], 100); assert.ok(barrels.obstacles.every(b => b.destroyed)); assert.equal(barrels.events.filter(e => e.type === 'explosion').length, 2); assert.equal(barrels.events.filter(e => e.type === 'destroy').length, 2);
});
test('enemies lose a prone player behind low cover and only search the last seen location', () => {
  const sim = quiet({ obstacles: [{ type: 'barrier', x: 0, z: 31, w: 14, d: .8, h: 1.05 }] }); const e = enemy(sim, 0, 24);
  advance(sim, .01); assert.equal(e.seesPlayer, true); const lastKnown = { ...e.lastKnown };
  sim.toggleProne(); advance(sim, .5); assert.equal(e.seesPlayer, false); assert.equal(sim.hidden, true);
  advance(sim, 1, { side: 1 }); assert.deepEqual(e.lastKnown, lastKnown); assert.notEqual(sim.player.x, e.lastKnown.x);
  sim.fire(); assert.equal(sim.hidden, false); assert.equal(e.lastKnown.x, sim.player.x);
});
test('enemy windup telegraphs fire, walls prevent damage, and death freezes combat', () => {
  const sim = quiet({ difficulty: 'hard' }); const e = enemy(sim); e.cooldown = 0;
  advance(sim, .01); assert.ok(e.windup > 0); assert.equal(sim.player.health, 100); advance(sim, .7); assert.ok(sim.events.some(e => e.type === 'enemy-shot'));
  sim.damagePlayer(1000, e); const time = sim.time, ammo = sim.weapons.rifle.ammo; advance(sim, 5, { forward: 1, fire: true }); assert.equal(sim.state, 'lost'); assert.equal(sim.time, time); assert.equal(sim.weapons.rifle.ammo, ammo); assert.equal(sim.jump(), false);
});
test('all three waves have safe navigable spawns and victory requires extraction', () => {
  const sim = new ShooterSimulation({ seed: 100 });
  for (let wave = 1; wave <= 3; wave++) {
    advance(sim, wave === 1 ? 1.5 : 7.1); assert.equal(sim.wave, wave); assert.equal(sim.alive.length, 3 + wave * 2);
    for (const e of sim.alive) { assert.ok(!sim.blocked(e.x, 0, e.z, 1.9, .38)); assert.ok(Math.hypot(e.x - sim.player.x, e.z - sim.player.z) >= 12); assert.ok(sim.findPath(e, sim.player).length); sim.damageEnemy(e, 1000); }
  }
  advance(sim, .1); assert.equal(sim.state, 'active'); assert.equal(sim.extractionAnnounced, true);
  Object.assign(sim.player, EXTRACTION); advance(sim, 2.5); assert.equal(sim.state, 'active'); sim.player.x += 5; advance(sim, .1); assert.equal(sim.extractionProgress, 0);
  Object.assign(sim.player, EXTRACTION); advance(sim, 3.1); assert.equal(sim.state, 'won'); assert.equal(sim.kills, 21);
});
test('health regenerates only after the delay, and pausing advances no grenade, reload or AI clocks', () => {
  const sim = quiet(); sim.damagePlayer(45, { x: 0, z: 0 }); sim.throwGrenade(); sim.weapons.rifle.ammo = 5; sim.reload();
  const state = JSON.stringify({ grenade: sim.projectiles[0], reload: sim.weapons.rifle.reload, time: sim.time }); sim.step(0);
  assert.equal(JSON.stringify({ grenade: sim.projectiles[0], reload: sim.weapons.rifle.reload, time: sim.time }), state);
  advance(sim, 5.4); assert.equal(sim.player.health, 55); advance(sim, .4); assert.ok(sim.player.health > 55); advance(sim, 10); assert.equal(sim.player.health, 100);
});
