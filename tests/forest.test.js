import test from 'node:test';
import assert from 'node:assert/strict';
import { generateExpedition, MISSIONS, TOOLS } from '../src/expedition.js';
import { GameSimulation, CELL } from '../src/simulation.js';
import { getTerrainHeight, getTerrainCeiling, getTerrainCave, getTerrainZone, getRavineCenter, forestBankHeight } from '../src/forest-world.js';
import { findPath, reachableCells, walkable } from '../src/maze.js';

const cellOf = ({ x, z }) => ({ x: Math.round(x / CELL), z: Math.round(z / CELL) });
const key = ({ x, z }) => `${x},${z}`;
const distance = (a, b) => Math.hypot(a.x - b.x, a.z - b.z);
function walkTo(sim, target) {
  const path = findPath(sim.maze, cellOf(sim.player), cellOf(target));
  assert.ok(path.length, 'Destination has a navigable path');
  for (const cell of path) {
    const next = { x: cell.x * CELL, z: cell.z * CELL };
    for (let steps = 0; distance(sim.player, next) > 0.015 && sim.status === 'playing'; steps += 1) {
      assert.ok(steps < 150, `Walking must reach ${key(cell)}`);
      const length = distance(sim.player, next);
      const beforeY = sim.player.y;
      const dt = Math.min(0.12, length / 4.5);
      sim.step(dt, { moveX: (next.x - sim.player.x) / length, moveZ: (next.z - sim.player.z) / length });
      assert.equal(sim.player.y, getTerrainHeight(sim.terrain, sim.player.x, sim.player.z));
      assert.ok(Math.abs(sim.player.y - beforeY) <= 4.5 * dt + 0.01, 'No height teleports or unwalkable slopes');
    }
  }
}

test('forest generation has connected clearings and two distinct caves with two reachable open mouths at every size', () => {
  for (const size of [9, 25, 51]) for (const complexity of [0, 100]) for (const seed of ['moon', 'roots', 'wolf']) {
    const config = { biome: 'forest', size, seed, complexity, levels: 3 };
    const world = generateExpedition(config);
    assert.deepEqual(world, generateExpedition(config));
    assert.equal(world.levels.length, 1);
    assert.equal(world.ladders.length, 0);
    const { maze, terrain } = world;
    const floors = reachableCells(maze);
    assert.equal(floors.length, maze.grid.flat().filter((value) => value === 0).length);
    assert.equal(new Set(terrain.caves.map((cave) => cave.type)).size, 2);
    assert.equal(terrain.caves.length, 2);
    assert.equal(world.allies.length, 2);
    for (const cave of terrain.caves) {
      assert.equal(cave.mouths.length, 2);
      for (const mouth of cave.mouths) {
        const inside = { x: mouth.x + (mouth.side === 'west' ? 0.2 : -0.2), z: mouth.z };
        const outside = { x: mouth.x + (mouth.side === 'west' ? -0.2 : 0.2), z: mouth.z };
        assert.ok(findPath(maze, maze.start, cellOf(outside)).length);
        assert.ok(walkable(maze, ...[cellOf(inside).x, cellOf(inside).z]));
        assert.equal(getTerrainCave(terrain, inside.x, inside.z), cave);
        assert.equal(getTerrainCave(terrain, outside.x, outside.z), null);
        assert.ok(Number.isFinite(getTerrainCeiling(terrain, inside.x, inside.z)));
        assert.equal(getTerrainCeiling(terrain, outside.x, outside.z), Infinity);
      }
      assert.ok(findPath(maze, cellOf(cave.mouths[0]), cellOf(cave.mouths[1])).length);
      for (const cell of cave.cells) {
        assert.ok(walkable(maze, cell.x, cell.z));
        assert.equal(getTerrainZone(terrain, cell.x * CELL, cell.z * CELL), cave.type);
      }
    }
    for (const entity of [...world.objectives, ...world.treasures, ...world.hazards, ...world.allies, ...world.rooms]) {
      assert.ok(findPath(maze, maze.start, cellOf(entity)).length);
      assert.equal(entity.y, getTerrainHeight(terrain, entity.x, entity.z));
    }
    assert.ok(findPath(maze, maze.start, maze.exit).length);
    for (let edge = 0; edge < size; edge += 1) {
      assert.equal(maze.grid[0][edge], 1);
      assert.equal(maze.grid[size - 1][edge], 1);
      assert.equal(maze.grid[edge][0], 1);
      assert.equal(maze.grid[edge][size - 1], 1);
    }
  }
});

