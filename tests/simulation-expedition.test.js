import test from 'node:test';
import assert from 'node:assert/strict';
import { GameSimulation, CELL } from '../src/simulation.js';
import { findPath, reachableCells, walkable } from '../src/maze.js';

const cellOf = ({ x, z }) => ({ x: Math.round(x / CELL), z: Math.round(z / CELL) });
const place = (body, point) => Object.assign(body, { x: point.x, z: point.z });
const atCell = (body, point) => place(body, { x: point.x * CELL, z: point.z * CELL });
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-6, `${actual} ≠ ${expected}`);

function arena(config = {}) {
  const sim = new GameSimulation({ size: 15, danger: 'normal', seed: 'combat-rules', ...config });
  sim.maze.grid = sim.maze.grid.map((row, z) => row.map((_, x) =>
    x === 0 || z === 0 || x === sim.maze.size - 1 || z === sim.maze.size - 1 ? 1 : 0));
  sim.rooms = [];
  sim.hazards = [];
  sim._floors = reachableCells(sim.maze);
  sim._nextSpawn = Infinity;
  sim._nextWorldEvent = Infinity;
  atCell(sim.player, { x: 7, z: 7 });
  return sim;
}
function monster(sim, type = 'listener', offset = { x: 0, z: -8 }) {
  const entity = { id: 100 + sim.monsters.length, type, x: sim.player.x + offset.x,
    z: sim.player.z + offset.z, age: 0, health: 110, maxHealth: 110 };
  sim.monsters.push(entity);
  return entity;
}

for (const mission of ['seals', 'repair', 'rescue']) test(`${mission} mission is completable through its public interactions`, () => {
  const sim = new GameSimulation({ danger: 'calm', mission, seed: `complete-${mission}` });
  for (const objective of sim.objectives) {
    place(sim.player, objective);
    assert.ok(sim.interact());
    if (mission === 'repair') {
      assert.equal(sim.activeInteraction.duration, 4);
      sim.step(4.1);
      assert.equal(objective.completed, true);
    }
  }
  if (mission === 'rescue') {
    assert.equal(sim.rescue.following, true);
    const path = findPath(sim.maze, cellOf(sim.player), sim.maze.exit);
    for (const cell of path) {
      atCell(sim.player, cell);
      sim.step(1.6);
      assert.ok(walkable(sim.maze, ...Object.values(cellOf(sim.rescue))));
    }
  }
  atCell(sim.player, sim.maze.exit);
  sim.step(0.1);
  assert.equal(sim.status, 'won');
  assert.equal(sim.missionProgress.ready, true);
  assert.equal(sim.events.filter((event) => event.type === 'win').length, 1);
  const result = sim.result;
  assert.equal(result.id, sim.result.id);
  assert.equal(result.won, true);
  assert.equal(result.mission, mission);
});

test('repair requires standing still; cancelling never marks the mechanism complete', () => {
  const sim = new GameSimulation({ danger: 'calm', mission: 'repair' });
  place(sim.player, sim.objectives[0]);
  assert.ok(sim.interact());
  sim.step(2);
  sim.step(0.05, { moveX: 1 });
  assert.equal(sim.activeInteraction, null);
  assert.equal(sim.objectives[0].completed, false);
});

test('library puzzle rejects wrong order, pauses clocks and awards its treasure exactly once', () => {
  const sim = new GameSimulation({ danger: 'calm' });
  const room = sim.rooms.find((entry) => entry.type === 'library');
  place(sim.player, room);
  assert.equal(sim.interaction.type, 'library');
  sim.interact();
  const elapsed = sim.elapsed;
  sim.step(10, { moveX: 1 });
  assert.equal(sim.elapsed, elapsed);
  assert.equal(sim.chooseRune((room.puzzle.sequence[0] + 1) % 3), false);
  assert.deepEqual(sim.activePuzzle.progress, []);
  for (const index of room.puzzle.sequence) assert.ok(sim.chooseRune(index));
  assert.equal(sim.activePuzzle, null);
  assert.equal(room.solved, true);
  assert.equal(sim.carriedTreasure, 2);
  assert.ok(sim.compassPath.length > 0);
  assert.ok(sim.compassPath.every((cell) => sim.explored.has(`${cell.x},${cell.z}`)));
  assert.equal(sim.interact(), false);
  assert.equal(sim.carriedTreasure, 2);
});

