import test from 'node:test';
import assert from 'node:assert/strict';
import { GameSimulation, CELL, LEVEL_HEIGHT } from '../src/simulation.js';
import { findPath } from '../src/maze.js';

const close = (actual, expected, tolerance = 1e-7) => assert.ok(Math.abs(actual - expected) < tolerance,
  `${actual} is not close to ${expected}`);
const unit = (from, to) => {
  const length = Math.hypot(to.x - from.x, to.y - from.y, to.z - from.z);
  return { x: (to.x - from.x) / length, y: (to.y - from.y) / length, z: (to.z - from.z) / length };
};
function arena(weapon, level = 0) {
  const sim = new GameSimulation({ size: 15, levels: 3, danger: 'calm', loadout: [weapon, 'chalk'] });
  for (const floor of sim.levels) {
    floor.maze.grid = floor.maze.grid.map((row, z) => row.map((_, x) =>
      x === 0 || z === 0 || x === floor.maze.size - 1 || z === floor.maze.size - 1 ? 1 : 0));
  }
  sim.player = { ...sim.player, x: CELL * 7, z: CELL * 7, level, y: level * LEVEL_HEIGHT };
  sim.maze = sim.levels[level].maze;
  sim.rooms = [];
  sim.hazards = [];
  return sim;
}
function addMonster(sim, point, level = sim.player.level) {
  const monster = { id: 100 + sim.monsters.length, type: 'listener', health: 110, maxHealth: 110,
    age: 0, level, y: level * LEVEL_HEIGHT, ...point };
  sim.monsters.push(monster);
  return monster;
}

for (const weapon of ['laser', 'machinegun', 'rocket']) test(`${weapon} fires along the muzzle ray independently of camera yaw on either floor`, () => {
  for (const level of [0, 2]) {
    const sim = arena(weapon, level);
    const enemy = addMonster(sim, { x: sim.player.x + 4, z: sim.player.z - 8 });
    const eye = { x: sim.player.x, y: sim.player.y + 1.72, z: sim.player.z };
    const cursorDirection = unit(eye, { ...enemy, y: enemy.y + 1.25 });
    const target = sim.getAimTarget(eye, cursorDirection);
    assert.equal(target.monsterId, enemy.id);
    const origin = { x: sim.player.x + 0.5, y: sim.player.y + 1.35, z: sim.player.z - 0.8 };
    const direction = unit(origin, target);
    assert.ok(sim.useTool(0, Math.PI, -0.5, { origin, direction }));
    const effect = weapon === 'rocket' ? sim.projectiles.at(-1) : sim.weaponEffects.at(-1);
    for (const axis of ['x', 'y', 'z']) close(effect[axis], origin[axis]);
    assert.equal(effect.slot, 0);
    if (weapon === 'rocket') {
      close(effect.dx, direction.x); close(effect.dy, direction.y); close(effect.dz, direction.z);
      sim.step(0.5);
      assert.equal(enemy.health, 0);
    } else {
      const actualDirection = unit(origin, { x: effect.toX, y: effect.toY, z: effect.toZ });
      for (const axis of ['x', 'y', 'z']) close(actualDirection[axis], direction[axis]);
      assert.equal(enemy.health, weapon === 'laser' ? 72 : 89);
    }
  }
});

test('cursor ray selects the nearest local creature and stops at cover, floor and ceiling', () => {
  const sim = arena('laser', 1);
  const origin = { x: sim.player.x, y: sim.player.y + 1.25, z: sim.player.z };
  const near = addMonster(sim, { x: origin.x + 4, z: origin.z - 8 });
  addMonster(sim, { x: origin.x + 8, z: origin.z - 16 });
  addMonster(sim, { x: origin.x + 1, z: origin.z - 2 }, 0);
  const direction = unit(origin, { ...near, y: near.y + 1.25 });
  assert.equal(sim.getAimTarget(origin, direction).monsterId, near.id);
  sim.maze.grid[5][8] = 1;
  const wallTarget = sim.getAimTarget(origin, direction);
  assert.equal(wallTarget.hit, true);
  assert.equal(wallTarget.monsterId, undefined);
  assert.ok(wallTarget.distance < 8);
  const floorTarget = sim.getAimTarget(origin, { x: 0, y: -1, z: 0 });
  close(floorTarget.y, LEVEL_HEIGHT + 0.12, 0.001);
  const ceilingTarget = sim.getAimTarget(origin, { x: 0, y: 1, z: 0 });
  close(ceilingTarget.y, LEVEL_HEIGHT + 4.15, 0.001);
  const short = sim.getAimTarget(origin, { x: 1, y: 0, z: 0 }, 0.025);
  close(short.x, origin.x + 0.025);
});

