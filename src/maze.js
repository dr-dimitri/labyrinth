/** Deterministic maze generation and grid navigation, independent of rendering. */

const DIRECTIONS = [
  { x: 1, z: 0 },
  { x: 0, z: 1 },
  { x: -1, z: 0 },
  { x: 0, z: -1 },
];
const DEFAULT_SEED = 'nachthall';

function finiteNumber(value, fallback) {
  try {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  } catch {
    return fallback;
  }
}

function normalizeSize(value) {
  const rounded = Math.round(finiteNumber(value, 15));
  const odd = rounded % 2 === 0 ? rounded + 1 : rounded;
  return Math.min(51, Math.max(9, odd));
}

/** Seeded random numbers in [0, 1), reproducible across platforms. */
export function createRng(seed = DEFAULT_SEED) {
  const text = String(seed ?? DEFAULT_SEED);
  let state = 2166136261;
  for (let index = 0; index < text.length; index += 1) {
    state = Math.imul(state ^ text.charCodeAt(index), 16777619);
  }
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = Math.imul(state ^ (state >>> 15), state | 1);
    mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
}

/** Accepts integer cell coordinates; positions outside the grid are walls. */
export function walkable(maze, x, z) {
  return Boolean(
    Number.isInteger(x) && Number.isInteger(z)
    && x >= 0 && z >= 0 && x < maze?.size && z < maze?.size
    && maze.grid?.[z]?.[x] === 0,
  );
}

function search(maze, from) {
  if (!walkable(maze, from?.x, from?.z)) return null;
  const { size } = maze;
  const distances = new Int32Array(size * size).fill(-1);
  const parents = new Int32Array(size * size).fill(-1);
  const queue = new Int32Array(size * size);
  const origin = from.z * size + from.x;
  distances[origin] = 0;
  queue[0] = origin;
  let head = 0;
  let tail = 1;

  while (head < tail) {
    const current = queue[head++];
    const x = current % size;
    const z = Math.floor(current / size);
    for (const direction of DIRECTIONS) {
      const nextX = x + direction.x;
      const nextZ = z + direction.z;
      if (!walkable(maze, nextX, nextZ)) continue;
      const next = nextZ * size + nextX;
      if (distances[next] !== -1) continue;
      distances[next] = distances[current] + 1;
      parents[next] = current;
      queue[tail++] = next;
    }
  }
  return { distances, parents, cells: queue.subarray(0, tail) };
}

function pointAt(index, size) {
  return { x: index % size, z: Math.floor(index / size) };
}

/** All connected floor cells, including the origin, in breadth-first order. */
export function reachableCells(maze, from = maze?.start) {
  const result = search(maze, from);
  return result ? Array.from(result.cells, (cell) => pointAt(cell, maze.size)) : [];
}

/** Shortest four-direction path, including both endpoints, or [] if unreachable. */
export function findPath(maze, from, to) {
  if (!walkable(maze, to?.x, to?.z)) return [];
  const result = search(maze, from);
  const target = to.z * maze.size + to.x;
  if (!result || result.distances[target] === -1) return [];
  const path = [];
  for (let cell = target; cell !== -1; cell = result.parents[cell]) {
    path.push(pointAt(cell, maze.size));
  }
  return path.reverse();
}

function placeRelics(maze, startSearch) {
  const { size } = maze;
  const startIndex = maze.start.z * size + maze.start.x;
  const exitIndex = maze.exit.z * size + maze.exit.x;
  const minimumDistances = Int32Array.from(startSearch.distances);
  const exitDistances = search(maze, maze.exit).distances;
  for (const cell of startSearch.cells) {
    minimumDistances[cell] = Math.min(minimumDistances[cell], exitDistances[cell]);
  }
  const excluded = new Set([startIndex, exitIndex]);
  const relics = [];
  // Farthest-point sampling uses actual route lengths so walls cannot make
  // apparently separated collectibles cluster along the same short corridor.
  for (let count = 0; count < 3; count += 1) {
    let bestCell = -1;
    let bestDistance = -1;
    for (const cell of startSearch.cells) {
      if (excluded.has(cell)) continue;
      const distance = minimumDistances[cell];
      if (distance > bestDistance || (distance === bestDistance
        && startSearch.distances[cell] > startSearch.distances[bestCell])) {
        bestCell = cell;
        bestDistance = distance;
      }
    }
    if (bestCell === -1) break;
    const point = pointAt(bestCell, size);
    relics.push(point);
    excluded.add(bestCell);
    const distances = search(maze, point).distances;
    for (const cell of startSearch.cells) {
      minimumDistances[cell] = Math.min(minimumDistances[cell], distances[cell]);
    }
  }
  return relics.sort((a, b) => startSearch.distances[a.z * size + a.x]
    - startSearch.distances[b.z * size + b.x]);
}