test('players walk continuously down the ravine and through both mouths of each cave, then ascend', () => {
  for (const size of [9, 25, 51]) {
    const sim = new GameSimulation({ biome: 'forest', size, danger: 'calm', seed: 'crossing' });
    const start = { ...sim.player };
    let deepest = 0;
    for (const cave of sim.terrain.caves) {
      for (const mouth of cave.mouths) {
        walkTo(sim, { x: mouth.x + (mouth.side === 'west' ? -CELL / 2 : CELL / 2), z: mouth.z });
      }
      const bottom = cave.cells.reduce((a, b) => getTerrainHeight(sim.terrain, a.x * CELL, a.z * CELL)
        < getTerrainHeight(sim.terrain, b.x * CELL, b.z * CELL) ? a : b);
      walkTo(sim, { x: bottom.x * CELL, z: bottom.z * CELL });
      deepest = Math.min(deepest, sim.player.y);
      assert.equal(getTerrainCave(sim.terrain, sim.player.x, sim.player.z), cave);
    }
    assert.ok(deepest < -4.5);
    walkTo(sim, start);
    assert.equal(sim.player.y, start.y);
    assert.equal(sim.player.level, 0);
  }
});

for (const mission of MISSIONS) test(`forest ${mission.id} mission completes by walking ravines and caves with public interactions`, () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, danger: 'calm', mission: mission.id, seed: 'forest-mission' });
  for (const objective of sim.objectives) {
    walkTo(sim, objective);
    assert.equal(sim.interaction.id, objective.id);
    assert.ok(sim.interact());
    if (mission.id === 'repair') sim.step(4.1);
  }
  const exit = { x: sim.exit.x * CELL, z: sim.exit.z * CELL };
  walkTo(sim, exit);
  if (mission.id === 'rescue') {
    sim.step(3);
    assert.equal(sim.rescue.y, getTerrainHeight(sim.terrain, sim.rescue.x, sim.rescue.z));
    assert.equal(sim.objectives[0].y, sim.rescue.y);
  }
  assert.equal(sim.status, 'won');
});

test('friendly elves refill both carried firearms and magazines only when needed; cooldown pauses with gameplay', () => {
  for (const loadout of [['machinegun', 'rocket'], ['laser', 'machinegun']]) {
    const sim = new GameSimulation({ biome: 'forest', size: 25, danger: 'calm', loadout });
    const elf = sim.allies[0];
    walkTo(sim, elf);
    assert.equal(sim.interaction.type, 'resupply');
    assert.equal(sim.interact(), false);
    assert.equal(elf.cooldown, 0);
    for (const item of sim.inventory) { item.charges = 0; item.magazine = 0; item.reloadRemaining = 1; }
    assert.equal(sim.interact(), true);
    for (const item of sim.inventory) {
      assert.equal(item.charges, TOOLS.find((tool) => tool.id === item.id).charges);
      if (item.id === 'machinegun') { assert.equal(item.magazine, 30); assert.equal(item.reloadRemaining, 0); }
    }
    assert.equal(elf.cooldown, 45);
    sim.inventory[0].charges -= 1;
    assert.equal(sim.interact(), false);
    const elapsed = sim.elapsed;
    sim.status = 'paused';
    sim.step(60);
    assert.equal(sim.elapsed, elapsed);
    assert.equal(elf.cooldown, 45);
    sim.status = 'playing';
    sim.step(45.1);
    assert.equal(elf.cooldown, 0);
    assert.equal(sim.interact(), true);
    assert.equal(elf.cooldown, 45);
    assert.ok(sim.inSanctuary);
  }
});

