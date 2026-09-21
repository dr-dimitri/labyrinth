import test from 'node:test';
import assert from 'node:assert/strict';
import { BIOMES, MISSIONS, TOOLS, generateExpedition } from '../src/expedition.js';
import { findPath, reachableCells, walkable } from '../src/maze.js';

const CELL = 3.6;
const key = ({ x, z }) => `${x},${z}`;
const cellOf = ({ x, z }) => ({ x: Math.round(x / CELL), z: Math.round(z / CELL) });

test('dungeon expeditions remain connected with complete reachable content for every size and dungeon biome', () => {
  for (const size of [9, 11, 15, 25, 35, 51]) {
    for (const complexity of [0, 55, 100]) {
      for (const biome of BIOMES.filter((entry) => entry.id !== 'forest')) {
        for (const seed of ['lantern', 'lost', 'seed-003']) {
          const expedition = generateExpedition({ size, complexity, biome: biome.id, seed });
          const { maze, rooms, objectives, treasures, hazards } = expedition;
          const label = JSON.stringify({ size, complexity, biome: biome.id, seed });
          assert.equal(reachableCells(maze).length, maze.grid.flat().filter((cell) => cell === 0).length, label);
          for (let index = 0; index < size; index += 1) {
            assert.equal(maze.grid[0][index], 1, label);
            assert.equal(maze.grid[size - 1][index], 1, label);
            assert.equal(maze.grid[index][0], 1, label);
            assert.equal(maze.grid[index][size - 1], 1, label);
          }
          assert.equal(rooms.length, 4);
          assert.deepEqual(new Set(rooms.map((room) => room.type)), new Set(['sanctuary', 'library', 'flooded', 'treasury']));
          const allRoomCells = rooms.flatMap((room) => room.cells);
          assert.equal(new Set(allRoomCells.map(key)).size, allRoomCells.length, label);
          for (const room of rooms) {
            assert.equal(room.cells.length, 9, label);
            assert.equal(new Set(room.cells.map((cell) => cell.x)).size, 3, label);
            assert.equal(new Set(room.cells.map((cell) => cell.z)).size, 3, label);
            assert.ok(room.cells.every((cell) => walkable(maze, cell.x, cell.z)), label);
          }
          const sanctuary = rooms.find((room) => room.type === 'sanctuary');
          assert.ok(Math.hypot(maze.start.x * CELL - sanctuary.x, maze.start.z * CELL - sanctuary.z) < sanctuary.radius, label);
          assert.equal(objectives.length, 3, label);
          assert.equal(maze.relics.length, 3, label);
          assert.ok(treasures.length >= 2, label);
          assert.ok(treasures.some((treasure) => treasure.trapped), label);
          assert.ok(treasures.some((treasure) => !treasure.trapped), label);
          assert.ok(hazards.length >= 1, label);
          assert.ok(hazards.every((hazard) => hazard.type === biome.hazard), label);
          const interactions = [...objectives, ...treasures, ...rooms];
          const cells = interactions.map(cellOf);
          assert.equal(new Set(cells.map(key)).size, cells.length, label);
          for (const destination of [...cells, ...hazards.map(cellOf), maze.exit, ...maze.relics]) {
            assert.ok(findPath(maze, maze.start, destination).length, label);
          }
          for (const objective of objectives) {
            assert.ok(Math.hypot(objective.x - sanctuary.x, objective.z - sanctuary.z) > sanctuary.radius + 1, label);
          }
          for (const hazard of hazards) {
            assert.ok(!cells.some((cell) => key(cell) === key(cellOf(hazard))), label);
          }
        }
      }
    }
  }
});

test('mission variations use independent state and the appropriate objective types', () => {
  for (const mission of MISSIONS) {
    const first = generateExpedition({ seed: 'objective', mission: mission.id });
    const second = generateExpedition({ seed: 'objective', mission: mission.id });
    assert.deepEqual(first, second);
    assert.equal(first.mission.id, mission.id);
    assert.ok(first.objectives.every((objective) => objective.completed === false));
    if (mission.id === 'rescue') {
      assert.equal(first.objectives.length, 1);
      assert.equal(first.objectives[0].type, 'survivor');
      assert.deepEqual(first.rescue, { x: first.objectives[0].x, z: first.objectives[0].z, following: false, rescued: false, level: 0, y: 0 });
    } else {
      assert.equal(first.objectives.length, 3);
      assert.equal(first.rescue, null);
      assert.ok(first.objectives.every((objective) => objective.type === (mission.id === 'seals' ? 'seal' : 'mechanism')));
    }
    first.objectives[0].completed = true;
    first.rooms[0].cells[0].x = -1;
    assert.equal(second.objectives[0].completed, false);
    assert.ok(second.rooms[0].cells[0].x > 0);
  }
});

test('seed controls layouts, room assignment and a solvable library clue', () => {
  const first = generateExpedition({ seed: 'moon-1', size: 25 });
  assert.deepEqual(first, generateExpedition({ seed: 'moon-1', size: 25 }));
  assert.notDeepEqual(first.maze.grid, generateExpedition({ seed: 'moon-2', size: 25 }).maze.grid);
  const observed = new Set();
  for (let seed = 0; seed < 20; seed += 1) {
    const { puzzle } = generateExpedition({ seed }).rooms.find((room) => room.type === 'library');
    assert.deepEqual([...puzzle.sequence].sort(), [0, 1, 2]);
    assert.equal(puzzle.symbols.length, 3);
    const names = ['Sonne', 'Mond', 'Stern'];
    assert.ok(puzzle.clue.startsWith(`Am Anfang steht ${names[puzzle.sequence[0]]}.`));
    assert.ok(puzzle.clue.includes(`Den Schluss bewacht ${names[puzzle.sequence[2]]}.`));
    observed.add(puzzle.sequence.join(','));
  }
  assert.ok(observed.size > 1);
});

test('invalid content settings fall back safely and all weapon definitions are usable', () => {
  for (const options of [undefined, null, false, 'invalid', { biome: 'missing', mission: 'missing', size: NaN }]) {
    const expedition = generateExpedition(options);
    assert.equal(expedition.biome.id, 'catacombs');
    assert.equal(expedition.mission.id, 'seals');
    assert.equal(expedition.maze.size, 15);
  }
  for (const id of ['laser', 'rocket', 'machinegun']) {
    const weapon = TOOLS.find((tool) => tool.id === id);
    assert.ok(weapon);
    assert.ok(Number.isInteger(weapon.charges) && weapon.charges > 0);
  }
  assert.equal(TOOLS.find((tool) => tool.id === 'machinegun').magazine, 30);
});