/**
 * Connected maze with a closed perimeter and 0=floor, 1=wall.
 * Size is rounded up to an odd integer after rounding, then clamped to 9..51.
 * Complexity is clamped to 0..100. Low values favor straight carving and open
 * many loops (alternate escape routes); high values branch more during carving
 * and retain dead ends. At 100 the corridor graph is a perfect maze (a tree).
 */
export function generateMaze(options = {}) {
  const { size: requestedSize = 15, complexity: requestedComplexity = 55,
    seed: requestedSeed = DEFAULT_SEED } = options ?? {};
  const size = normalizeSize(requestedSize);
  const complexity = Math.min(100, Math.max(0, finiteNumber(requestedComplexity, 55)));
  const seed = String(requestedSeed ?? DEFAULT_SEED);
  const rng = createRng(seed);
  const difficulty = complexity / 100;
  const grid = Array.from({ length: size }, () => Array(size).fill(1));
  const start = { x: 1, z: 1 };
  const active = [{ ...start, direction: -1 }];
  grid[1][1] = 0;

  while (active.length) {
    const index = rng() < difficulty * 0.24
      ? Math.floor(rng() * active.length) : active.length - 1;
    const current = active[index];
    const available = [];
    for (let direction = 0; direction < DIRECTIONS.length; direction += 1) {
      const vector = DIRECTIONS[direction];
      const x = current.x + vector.x * 2;
      const z = current.z + vector.z * 2;
      if (x > 0 && z > 0 && x < size - 1 && z < size - 1 && grid[z][x] === 1) {
        available.push(direction);
      }
    }
    if (!available.length) {
      active.splice(index, 1);
      continue;
    }
    const continueStraight = available.includes(current.direction)
      && rng() < 0.85 * (1 - difficulty);
    const direction = continueStraight
      ? current.direction : available[Math.floor(rng() * available.length)];
    const vector = DIRECTIONS[direction];
    const next = { x: current.x + vector.x * 2, z: current.z + vector.z * 2, direction };
    grid[current.z + vector.z][current.x + vector.x] = 0;
    grid[next.z][next.x] = 0;
    active.push(next);
  }

  const loopCandidates = [];
  for (let z = 1; z < size - 1; z += 1) {
    for (let x = 1; x < size - 1; x += 1) {
      if (grid[z][x] !== 1) continue;
      const horizontal = grid[z][x - 1] === 0 && grid[z][x + 1] === 0
        && grid[z - 1][x] === 1 && grid[z + 1][x] === 1;
      const vertical = grid[z - 1][x] === 0 && grid[z + 1][x] === 0
        && grid[z][x - 1] === 1 && grid[z][x + 1] === 1;
      if (horizontal || vertical) loopCandidates.push({ x, z });
    }
  }
  const loopCount = Math.round(loopCandidates.length * 0.52 * (1 - difficulty) ** 1.2);
  for (let index = 0; index < loopCount; index += 1) {
    const chosen = index + Math.floor(rng() * (loopCandidates.length - index));
    [loopCandidates[index], loopCandidates[chosen]] = [loopCandidates[chosen], loopCandidates[index]];
    const { x, z } = loopCandidates[index];
    grid[z][x] = 0;
  }

  const maze = { size, grid, start, exit: { ...start }, relics: [], seed, complexity };
  const startSearch = search(maze, start);
  let farthest = startSearch.cells[0];
  for (const cell of startSearch.cells) {
    if (startSearch.distances[cell] > startSearch.distances[farthest]) farthest = cell;
  }
  maze.exit = pointAt(farthest, size);
  maze.relics = placeRelics(maze, startSearch);
  return maze;
}

/**
 * Pick a reachable cell at least minDistance corridor steps from the player.
 * Avoid start, exit and relic cells whenever any other eligible cell exists.
 * Returns null if the player is invalid or no cell satisfies the path distance.
 */
export function chooseSpawnCell(maze, player, rng = Math.random, minDistance = 6) {
  const result = search(maze, player);
  if (!result) return null;
  const minimum = Math.max(0, finiteNumber(minDistance, 6));
  const reserved = new Set([maze.start, maze.exit, ...(maze.relics ?? [])]
    .filter(Boolean).map(({ x, z }) => z * maze.size + x));
  const candidates = [];
  const preferred = [];
  for (const cell of result.cells) {
    if (result.distances[cell] < minimum) continue;
    candidates.push(cell);
    if (!reserved.has(cell)) preferred.push(cell);
  }
  const pool = preferred.length ? preferred : candidates;
  if (!pool.length) return null;
  const sample = typeof rng === 'function' ? finiteNumber(rng(), 0) : 0;
  const index = Math.min(pool.length - 1, Math.max(0, Math.floor(sample * pool.length)));
  return pointAt(pool[index], maze.size);
}