test('forest encounters contain faster wolves and tough orcs at the actual terrain height', () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, danger: 'normal', seed: 'pack' });
  sim.step(26.1);
  assert.ok(sim.monsters.length >= 4);
  assert.deepEqual(new Set(sim.monsters.map((monster) => monster.type)), new Set(['wolf', 'orc']));
  for (const monster of sim.monsters) {
    assert.equal(monster.y, getTerrainHeight(sim.terrain, monster.x, monster.z));
    assert.ok(!sim._isSanctuary(monster));
    assert.equal(monster.maxHealth, monster.type === 'wolf' ? 85 : 210);
  }
  assert.equal(sim.queueWorldEvent('shift'), false);
  assert.equal(sim.queueWorldEvent('flood'), false);
  assert.deepEqual(sim._shiftWalls(), []);
});

test('cave roofs and sloping ground stop gunfire and rockets while outdoor sky remains open', () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, danger: 'calm', loadout: ['laser', 'rocket'] });
  const cave = sim.terrain.caves[0];
  const cell = cave.cells[Math.floor(cave.cells.length / 2)];
  walkTo(sim, { x: cell.x * CELL, z: cell.z * CELL });
  const origin = { x: sim.player.x, z: sim.player.z, y: sim.player.y + 1.72 };
  const ceiling = sim.getAimTarget(origin, { x: 0, y: 1, z: 0 }, 20);
  assert.ok(ceiling.hit);
  assert.ok(Math.abs(ceiling.y - getTerrainCeiling(sim.terrain, origin.x, origin.z)) < 0.01);
  const ground = sim.getAimTarget(origin, { x: 0, y: -1, z: 0 }, 20);
  assert.ok(ground.hit);
  assert.ok(Math.abs(ground.y - sim.player.y - 0.12) < 0.01);
  assert.ok(sim.useTool(1, 0, 0, { origin, direction: { x: 0, y: 1, z: 0 } }));
  sim.step(0.45);
  assert.equal(sim.projectiles.length, 0);
  assert.ok(sim.weaponEffects.some((effect) => effect.type === 'explosion'));
  walkTo(sim, sim.allies[0]);
  const sky = sim.getAimTarget({ x: sim.player.x, z: sim.player.z, y: sim.player.y + 1.72 }, { x: 0, y: 1, z: 0 }, 20);
  assert.equal(sky.hit, false);
});

test('wolf hitboxes follow their low body at the ravine floor and friendly elves never become weapon targets', () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, danger: 'calm', loadout: ['laser', 'rocket'] });
  const cave = sim.terrain.caves[0];
  const z = (cave.minZ + cave.maxZ) / 2;
  const x = sim.terrain.ravine.centerX;
  const wolf = { id: 101, type: 'wolf', x: x + 2.5, z, y: getTerrainHeight(sim.terrain, x + 2.5, z), level: 0, health: 85, age: 0 };
  Object.assign(sim.player, { x, z, y: getTerrainHeight(sim.terrain, x, z) });
  sim.monsters.push(wolf);
  const low = { x, z, y: wolf.y + 0.75 };
  const target = sim.getAimTarget(low, { x: 1, y: 0, z: 0 }, 10);
  assert.equal(target.monsterId, wolf.id);
  assert.ok(sim.useTool(0, 0, 0, { origin: low, direction: { x: 1, y: 0, z: 0 } }));
  assert.equal(wolf.health, 47);
  const over = sim.getAimTarget({ ...low, y: wolf.y + 1.6 }, { x: 1, y: 0, z: 0 }, 10);
  assert.equal(over.monsterId, undefined);
  sim.monsters.length = 0;
  const elf = sim.allies[0];
  const before = { ...elf };
  Object.assign(sim.player, { x: elf.x - 2, z: elf.z, y: getTerrainHeight(sim.terrain, elf.x - 2, elf.z) });
  const elfRay = sim.getAimTarget({ x: sim.player.x, z: elf.z, y: elf.y + 1.35 }, { x: 1, y: 0, z: 0 }, 3);
  assert.equal(elfRay.monsterId, undefined);
  sim._explode({ type: 'rocket', x: elf.x, z: elf.z, y: elf.y + 1.35, level: 0 });
  assert.deepEqual(elf, before);
});