test('water hall can be drained and sanctuary protects and restores health', () => {
  const sim = new GameSimulation({ danger: 'normal' });
  const flooded = sim.rooms.find((room) => room.type === 'flooded');
  place(sim.player, flooded);
  const before = sim.player.x;
  sim.step(0.1, { moveX: 1 });
  close(sim.player.x - before, 4.5 * 0.1 * 0.6);
  place(sim.player, flooded);
  assert.equal(sim.interaction.type, 'drain');
  sim.interact();
  assert.equal(flooded.drained, true);
  const after = sim.player.x;
  sim.step(0.1, { moveX: 1 });
  close(sim.player.x - after, 4.5 * 0.1);
  const sanctuary = sim.rooms.find((room) => room.type === 'sanctuary');
  place(sim.player, sanctuary);
  sim.player.health = 50;
  const enemy = monster(sim, 'listener', { x: 0, z: 0 });
  sim.step(1);
  assert.equal(sim.inSanctuary, true);
  assert.equal(sim.threat, 0);
  assert.ok(sim.player.health > 50);
  assert.ok(!sim.events.some((event) => event.type === 'damage'));
  assert.ok(sim.monsters.includes(enemy));
});

test('trapped treasure gives a retreat window and never deals surprise instant damage', () => {
  const sim = new GameSimulation({ danger: 'normal' });
  const treasure = sim.treasures.find((entry) => entry.trapped);
  place(sim.player, treasure);
  assert.equal(sim.interaction.type, 'treasure');
  assert.match(sim.interaction.description, /2,5 Sekunden/);
  sim.interact();
  assert.equal(sim.carriedTreasure, treasure.value);
  const trap = sim.hazards.find((entry) => entry.id === `trap-${treasure.id}`);
  assert.equal(trap.warning, true);
  sim.step(2);
  assert.equal(sim.player.health, 100);
  sim.step(0.6);
  assert.equal(trap.active, true);
  assert.ok(sim.player.health < 100 && sim.player.health > 0);
  const health = sim.player.health;
  sim.step(0.1);
  assert.equal(sim.player.health, health);
});

test('listener tracks loud footsteps and decoys while silent players are not magically tracked', () => {
  const sim = arena({ loadout: ['stone', 'chalk'] });
  const enemy = monster(sim, 'listener', { x: 0, z: -10 });
  sim.step(0.05, { light: false });
  assert.equal(enemy.state, 'patrol');
  sim.step(0.05, { moveX: 1, sprint: true, light: false });
  assert.equal(enemy.state, 'hunting');
  assert.equal(sim.player.noise, 1);
  assert.ok(sim.useTool(0, 0));
  sim.step(0.6, { light: false });
  assert.equal(enemy.state, 'investigating');
  close(enemy.lastKnown.x, sim.decoys[0].x);
  close(enemy.lastKnown.z, sim.decoys[0].z);
});

test('sneaking is slower and quieter than walking, and does not reveal a distant player to listener', () => {
  const sim = arena();
  const enemy = monster(sim, 'listener', { x: 0, z: -6 });
  const x = sim.player.x;
  sim.step(0.1, { moveX: 1, sneak: true, sprint: true, light: false });
  close(sim.player.x - x, 0.22);
  assert.equal(sim.player.noise, 0.05);
  assert.equal(sim.player.sneaking, true);
  assert.equal(enemy.state, 'patrol');
  sim.step(0.1, { moveX: 1, light: false });
  assert.equal(sim.player.noise, 0.3);
  assert.equal(enemy.state, 'hunting');
});

test('watcher freezes only while actually seen, including line of sight and viewing direction', () => {
  const sim = arena();
  const enemy = monster(sim, 'watcher');
  const initial = { x: enemy.x, z: enemy.z };
  sim.step(0.5, { yaw: 0, light: false });
  assert.equal(enemy.state, 'frozen');
  close(enemy.x, initial.x); close(enemy.z, initial.z);
  sim.step(0.05, { yaw: 0, pitch: 0.85, light: false });
  assert.notEqual(enemy.state, 'frozen');
  sim.step(0.2, { yaw: Math.PI, light: false });
  assert.notEqual(enemy.state, 'frozen');
  assert.ok(Math.hypot(enemy.x - initial.x, enemy.z - initial.z) > 0);
  sim.maze.grid[5][7] = 1;
  atCell(enemy, { x: 7, z: 3 });
  sim.step(0.05, { yaw: 0, light: true });
  assert.notEqual(enemy.state, 'frozen');
});