for (const weapon of ['laser', 'machinegun', 'rocket']) test(`${weapon} cannot shoot through cover when its muzzle clips a wall`, () => {
  const sim = arena(weapon);
  sim.maze.grid[5][7] = 1;
  sim.player.z = CELL * 5 + CELL / 2 + 0.28;
  const target = addMonster(sim, { x: sim.player.x, z: CELL * 4 });
  const origin = { x: sim.player.x, y: 1.4, z: sim.player.z - 0.8 };
  assert.ok(sim.useTool(0, 0, 0, { origin, direction: { x: 0, y: 0, z: -1 } }));
  assert.equal(sim.inventory[0].charges, weapon === 'laser' ? 79 : weapon === 'rocket' ? 2 : 179);
  if (weapon === 'rocket') {
    close(sim.projectiles[0].z, origin.z);
    sim.step(0.05);
    assert.equal(sim.projectiles.length, 0);
    const blast = sim.weaponEffects.find((effect) => effect.type === 'explosion');
    assert.ok(blast.z > CELL * 5 + CELL / 2);
  } else {
    const effect = sim.weaponEffects.at(-1);
    close(effect.z, origin.z);
    assert.ok(effect.toZ > CELL * 5 + CELL / 2);
    assert.equal(effect.hit, false);
  }
  assert.equal(target.health, 110);
});

test('a muzzle beyond a wall corner cannot bypass eye-to-barrel cover even when both endpoints are clear', () => {
  const sim = arena('laser');
  sim.maze.grid[6][6] = 1;
  const edge = CELL * 6 + CELL / 2;
  sim.player.x = edge + 0.28;
  sim.player.z = edge - 0.4;
  const origin = { x: edge - 0.4, y: 1.4, z: edge + 0.28 };
  const direction = { x: -1, y: 0, z: 0 };
  const enemy = addMonster(sim, { x: origin.x - 5, z: origin.z });
  assert.ok(sim._canOccupy(sim.player.x, sim.player.z, 0.05));
  assert.ok(sim._canOccupy(origin.x, origin.z, 0.05));
  assert.equal(sim.getAimTarget(origin, direction).monsterId, enemy.id);
  assert.ok(sim.useTool(0, 0, 0, { origin, direction }));
  assert.equal(enemy.health, 110);
  assert.equal(sim.weaponEffects.at(-1).hit, false);
});

test('invalid muzzle data cannot consume ammunition or corrupt effects; finite directions normalize', () => {
  const sim = arena('machinegun');
  const origin = { x: sim.player.x + 0.2, y: 1.4, z: sim.player.z - 0.6 };
  const direction = { x: 0, y: 0, z: -1 };
  for (const shot of [{}, { origin }, { origin, direction: { x: 0, y: 0, z: 0 } },
    { origin: { ...origin, x: Infinity }, direction }, { origin, direction: { ...direction, y: NaN } },
    { origin: { ...origin, z: origin.z - 10 }, direction }, { origin, direction: 'forward' }]) {
    assert.equal(sim.useTool(0, 0, 0, shot), false);
    assert.equal(sim.inventory[0].charges, 180);
    assert.equal(sim.weaponEffects.length, 0);
  }
  assert.equal(sim.getAimTarget(origin, { x: 0, y: 0, z: 0 }), null);
  assert.equal(sim.getAimTarget(origin, direction, Infinity), null);
  assert.ok(sim.useTool(0, 0, 0, { origin, direction: { x: 0, y: 0, z: -25 } }));
  const effect = sim.weaponEffects.at(-1);
  close(effect.toX, origin.x); close(effect.toY, origin.y);
  assert.ok(effect.toZ < origin.z);
});