test('a cave roof blocks sight and gunfire between actors despite a clear horizontal grid route', () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, danger: 'normal', seed: 'cover' });
  const from = { x: 14.4, z: 25.2, y: sim._floorAt(14.4, 25.2), level: 0 };
  const target = { id: 801, type: 'orc', x: 61.2, z: 25.2, y: sim._floorAt(61.2, 25.2), level: 0, health: 210 };
  for (let x = 4; x <= 17; x += 1) assert.ok(walkable(sim.maze, x, 7));
  assert.equal(sim._lineOfSight(from, target), false);
  // A shot from this exposed shoulder meets the front edge of the cavern roof.
  const origin = { ...from, y: from.y + 1.35 };
  const dx = target.x - origin.x;
  const dy = target.y + 1.35 - origin.y;
  const length = Math.hypot(dx, dy);
  const ray = sim.getAimTarget(origin, { x: dx / length, y: dy / length, z: 0 }, length);
  assert.equal(ray.hit, true);
  assert.ok(ray.distance < length - 1);
});

test('hunting wolves outrun orcs while both stay attached to the sloping cave ground', () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, danger: 'normal', seed: 'pace' });
  const cave = sim.terrain.caves[0];
  const z = (cave.minZ + cave.maxZ) / 2;
  const x = cave.minX + CELL;
  Object.assign(sim.player, { x: x + CELL * 3, z, y: sim._floorAt(x + CELL * 3, z) });
  const monsters = ['wolf', 'orc'].map((type, index) => ({ id: index + 701, type, x, z,
    y: sim._floorAt(x, z), level: 0, age: 0, memory: 7, lastKnown: { x: sim.player.x, z }, attackCooldown: 0 }));
  sim.monsters.push(...monsters);
  sim._moveMonsters(0.5);
  const [wolf, orc] = monsters;
  assert.equal(wolf.state, 'hunting');
  assert.equal(orc.state, 'hunting');
  assert.ok(wolf.x - x > (orc.x - x) * 1.4);
  assert.equal(wolf.y, sim._floorAt(wolf.x, wolf.z));
  assert.equal(orc.y, sim._floorAt(orc.x, orc.z));
});

test('skyward laser rays and rockets pass above finite woodland obstacles while walking keeps its closed boundary', () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, seed: 'FOREST-FRIENDS', danger: 'calm', loadout: ['laser', 'rocket'] });
  const origin = { x: sim.player.x, y: sim.player.y + 1.72, z: sim.player.z };
  const direction = { x: 0.6, y: 0.8, z: 0 };
  // Previously this visibly empty sky hit an infinitely tall grid cell at
  // x=26.95, y=32.85. The ray must now continue above banks, rocks and trunks.
  const sky = sim.getAimTarget(origin, direction, 55);
  assert.equal(sky.hit, false);
  assert.equal(sky.distance, 55);
  assert.ok(sim.useTool(0, 0, 0, { origin, direction }));
  assert.equal(sim.weaponEffects.at(-1).hit, false);
  assert.ok(sim.weaponEffects.at(-1).toY > 40);
  assert.ok(sim.useTool(1, 0, 0, { origin, direction }));
  sim.step(2.4);
  assert.equal(sim.projectiles.length, 1);
  assert.ok(sim.projectiles[0].x > 26.95);
  assert.ok(sim.projectiles[0].y > 32.85);
  assert.ok(!sim.weaponEffects.some(effect => effect.type === 'explosion'));
  assert.equal(sim._canOccupy(0, 0, 0.28), false);
  assert.equal(sim._canOccupy(-CELL, 3 * CELL, 0.28), false);
});

