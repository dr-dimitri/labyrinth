import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createRng, generateMaze, walkable, reachableCells, findPath, chooseSpawnCell,
} from '../src/maze.js';

const key = ({ x, z }) => `${x},${z}`;
const neighbors = ({ x, z }) => [
  { x: x + 1, z }, { x: x - 1, z }, { x, z: z + 1 }, { x, z: z - 1 },
];

function independentDistances(maze, origin) {
  const distances = new Map([[key(origin), 0]]);
  const queue = [origin];
  for (let index = 0; index < queue.length; index += 1) {
    const current = queue[index];
    for (const next of neighbors(current)) {
      if (maze.grid[next.z]?.[next.x] !== 0 || distances.has(key(next))) continue;
      distances.set(key(next), distances.get(key(current)) + 1);
      queue.push(next);
    }
  }
  return distances;
}

test('seeded random numbers are reproducible and stay in [0, 1)', () => {
  const first = createRng('Der Wächter 👁');
  const second = createRng('Der Wächter 👁');
  const different = createRng('another seed');
  const sequence = Array.from({ length: 1000 }, () => first());
  assert.deepEqual(sequence, Array.from({ length: 1000 }, () => second()));
  assert.notDeepEqual(sequence.slice(0, 10), Array.from({ length: 10 }, () => different()));
  assert.ok(sequence.every((value) => value >= 0 && value < 1));
});

test('maze layouts and objectives are deterministic', () => {
  const settings = { size: 21, complexity: 71, seed: 'level-one' };
  assert.deepEqual(generateMaze(settings), generateMaze(settings));
  assert.notDeepEqual(generateMaze(settings).grid,
    generateMaze({ ...settings, seed: 'level-two' }).grid);
});

test('all floors connect, perimeter stays closed, objectives are reachable and spaced', () => {
  for (const size of [9, 15, 25, 35]) {
    for (const complexity of [0, 55, 100]) {
      for (const seed of ['catacomb', 'moon', '013']) {
        const maze = generateMaze({ size, complexity, seed });
        const label = JSON.stringify({ size, complexity, seed });
        assert.equal(maze.size, size, label);
        assert.deepEqual(maze.start, { x: 1, z: 1 }, label);
        for (let index = 0; index < size; index += 1) {
          assert.equal(maze.grid[0][index], 1, label);
          assert.equal(maze.grid[size - 1][index], 1, label);
          assert.equal(maze.grid[index][0], 1, label);
          assert.equal(maze.grid[index][size - 1], 1, label);
        }
        assert.ok(maze.grid.flat().every((value) => value === 0 || value === 1), label);
        const distances = independentDistances(maze, maze.start);
        const floorCount = maze.grid.flat().filter((value) => value === 0).length;
        assert.equal(distances.size, floorCount, label);
        assert.equal(reachableCells(maze, maze.start).length, floorCount, label);
        assert.equal(distances.get(key(maze.exit)), Math.max(...distances.values()), label);
        assert.ok(distances.get(key(maze.exit)) >= size - 2, label);
        assert.equal(maze.relics.length, 3, label);
        const objectives = [maze.start, maze.exit, ...maze.relics];
        assert.equal(new Set(objectives.map(key)).size, objectives.length, label);
        for (let first = 0; first < objectives.length; first += 1) {
          const objectiveDistances = independentDistances(maze, objectives[first]);
          for (let second = first + 1; second < objectives.length; second += 1) {
            assert.ok(objectiveDistances.get(key(objectives[second])) >= 3, label);
          }
        }
        for (const destination of [maze.exit, ...maze.relics]) {
          const path = findPath(maze, maze.start, destination);
          assert.deepEqual(path[0], maze.start, label);
          assert.deepEqual(path.at(-1), destination, label);
          assert.equal(path.length - 1, distances.get(key(destination)), label);
          path.forEach((cell, index) => {
            assert.ok(walkable(maze, cell.x, cell.z), label);
            if (index) assert.equal(Math.abs(cell.x - path[index - 1].x)
              + Math.abs(cell.z - path[index - 1].z), 1, label);
          });
        }
      }
    }
  }
});

