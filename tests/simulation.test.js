import test from 'node:test';
import assert from 'node:assert/strict';
import { GameSimulation, CELL, PLAYER_RADIUS } from '../src/simulation.js';
import { findPath, walkable } from '../src/maze.js';

const cellOf = ({ x, z }) => ({ x: Math.round(x / CELL), z: Math.round(z / CELL) });
const placeAt = (body, cell) => { body.x = cell.x * CELL; body.z = cell.z * CELL; };

function directionFromStart(sim) {
  const path = findPath(sim.maze, sim.maze.start, sim.maze.exit);
  return { moveX: path[1].x - path[0].x, moveZ: path[1].z - path[0].z };
}

test('player collision keeps the entire circle outside perimeter and interior walls', () => {
  const sim = new GameSimulation({ danger: 'calm' });
  sim.step(8, { moveX: -1, sprint: true });
  assert.ok(sim.player.x >= CELL / 2 + PLAYER_RADIUS - 1e-6);
  assert.equal(sim.player.z, CELL);
  sim.step(8, { moveZ: -1, sprint: true });
  assert.ok(sim.player.z >= CELL / 2 + PLAYER_RADIUS - 1e-6);
  assert.ok(walkable(sim.maze, ...Object.values(cellOf(sim.player))));
  // Locate an internal floor/wall boundary and charge through it in a large dt.
  let floor;
  for (let z = 1; z < sim.maze.size - 1 && !floor; z += 1) {
    for (let x = 1; x < sim.maze.size - 2; x += 1) {
      if (walkable(sim.maze, x, z) && !walkable(sim.maze, x + 1, z)) { floor = { x, z }; break; }
    }
  }
  assert.ok(floor);
  placeAt(sim.player, floor);
  sim.step(10, { moveX: 1, sprint: true });
  assert.ok(sim.player.x <= floor.x * CELL + CELL / 2 - PLAYER_RADIUS + 1e-6);
});

test('movement normalizes diagonals and simulation advances only when stepped', () => {
  const straight = new GameSimulation({ danger: 'calm' });
  const diagonal = new GameSimulation({ danger: 'calm' });
  const start = { ...straight.player };
  straight.step(0.1, { moveX: 1 });
  diagonal.step(0.1, { moveX: 1, moveZ: 1 });
  assert.ok(Math.abs(Math.hypot(straight.player.x - start.x, straight.player.z - start.z) - 0.45) < 1e-9);
  assert.ok(Math.abs(Math.hypot(diagonal.player.x - start.x, diagonal.player.z - start.z) - 0.45) < 1e-9);
  const snapshot = JSON.stringify({ player: diagonal.player, elapsed: diagonal.elapsed, monsters: diagonal.monsters });
  diagonal.step(0, { moveX: 1 });
  diagonal.step(NaN, { moveX: 1 });
  diagonal.step(-1, { moveX: 1 });
  assert.equal(JSON.stringify({ player: diagonal.player, elapsed: diagonal.elapsed, monsters: diagonal.monsters }), snapshot);
});

test('exhaustion locks sprinting until stamina recovers to 25 after a delay', () => {
  const sim = new GameSimulation({ danger: 'calm' });
  const direction = directionFromStart(sim);
  sim.player.stamina = 0.5;
  assert.equal(sim.step(0.05, { ...direction, sprint: true }).sprinting, true);
  assert.equal(sim.player.stamina, 0);
  assert.equal(sim.events.filter((event) => event.type === 'exhausted').length, 1);
  assert.equal(sim.step(0.05, { ...direction, sprint: true }).sprinting, false);
  sim.step(1);
  assert.equal(sim.player.stamina, 0);
  sim.step(1);
  assert.ok(sim.player.stamina > 0 && sim.player.stamina < 25);
  placeAt(sim.player, sim.maze.start);
  assert.equal(sim.step(0.05, { ...direction, sprint: true }).sprinting, false);
  sim.step(1.1);
  assert.ok(sim.player.stamina >= 25);
  assert.equal(sim.step(0.05, { ...direction, sprint: true }).sprinting, true);
});

test('calm mode never spawns monsters and stamina stays bounded', () => {
  const sim = new GameSimulation({ danger: 'calm' });
  sim.step(180);
  assert.equal(sim.monsters.length, 0);
  assert.equal(sim.events.length, 0);
  assert.equal(sim.player.stamina, 100);
  assert.equal(sim.status, 'playing');
  assert.ok(Math.abs(sim.elapsed - 180) < 1e-6);
});