test('shade retreats from directed flashlight and nearby flare, while walls block protection', () => {
  const sim = arena({ loadout: ['flare', 'laser'] });
  const enemy = monster(sim, 'shade', { x: 0, z: -6 });
  const separation = Math.hypot(enemy.x - sim.player.x, enemy.z - sim.player.z);
  sim.step(0.1, { yaw: 0, light: true });
  assert.equal(enemy.state, 'repelled');
  assert.ok(Math.hypot(enemy.x - sim.player.x, enemy.z - sim.player.z) > separation);
  sim.step(0.1, { yaw: Math.PI, light: true });
  assert.equal(enemy.state, 'hunting');
  sim.useTool(0, 0);
  sim.step(0.1, { light: false });
  assert.equal(enemy.state, 'repelled');
  sim.maze.grid[5][7] = 1;
  atCell(enemy, { x: 7, z: 4 });
  sim.step(0.05, { yaw: 0, light: true });
  assert.notEqual(enemy.state, 'repelled');
});

test('laser hits nearest visible target, consumes energy, respects walls and overheats until cooled', () => {
  const sim = arena({ loadout: ['laser', 'rocket'] });
  const first = monster(sim, 'listener', { x: 0, z: -5 });
  const second = monster(sim, 'listener', { x: 0, z: -10 });
  assert.ok(sim.useTool(0, 0));
  assert.equal(first.health, 72);
  assert.equal(second.health, 110);
  assert.equal(sim.inventory[0].charges, 79);
  assert.equal(sim.useTool(0, 0), false);
  sim.monsters = [];
  for (let shot = 0; shot < 5; shot += 1) { sim.step(0.18); sim.useTool(0, 0); }
  assert.equal(sim.inventory[0].overheated, true);
  const charges = sim.inventory[0].charges;
  sim.step(0.2);
  assert.equal(sim.useTool(0, 0), false);
  assert.equal(sim.inventory[0].charges, charges);
  sim.step(4.5);
  assert.equal(sim.inventory[0].overheated, false);
  assert.ok(sim.useTool(0, 0));
  sim.step(0.2);
  sim.maze.grid[5][7] = 1;
  const behind = monster(sim, 'listener', { x: 0, z: -11 });
  sim.useTool(0, 0);
  assert.equal(behind.health, 110);
});

test('machinegun holds a 30-round magazine with finite total ammo, cadence and automatic/manual reload', () => {
  const sim = arena({ loadout: ['machinegun', 'rocket'] });
  const gun = sim.inventory[0];
  assert.equal(gun.magazine, 30);
  assert.equal(gun.charges, 180);
  for (let shot = 0; shot < 30; shot += 1) {
    assert.ok(sim.useTool(0, 0));
    assert.equal(sim.useTool(0, 0), false);
    sim.step(0.1);
  }
  assert.equal(gun.magazine, 0);
  assert.equal(gun.charges, 150);
  assert.equal(sim.useTool(0, 0), false);
  assert.ok(gun.reloadRemaining >= 1.59 && gun.reloadRemaining <= 1.7);
  sim.step(1);
  assert.equal(sim.useTool(0, 0), false);
  sim.step(0.71);
  assert.equal(gun.magazine, 30);
  assert.equal(gun.charges, 150);
  sim.useTool(0, 0);
  assert.equal(sim.reloadWeapons(), true);
  sim.step(1.71);
  assert.equal(gun.magazine, 30);
  assert.equal(gun.charges, 149);
  gun.charges = 4; gun.magazine = 0;
  sim.reloadWeapons(); sim.step(1.71);
  assert.equal(gun.magazine, 4);
});

test('machinegun bullets damage targets but never penetrate a wall', () => {
  const sim = arena({ loadout: ['machinegun', 'rocket'] });
  const enemy = monster(sim);
  sim.useTool(0, 0);
  assert.equal(enemy.health, 89);
  assert.equal(sim.weaponEffects.at(-1).type, 'bullet');
  sim.maze.grid[5][7] = 1;
  sim.step(0.1);
  sim.useTool(0, 0);
  assert.equal(enemy.health, 89);
});

test('rockets collide with enemies, kill in an area and can hurt the player nearby', () => {
  const sim = arena({ loadout: ['rocket', 'laser'] });
  monster(sim, 'listener', { x: 0, z: -3 });
  const neighbour = monster(sim, 'shade', { x: 1.5, z: -3 });
  assert.ok(sim.useTool(0, 0));
  assert.equal(sim.projectiles.length, 1);
  sim.step(0.2);
  assert.equal(sim.projectiles.length, 0);
  assert.equal(sim.monsters.length, 0);
  assert.equal(neighbour.health, 0);
  assert.ok(sim.player.health < 100 && sim.player.health > 0);
  assert.ok(sim.weaponEffects.some((effect) => effect.type === 'explosion'));
  assert.equal(sim.inventory[0].charges, 2);
});