test('complexity changes route choices, with no cycles at maximum complexity', () => {
  function cycleCount(maze) {
    const floors = reachableCells(maze, maze.start);
    const edges = floors.reduce((count, cell) => count
      + neighbors(cell).filter((neighbor) => walkable(maze, neighbor.x, neighbor.z)).length, 0) / 2;
    return edges - floors.length + 1;
  }
  for (const seed of ['a', 'b', 'c']) {
    const low = generateMaze({ size: 25, complexity: 0, seed });
    const middle = generateMaze({ size: 25, complexity: 55, seed });
    const high = generateMaze({ size: 25, complexity: 100, seed });
    assert.equal(cycleCount(high), 0);
    assert.ok(cycleCount(low) > cycleCount(middle));
    assert.ok(cycleCount(middle) > cycleCount(high));
    assert.notDeepEqual(low.grid, high.grid);
  }
});

test('settings normalize nonfinite, even and out-of-range values', () => {
  for (const size of [NaN, Infinity, -Infinity, 'bad', Symbol('size')]) {
    assert.equal(generateMaze({ size }).size, 15);
  }
  assert.equal(generateMaze({ size: -4 }).size, 9);
  assert.equal(generateMaze({ size: 1000 }).size, 51);
  assert.equal(generateMaze({ size: 10 }).size, 11);
  assert.equal(generateMaze({ size: '21' }).size, 21);
  assert.equal(generateMaze({ complexity: Infinity }).complexity, 55);
  assert.equal(generateMaze({ complexity: -1 }).complexity, 0);
  assert.equal(generateMaze({ complexity: 200 }).complexity, 100);
  assert.equal(generateMaze(null).size, 15);
});

test('navigation rejects invalid positions and handles disconnected floors', () => {
  const maze = generateMaze();
  assert.deepEqual(findPath(maze, maze.start, maze.start), [maze.start]);
  for (const point of [{ x: 0, z: 0 }, { x: -1, z: 1 }, { x: 1.5, z: 1 },
    { x: NaN, z: 1 }, { x: 1, z: Infinity }, { x: 999, z: 1 }, {}]) {
    assert.equal(walkable(maze, point.x, point.z), false);
    assert.deepEqual(findPath(maze, point, maze.start), []);
    assert.deepEqual(findPath(maze, maze.start, point), []);
    assert.deepEqual(reachableCells(maze, point), []);
  }
  assert.equal(walkable(null, 1, 1), false);
  assert.deepEqual(findPath(null, null, null), []);
  const split = { size: 5, grid: [
    [1, 1, 1, 1, 1], [1, 0, 1, 0, 1], [1, 1, 1, 1, 1],
    [1, 0, 1, 0, 1], [1, 1, 1, 1, 1],
  ] };
  assert.deepEqual(findPath(split, { x: 1, z: 1 }, { x: 3, z: 1 }), []);
});

test('spawns respect route distance and prefer cells without objectives', () => {
  const maze = generateMaze({ size: 25, complexity: 100, seed: 'hunted' });
  const reserved = new Set([maze.start, maze.exit, ...maze.relics].map(key));
  const rng = createRng('spawning');
  for (const player of [maze.start, maze.exit, ...maze.relics]) {
    const distances = independentDistances(maze, player);
    for (let index = 0; index < 30; index += 1) {
      const spawn = chooseSpawnCell(maze, player, rng, 12);
      assert.ok(spawn);
      assert.ok(distances.get(key(spawn)) >= 12);
      assert.equal(reserved.has(key(spawn)), false);
    }
  }
  assert.equal(chooseSpawnCell(maze, maze.start, rng, 100000), null);
  assert.equal(chooseSpawnCell(maze, { x: 0, z: 0 }, rng), null);
  assert.deepEqual(chooseSpawnCell(maze, maze.start, createRng('same')),
    chooseSpawnCell(maze, maze.start, createRng('same')));
  for (const sample of [NaN, Infinity, -1, 1, 2]) {
    assert.ok(chooseSpawnCell(maze, maze.start, () => sample));
  }
});

test('spawn distance follows corridors rather than geometric proximity', () => {
  const maze = { size: 5, start: { x: 1, z: 1 }, exit: { x: 1, z: 3 }, relics: [], grid: [
    [1, 1, 1, 1, 1], [1, 0, 0, 0, 1], [1, 1, 1, 0, 1],
    [1, 0, 0, 0, 1], [1, 1, 1, 1, 1],
  ] };
  // The exit is two cells away in space, but six corridor steps away.
  assert.deepEqual(chooseSpawnCell(maze, maze.start, () => 0, 6), maze.exit);
  assert.deepEqual(chooseSpawnCell(maze, maze.start, () => 0, 5), { x: 2, z: 3 });
});