test('two-monster waves fill the larger per-floor caps with safe player, ladder and monster spacing', () => {
  for (const [danger, cap, minimumPath] of [['normal', 8, 7], ['nightmare', 12, 5]]) {
    const sim = new GameSimulation({ size: 25, levels: 3, danger, seed: 'dense-floors' });
    for (const level of [0, 1]) {
      sim.player.level = level;
      sim.player.y = level * LEVEL_HEIGHT;
      sim.maze = sim.levels[level].maze;
      sim.player.x = sim.maze.start.x * CELL; sim.player.z = sim.maze.start.z * CELL;
      for (let wave = 0; wave < cap / 2 + 1; wave += 1) {
        sim.elapsed = sim._nextSpawn;
        sim._spawnIfDue();
        const local = sim.monsters.filter((monster) => monster.level === level);
        assert.equal(local.length, Math.min((wave + 1) * 2, cap));
        for (const monster of local) {
          assert.ok(Math.hypot(monster.x - sim.player.x, monster.z - sim.player.z) >= CELL * 3);
          const route = findPath(sim.maze, sim.maze.start, { x: Math.round(monster.x / CELL), z: Math.round(monster.z / CELL) });
          assert.ok(route.length - 1 >= minimumPath);
          for (const other of local) if (other !== monster) {
            assert.ok(Math.hypot(monster.x - other.x, monster.z - other.z) >= CELL * 1.5);
          }
          for (const ladder of sim.ladders.filter((ladder) => ladder.fromLevel === level || ladder.toLevel === level)) {
            assert.ok(Math.hypot(monster.x - ladder.x, monster.z - ladder.z) >= 2.2);
          }
        }
      }
    }
    assert.equal(sim.monsters.length, cap * 2);
  }
});

test('first waves stay in the reachable local region of a 51×51 maze at both complexity extremes', () => {
  for (const [danger, minimum, maximum] of [['normal', 7, 18], ['nightmare', 5, 16]]) {
    for (const complexity of [0, 100]) for (const seed of ['nearby-1', 'nearby-2', 'nearby-3']) {
      const sim = new GameSimulation({ size: 51, levels: 3, danger, complexity, seed });
      for (let wave = 0; wave < 2; wave += 1) { sim.elapsed = sim._nextSpawn; sim._spawnIfDue(); }
      assert.equal(sim.monsters.length, 4);
      for (const monster of sim.monsters) {
        const route = findPath(sim.maze, sim.maze.start, { x: Math.round(monster.x / CELL), z: Math.round(monster.z / CELL) });
        assert.ok(route.length - 1 >= minimum && route.length - 1 <= maximum,
          `${danger}/${complexity}/${seed}: spawn ${route.length - 1} cells away`);
        assert.ok(Math.hypot(monster.x - sim.player.x, monster.z - sim.player.z) >= CELL * 3);
        for (const other of sim.monsters) if (other !== monster) {
          assert.ok(Math.hypot(monster.x - other.x, monster.z - other.z) >= CELL * 1.5);
        }
      }
    }
  }
});

test('saturated nearby spawn cells expand only into the next reachable band', () => {
  const sim = new GameSimulation({ size: 51, danger: 'normal', seed: 'crowded-corridor' });
  sim.rooms = []; sim.ladders = []; sim.objectives = [];
  sim.maze.grid = sim.maze.grid.map((row, z) => row.map((_, x) => z === 25 && x > 0 && x < 50 ? 0 : 1));
  sim.maze.start = { x: 1, z: 25 }; sim.maze.exit = { x: 49, z: 25 };
  sim.player.x = CELL; sim.player.z = CELL * 25;
  // Six actors cover all safe positions 7–18 corridor steps from the player.
  for (const steps of [8, 10, 12, 14, 16, 18]) {
    addMonster(sim, { x: (1 + steps) * CELL, z: sim.player.z });
  }
  sim.elapsed = sim._nextSpawn; sim._spawnIfDue();
  assert.equal(sim.monsters.length, 8);
  for (const monster of sim.monsters.slice(6)) {
    const steps = Math.round(monster.x / CELL) - 1;
    assert.ok(steps >= 20 && steps <= 28, `${steps} steps away`);
  }
});