test('solid walls stop rocket flight and shield actors from blast damage on the far side', () => {
  const sim = arena({ loadout: ['rocket', 'laser'] });
  sim.maze.grid[5][7] = 1;
  const behind = monster(sim, 'listener', { x: 0, z: -9.1 });
  sim.useTool(0, 0);
  sim.step(0.4);
  assert.equal(sim.projectiles.length, 0);
  assert.equal(behind.health, 110);
  const blast = sim.weaponEffects.find((effect) => effect.type === 'explosion');
  assert.ok(blast);
  assert.ok(blast.z > 5 * CELL + CELL / 2);
});

test('chalk persists and thrown stones stop before a solid wall', () => {
  const sim = arena({ loadout: ['chalk', 'stone'] });
  sim.useTool(0, 1);
  assert.equal(sim.markers[0].yaw, 1);
  sim.maze.grid[5][7] = 1;
  sim.useTool(1, 0);
  assert.ok(sim.decoys[0].z > 5 * CELL + CELL / 2);
  sim.step(9);
  assert.equal(sim.decoys.length, 0);
  assert.equal(sim.markers.length, 1);
});

test('announced wall shifts preserve every remaining floor and protected actor/item cell', () => {
  for (const size of [9, 15, 35]) {
    const sim = new GameSimulation({ size, complexity: 100, danger: 'normal', seed: `shift-${size}` });
    sim._nextSpawn = Infinity;
    const protectedWorld = [sim.player, ...sim.objectives, ...sim.treasures];
    const protectedGrid = [sim.maze.start, sim.maze.exit, ...sim.rooms.flatMap((room) => room.cells), ...protectedWorld.map(cellOf)];
    const before = JSON.stringify(sim.maze.grid);
    assert.ok(sim.queueWorldEvent('shift'));
    sim.step(7.9);
    assert.equal(sim.worldEvent.phase, 'warning');
    assert.equal(JSON.stringify(sim.maze.grid), before);
    sim.step(0.2);
    assert.equal(sim.worldEvent.phase, 'active');
    const floorCount = sim.maze.grid.flat().filter((value) => value === 0).length;
    assert.equal(reachableCells(sim.maze).length, floorCount);
    assert.ok(protectedGrid.every((cell) => walkable(sim.maze, cell.x, cell.z)));
    for (const target of [...sim.objectives, ...sim.treasures]) assert.ok(findPath(sim.maze, sim.maze.start, cellOf(target)).length > 0);
    sim.step(5.1);
    assert.equal(sim.worldEvent, null);
  }
});

test('world events are bounded and calm mode has neither dangerous events nor damaging traps', () => {
  for (const type of ['blackout', 'flood', 'gas']) {
    const sim = arena({ biome: 'mine' });
    assert.ok(sim.queueWorldEvent(type));
    sim.step(8.1);
    assert.equal(sim.worldEvent.phase, 'active');
    assert.equal(sim._view.light, true);
    sim.step(21);
    assert.equal(sim.worldEvent, null);
  }
  const calm = new GameSimulation({ danger: 'calm' });
  assert.equal(calm.queueWorldEvent('gas'), false);
  const treasure = calm.treasures.find((entry) => entry.trapped);
  place(calm.player, treasure);
  calm.interact(); calm.step(10);
  assert.equal(calm.player.health, 100);
  assert.ok(calm.hazards.every((hazard) => !hazard.active));
});

test('rescue waits for a runaway player and resumes safely after they return', () => {
  const sim = arena({ mission: 'rescue' });
  atCell(sim.rescue, { x: 3, z: 3 });
  sim.rescue.following = true;
  atCell(sim.player, { x: 12, z: 12 });
  sim.step(0.1);
  assert.equal(sim.rescue.waiting, true);
  const initial = { ...sim.rescue };
  atCell(sim.player, { x: 4, z: 3 });
  sim.step(0.1);
  assert.equal(sim.rescue.waiting, false);
  assert.ok(sim.rescue.x > initial.x);
});

test('taking fatal damage records one loss and all subsequent rules are frozen', () => {
  const sim = arena({ loadout: ['rocket', 'laser'] });
  sim.player.health = 10;
  monster(sim, 'listener', { x: 0, z: -0.6 });
  sim.step(0.1);
  assert.equal(sim.status, 'lost');
  assert.equal(sim.events.filter((event) => event.type === 'lose').length, 1);
  const snapshot = JSON.stringify({ player: sim.player, elapsed: sim.elapsed, charges: sim.inventory[0].charges });
  sim.step(10);
  assert.equal(sim.useTool(0, 0), false);
  assert.equal(snapshot, JSON.stringify({ player: sim.player, elapsed: sim.elapsed, charges: sim.inventory[0].charges }));
  assert.equal(sim.result.won, false);
});