test('normal and nightmare spawn on schedule at a safe path distance', () => {
  for (const [danger, first, minimum] of [['normal', 8, 7], ['nightmare', 5, 5]]) {
    const sim = new GameSimulation({ size: 25, danger, seed: 'safe' });
    sim.step(first - 0.1);
    assert.equal(sim.monsters.length, 0);
    sim.step(0.1);
    assert.equal(sim.monsters.length, 2);
    const event = sim.events.find((entry) => entry.type === 'spawn');
    assert.ok(event);
    const path = findPath(sim.maze, cellOf(sim.player), cellOf(event));
    assert.ok(path.length - 1 >= minimum);
    assert.ok(sim.monsters[0].age <= 0.051);
    assert.equal(sim.status, 'playing');
  }
});

test('monster spawn schedules recur and respect each difficulty cap', () => {
  for (const [danger, first, interval, cap] of [
    ['normal', 8, 9, 8], ['nightmare', 5, 6, 12],
  ]) {
    const sim = new GameSimulation({ size: 35, complexity: 100, danger, seed: 'schedule' });
    for (let id = 100; id < 100 + cap; id += 1) {
      sim.monsters.push({ id, x: sim.maze.exit.x * CELL, z: sim.maze.exit.z * CELL, age: 0 });
    }
    sim.step(first);
    assert.equal(sim.status, 'playing');
    assert.equal(sim.monsters.length, cap);
    assert.equal(sim.events.filter((event) => event.type === 'spawn').length, 0);
    sim.monsters.length = 0;
    sim.step(interval - 0.1);
    assert.equal(sim.monsters.length, 0);
    sim.step(0.1);
    assert.equal(sim.monsters.length, 2);
    assert.equal(sim.events.filter((event) => event.type === 'spawn').length, 2);
    sim.monsters.length = 0;
    sim.step(interval);
    assert.equal(sim.monsters.length, 2);
    assert.equal(sim.events.filter((event) => event.type === 'spawn').length, 4);
  }
});

test('relic collection requires proximity and victory requires every relic plus exit', () => {
  const sim = new GameSimulation({ danger: 'calm' });
  assert.equal(sim.nearbyRelic, -1);
  assert.equal(sim.collectRelic(), false);
  placeAt(sim.player, sim.maze.exit);
  sim.step(0.05);
  assert.equal(sim.status, 'playing');
  sim.relics.forEach((relic, index) => {
    sim.player.x = relic.x;
    sim.player.z = relic.z;
    assert.equal(sim.nearbyRelic, index);
    assert.equal(sim.collectRelic(), true);
    assert.equal(sim.collectRelic(), false);
  });
  assert.equal(sim.status, 'playing');
  placeAt(sim.player, sim.maze.exit);
  sim.step(0.05);
  assert.equal(sim.status, 'won');
  assert.equal(sim.events.filter((event) => event.type === 'relic').length, 3);
  assert.equal(sim.events.filter((event) => event.type === 'win').length, 1);
  const elapsed = sim.elapsed;
  sim.step(2);
  assert.equal(sim.elapsed, elapsed);
  assert.equal(sim.collectRelic(), false);
});

test('a searching monster follows remembered corridors and damages a player outside sanctuary', () => {
  const sim = new GameSimulation({ size: 15, danger: 'normal', seed: 'pursuit' });
  const path = findPath(sim.maze, sim.maze.start, sim.maze.exit);
  placeAt(sim.player, path[8]);
  sim.rooms = [];
  sim.monsters.push({ id: 900, type: 'shade', x: path[5].x * CELL, z: path[5].z * CELL, age: 0,
    lastKnown: { x: sim.player.x, z: sim.player.z }, memory: 20 });
  for (let frame = 0; frame < 400 && sim.status === 'playing'; frame += 1) {
    sim.step(0.05, { light: false });
    for (const monster of sim.monsters) {
      const cell = cellOf(monster);
      assert.ok(walkable(sim.maze, cell.x, cell.z));
    }
  }
  assert.equal(sim.status, 'lost');
  assert.equal(sim.events.filter((event) => event.type === 'lose').length, 1);
  const elapsed = sim.elapsed;
  sim.step(10);
  assert.equal(sim.elapsed, elapsed);
});

test('monsters expire after 90 seconds and explored cells stop at walls', () => {
  const sim = new GameSimulation({ danger: 'calm' });
  sim.monsters.push({ id: 42, x: sim.maze.exit.x * CELL, z: sim.maze.exit.z * CELL, age: 89.98 });
  sim.step(0.05);
  assert.equal(sim.monsters.length, 0);
  assert.ok(sim.explored.has('1,1'));
  assert.ok(sim.explored.has('0,1'));
  assert.equal(sim.explored.has('-1,1'), false);
  assert.ok(sim.explored.size <= 9);
});