test('finite trunk and rock volumes still stop bullets, and cave roofs do not extend upward into the sky', () => {
  const sim = new GameSimulation({ biome: 'forest', size: 25, seed: 'FOREST-FRIENDS', danger: 'calm' });
  const tree = sim.terrain.obstacles.treeSets.flat()[0];
  const h = 3;
  const localX = Math.sin(h * 0.18) * 0.45 * tree.sx;
  const localZ = Math.sin(h * 0.3) * 0.13 * tree.sz;
  const centre = { x: tree.x + Math.cos(tree.angle) * localX + Math.sin(tree.angle) * localZ,
    y: tree.y + h * tree.sy, z: tree.z - Math.sin(tree.angle) * localX + Math.cos(tree.angle) * localZ };
  const trunkRay = sim.getAimTarget({ ...centre, x: centre.x - 1.3 }, { x: 1, y: 0, z: 0 }, 2.6);
  assert.equal(trunkRay.hit, true);
  assert.ok(trunkRay.distance < 1.3);
  const rock = sim.terrain.obstacles.rocks[0];
  const rockRay = sim.getAimTarget({ x: rock.x - 2.1, y: rock.y + rock.sy * 0.5, z: rock.z }, { x: 1, y: 0, z: 0 }, 4.2);
  assert.equal(rockRay.hit, true);
  assert.ok(rockRay.distance < 2.1);
  const cave = sim.terrain.caves[0];
  const z = (cave.minZ + cave.maxZ) / 2;
  const overRoof = sim.getAimTarget({ x: cave.minX - 2, y: 35, z }, { x: 1, y: 0, z: 0 }, cave.maxX - cave.minX + 4);
  assert.equal(overRoof.hit, false);
});


test('seeded forest relief has curved ravines, visible hills and bounded continuous walking gradients', () => {
  for (const size of [9, 15, 25, 51]) for (const seed of ['moon', 'roots', 'wolf']) {
    const { terrain } = generateExpedition({ biome: 'forest', size, seed });
    let minimum = Infinity, maximum = -Infinity;
    for (let z = CELL / 2; z < (size - 1) * CELL; z += 0.9) {
      for (let x = CELL / 2; x < (size - 1) * CELL; x += 0.9) {
        const y = getTerrainHeight(terrain, x, z);
        minimum = Math.min(minimum, y); maximum = Math.max(maximum, y);
        const dx = (getTerrainHeight(terrain, x + .01, z) - getTerrainHeight(terrain, x - .01, z)) / .02;
        const dz = (getTerrainHeight(terrain, x, z + .01) - getTerrainHeight(terrain, x, z - .01)) / .02;
        assert.ok(Math.hypot(dx, dz) < 1, 'every sampled direction has a walkable slope below 45 degrees');
      }
    }
    if (size >= 25) {
      assert.ok(maximum - minimum > 12, 'ridges and ravine create substantial physical elevation');
      const centers = Array.from({ length: 20 }, (_, i) => getRavineCenter(terrain, i * size * CELL / 20));
      assert.ok(Math.max(...centers) - Math.min(...centers) > 3.5, 'ravine bends reveal changing near and far silhouettes');
    }
  }
});

test('earth banks form rounded smooth mounds confined to blocked cells', () => {
  const maze = { size: 5, grid: Array.from({ length: 5 }, () => [0, 0, 0, 0, 0]) };
  maze.grid[2][2] = 1;
  const x = CELL * 2, z = CELL * 2;
  const center = forestBankHeight(maze, x, z);
  const shoulder = forestBankHeight(maze, x + .6, z);
  const rim = forestBankHeight(maze, x + 1.2, z);
  assert.ok(center > shoulder && shoulder > rim && rim > 0, 'there is no flat top or rectangular plateau');
  assert.ok(forestBankHeight(maze, x + .9, z + .9) < forestBankHeight(maze, x + .9, z), 'corners round away');
  assert.equal(forestBankHeight(maze, x + CELL, z), 0, 'adjacent passable cell stays at its shared walking height');
  assert.equal(forestBankHeight(maze, x + 2.1, z), 0, 'mounds do not protrude into the player clearance');
});
