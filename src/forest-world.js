import { createRng, generateMaze, reachableCells, walkable } from './maze.js';

const CELL = 3.6;
const key = ({ x, z }) => `${x},${z}`;
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const smooth = (value) => value * value * (3 - 2 * value);

/** Gentle, seeded bends reveal different sides of the ravine as the player walks. */
export function getRavineCenter(terrain, z) {
  const span = (terrain.size - 3) * CELL;
  const bend = terrain.ravine.bend ?? 0;
  return terrain.ravine.centerX + bend * (Math.sin(z / span * Math.PI * 2 + terrain.phase)
    + 0.28 * Math.sin(z / span * Math.PI * 4 - terrain.phase));
}

/** One continuous ground surface, shared by walking, aiming and terrain meshes.
 * Broad ridges provide perspective; smaller rolls make movement reveal nearby
 * ground. Frequencies and amplitudes are bounded to retain traversable slopes. */
export function getTerrainHeight(terrain, x, z) {
  if (!terrain || terrain.kind !== 'forest') return 0;
  const { width, depth } = terrain.ravine;
  const inward = clamp(1 - Math.abs(x - getRavineCenter(terrain, z)) / (width / 2), 0, 1);
  const basin = smooth(clamp(inward / 0.8, 0, 1));
  const scale = clamp((terrain.size - 9) / 16, 0, 1);
  const phase = terrain.phase;
  const hills = Math.sin(x * 0.055 + phase) * Math.sin(z * 0.069 - phase * 0.7) * 2.1
    + Math.sin(x * 0.11 + z * 0.037 + phase) * 0.72;
  const ripples = Math.sin(x * 0.23 + phase) * Math.cos(z * 0.19) * 0.15
    + Math.sin(z * 0.39 - x * 0.14) * 0.055;
  // The compact forest keeps its deep central route without steep new slopes.
  return -depth * basin + scale * (hills * (1 - basin * 0.72) + ripples)
    + Math.sin(z * 0.09 + phase) * Math.sin(x * 0.12) * 0.12 * basin;
}

export function getTerrainCave(terrain, x, z) {
  return terrain?.caves?.find((cave) => x >= cave.minX && x <= cave.maxX
    && z >= cave.minZ && z <= cave.maxZ) ?? null;
}

/** Outward scallops occupy the blocked bank, preserving the full clear route. */
export function getCaveWallOffset(cave, x, side, heightFraction = 1) {
  const phase = cave.type === 'cave-roots' ? 1.7 : 0.3;
  const scallop = 0.46 + 0.24 * Math.sin(x * 0.43 + side * 1.7 + phase)
    + 0.16 * Math.sin(x * 1.17 - side * 0.8);
  return 0.12 + scallop * (0.6 + 0.4 * Math.sin(heightFraction * Math.PI * 0.8))
    + 0.14 * Math.sin(x * 1.8 + heightFraction * 8) ** 2;
}

export function getCaveRoofHeight(terrain, cave, x, z) {
  const half = (cave.maxZ - cave.minZ) / 2;
  const cross = clamp((z - (cave.minZ + cave.maxZ) / 2) / half, -1, 1);
  const arch = Math.max(0, 1 - cross * cross);
  const chamber = Math.sin((x - cave.minX) / (cave.maxX - cave.minX) * Math.PI);
  return getTerrainHeight(terrain, x, z) + cave.ceilingHeight + arch * (1.25 + chamber * 0.6)
    + 0.18 * Math.sin(x * 0.83 + z * 0.67) * arch;
}

export function getCaveRoofTop(terrain, cave, x, z) {
  const span = (x - cave.minX) / (cave.maxX - cave.minX);
  return getCaveRoofHeight(terrain, cave, x, z) + 2.05 + Math.sin(clamp(span, 0, 1) * Math.PI) * 1.25;
}

export function getTerrainCeiling(terrain, x, z) {
  const cave = getTerrainCave(terrain, x, z);
  return cave ? getCaveRoofHeight(terrain, cave, x, z) : Infinity;
}

export function getTerrainZone(terrain, x, z) {
  const cave = getTerrainCave(terrain, x, z);
  return cave?.type ?? (getTerrainHeight(terrain, x, z) < -1.4 ? 'ravine' : 'forest');
}

/** A forest of wide paths and clearings, with two walk-through cave systems.
 * Cave walls and random rock banks use the same navigation grid as all actors;
 * roofs and the ravine are continuous world-space geometry, never teleporters. */
export function generateForestExpedition(config, biome, mission) {
  const maze = generateMaze(config);
  const { size } = maze;
  const rng = createRng(`${maze.seed}:forest`);
  maze.grid = Array.from({ length: size }, (_, z) => Array.from({ length: size }, (_, x) =>
    x === 0 || z === 0 || x === size - 1 || z === size - 1 ? 1 : 0));
  const depth = Math.min(10.5 + Math.max(0, size - 25) * 0.18, (size - 3) * CELL * 0.23);
  const terrain = { kind: 'forest', size, cell: CELL, seed: maze.seed, depth, phase: rng() * Math.PI * 2,
    ravine: { centerX: (size - 1) * CELL * 0.5, width: (size - 3) * CELL * (size >= 25 ? 0.8 : 1),
      depth, bend: Math.max(0, size - 9) * 0.13 }, caves: [] };
  const point = ({ x, z }) => ({ x: x * CELL, z: z * CELL, y: getTerrainHeight(terrain, x * CELL, z * CELL), level: 0 });
  const protectedCells = new Set();
  const protect = (cell) => { protectedCells.add(key(cell)); maze.grid[cell.z][cell.x] = 0; };
  const cellsIn = (x0, x1, z0, z1) => {
    const result = [];
    for (let z = z0; z <= z1; z += 1) for (let x = x0; x <= x1; x += 1) result.push({ x, z });
    return result;
  };
  const campCells = [cellsIn(1, 2, 1, 2), cellsIn(size - 3, size - 2, 1, 2)];
  for (const cell of campCells.flat()) protect(cell);
  protect(maze.start);
  const rooms = campCells.map((cells, index) => ({ id: `forest-camp-${index}`, type: 'sanctuary',
    name: index ? 'Lager der Mondelfen' : 'Hain der Waldhüter', ...point(cells.at(-1)), radius: CELL * 1.3, cells }));
  const allies = rooms.map((room, index) => ({ id: `elf-${index}`, type: 'elf', label: index ? 'Liora · Mondelfe' : 'Aelwen · Waldhüterin',
    x: room.x, z: room.z, y: room.y, level: 0, cooldown: 0 }));
  const halfWidth = size >= 15 ? 1 : 0;
  const length = Math.max(3, Math.floor(size * 0.30));
  const caveCenters = [Math.max(2, Math.round((size - 1) * 0.32)), Math.min(size - 3, Math.round((size - 1) * 0.76))];
  for (let index = 0; index < 2; index += 1) {
    const z = caveCenters[index];
    const x0 = clamp(Math.round((size - 1) * (index ? 0.58 : 0.44)) - Math.floor(length / 2), 2, size - 3 - length + 1);
    const x1 = x0 + length - 1;
    const z0 = z - halfWidth;
    const z1 = z + halfWidth;
    const cells = cellsIn(x0, x1, z0, z1);
    for (const cell of cells) protect(cell);
    // The full width of each end is an entrance. Preserve a three-cell-long
    // clear approach, so random boulders cannot close or narrow either mouth.
    for (const cell of cellsIn(Math.max(1, x0 - 2), Math.min(size - 2, x1 + 2), z0, z1)) protect(cell);
    for (const side of [z0 - 1, z1 + 1]) for (let x = x0; x <= x1; x += 1) {
      if (!protectedCells.has(`${x},${side}`)) maze.grid[side][x] = 1;
    }
    const cave = { id: `forest-cave-${index}`, type: index ? 'cave-roots' : 'cave-rock',
      name: index ? 'Wurzelhöhle' : 'Tropfsteingrotte', minX: (x0 - 0.5) * CELL, maxX: (x1 + 0.5) * CELL,
      minZ: (z0 - 0.5) * CELL, maxZ: (z1 + 0.5) * CELL, ceilingHeight: index ? 4.5 : 5.2, cells,
      mouths: [ { x: (x0 - 0.5) * CELL, z: z * CELL, side: 'west' },
        { x: (x1 + 0.5) * CELL, z: z * CELL, side: 'east' } ] };
    for (const mouth of cave.mouths) mouth.y = getTerrainHeight(terrain, mouth.x, mouth.z);
    terrain.caves.push(cave);
    rooms.push({ id: cave.id, type: cave.type, name: cave.name, ...point({ x: x0, z }), radius: CELL * 1.5, cells });
  }
  // Connect every initial clearing around the banks before scattering rocks.
  // Even the compact 9×9 layout keeps both cave mouths connected to outdoors.
  let floors = reachableCells(maze);
  if (floors.length !== maze.grid.flat().filter((value) => value === 0).length) {
    for (const cave of terrain.caves) for (const cell of cave.cells) protect(cell);
    for (let z = 1; z < size - 1; z += 1) { protect({ x: 1, z }); protect({ x: size - 2, z }); }
  }
  const density = 0.10 + maze.complexity / 100 * 0.14;
  const candidates = [];
  for (let z = 1; z < size - 1; z += 1) for (let x = 1; x < size - 1; x += 1) {
    if (!protectedCells.has(`${x},${z}`) && maze.grid[z][x] === 0 && rng() < density) candidates.push({ x, z });
  }
  let floorCount = maze.grid.flat().filter((value) => value === 0).length;
  for (const cell of candidates) {
    maze.grid[cell.z][cell.x] = 1;
    if (reachableCells(maze).length !== floorCount - 1) maze.grid[cell.z][cell.x] = 0;
    else floorCount -= 1;
  }
  floors = reachableCells(maze);
  const reserved = new Set([...campCells.flat().map(key), key(maze.start), ...rooms.map((room) => key({ x: Math.round(room.x / CELL), z: Math.round(room.z / CELL) }))]);
  const choose = (preferred) => {
    const result = preferred.find((cell) => walkable(maze, cell.x, cell.z) && !reserved.has(key(cell)))
      ?? floors.find((cell) => !reserved.has(key(cell)));
    reserved.add(key(result));
    return { ...result };
  };
  maze.exit = choose([...floors].reverse().filter((cell) => !getTerrainCave(terrain, cell.x * CELL, cell.z * CELL)));
  const targets = terrain.caves.map((cave) => choose([...cave.cells].sort((a, b) =>
    Math.abs(a.x * CELL - terrain.ravine.centerX) - Math.abs(b.x * CELL - terrain.ravine.centerX))));
  targets.push(choose([...floors].reverse().filter((cell) => !getTerrainCave(terrain, cell.x * CELL, cell.z * CELL))));
  maze.relics = targets;
  const objectiveCells = mission.id === 'rescue' ? [targets[1]] : targets;
  const objectives = objectiveCells.map((cell, index) => ({ id: `forest-${mission.id}-${index}`, ...point(cell), completed: false,
    type: mission.id === 'repair' ? 'mechanism' : mission.id === 'rescue' ? 'survivor' : 'seal',
    label: mission.id === 'repair' ? `Waldtorwerk ${index + 1}` : mission.id === 'rescue' ? 'Vermisster Forscher' : `Waldsiegel ${index + 1}` }));
  const rescue = mission.id === 'rescue' ? { ...point(objectiveCells[0]), following: false, rescued: false } : null;
  const treasures = terrain.caves.map((cave, index) => ({ id: `forest-treasure-${index}`, ...point(choose([...cave.cells].reverse())),
    value: index ? 4 : 2, trapped: Boolean(index), label: index ? 'Verwunschene Wurzeltruhe' : 'Verlorene Waldkasse', collected: false }));
  const hazardCandidates = floors.filter((cell) => !reserved.has(key(cell)) && !protectedCells.has(key(cell))
    && !getTerrainCave(terrain, cell.x * CELL, cell.z * CELL)
    && [[1, 0], [-1, 0], [0, 1], [0, -1]].filter(([dx, dz]) => walkable(maze, cell.x + dx, cell.z + dz)).length >= 3);
  const hazards = hazardCandidates.slice(-Math.min(5, Math.ceil(size / 10))).map((cell, index) => ({
    id: `forest-thorns-${index}`, type: 'thorns', ...point(cell), radius: 0.72 }));
  terrain.obstacles = createForestObstacles(maze, terrain);
  return { maze, levels: [{ index: 0, y: 0, maze }], ladders: [], exit: { ...maze.exit, level: 0 },
    terrain, rooms, allies, objectives, treasures, hazards, mission, biome, rescue };
}

/** Earth banks belong to blocked cells. Kept shared so shots meet the visible
 * bank surface while walking still uses the closed navigation perimeter. */
export function forestBankHeight(maze, x, z) {
  const cx = Math.round(x / CELL), cz = Math.round(z / CELL);
  let bank = 0;
  for (let dz = -1; dz <= 1; dz += 1) for (let dx = -1; dx <= 1; dx += 1) {
    const gx = cx + dx, gz = cz + dz;
    if (gx < 0 || gz < 0 || gx >= maze.size || gz >= maze.size || !maze.grid[gz][gx]) continue;
    const localX = x - gx * CELL, localZ = z - gz * CELL;
    const angle = Math.atan2(localZ, localX);
    const radius = CELL * (0.525 + 0.03 * Math.sin(angle * 3 + gx * 1.7 + gz));
    const radial = clamp(Math.hypot(localX, localZ) / radius, 0, 1);
    const edge = (1 - radial * radial) ** 2;
    const variation = 1.55 + 0.55 * Math.sin(gx * 2.8 + gz * 1.7) + 0.25 * Math.cos(gz * 3.1);
    bank = Math.max(bank, edge * variation);
  }
  return bank;
}

/** The renderer and ballistics consume the same seeded finite rock/trunk
 * transforms; decorative foliage is penetrable. Spatial buckets keep aiming
 * local even in the largest forest, instead of scanning every tree per ray. */
export function createForestObstacles(maze, terrain) {
  const treeSets = [[], [], []], rocks = [], caveWalls = [], ferns = [], byCell = {};
  const rng = createRng(`${maze.seed}:living-forest`);
  const sides = [{ x: 1, z: 0 }, { x: -1, z: 0 }, { x: 0, z: 1 }, { x: 0, z: -1 }];
  const remember = (gx, gz, object, kind) => {
    object.kind = kind;
    (byCell[`${gx},${gz}`] ??= []).push(object);
    return object;
  };
  for (let z = 0; z < maze.size; z += 1) for (let x = 0; x < maze.size; x += 1) {
    const px = x * CELL, pz = z * CELL, cave = getTerrainCave(terrain, px, pz), blocked = maze.grid[z][x];
    if (blocked) {
      const floor = getTerrainHeight(terrain, px, pz), ravine = getTerrainZone(terrain, px, pz) === 'ravine';
      const nextToCave = terrain.caves.some(c => px >= c.minX - CELL && px <= c.maxX + CELL && pz >= c.minZ - CELL && pz <= c.maxZ + CELL);
      const nearPath = sides.some(d => walkable(maze, x + d.x, z + d.z));
      if (cave || nextToCave) {
        const height = 2.8 + rng() * 1.4;
        caveWalls.push(remember(x, z, { x: px, y: floor + height * 0.45, z: pz, sx: 1.78, sy: height, sz: 1.78,
          angle: rng() * 0.28, tint: 0.75 + rng() * 0.22 }, 'rock'));
      } else if (ravine || rng() < 0.3) {
        const height = ravine ? 2.4 + rng() * 2.1 : 1.5 + rng() * 1.7;
        rocks.push(remember(x, z, { x: px + (rng() - 0.5) * 0.15, y: floor + height * 0.42, z: pz,
          sx: 1.45 + rng() * 0.2, sy: height, sz: 1.45 + rng() * 0.2,
          angle: rng() * Math.PI * 2, tint: 0.75 + rng() * 0.22 }, 'rock'));
      }
      if (!cave && !nextToCave && (nearPath || rng() < 0.7)) {
        const tx = px + (rng() - 0.5) * 0.45, tz = pz + (rng() - 0.5) * 0.45;
        const base = floor + forestBankHeight(maze, tx, tz) - 0.04, scale = 0.72 + rng() * 0.5;
        const tree = remember(x, z, { x: tx, y: base, z: tz, sx: 0.8 + rng() * 0.4, sy: scale, sz: 0.8 + rng() * 0.4,
          angle: rng() * Math.PI * 2, tint: 0.65 + rng() * 0.32,
          cellX: x, cellZ: z, torch: nearPath && ((x * 11 + z * 7) % 13 === 0 || (z === 0 && x === 1)) }, 'tree');
        treeSets[(x + z) % 3].push(tree);
      }
    } else if (!cave) {
      for (const side of sides.filter(d => !walkable(maze, x + d.x, z + d.z))) for (let n = 0; n < 2; n += 1) {
        const fx = px + side.x * 1.4 + (side.x ? 0 : (rng() - 0.5) * 2.2), fz = pz + side.z * 1.4 + (side.z ? 0 : (rng() - 0.5) * 2.2);
        ferns.push({ x: fx, y: getTerrainHeight(terrain, fx, fz) + 0.01, z: fz, scale: 0.6 + rng() * 0.8,
          angle: rng() * Math.PI * 2, tint: 0.7 + rng() * 0.3 });
      }
    }
  }
  return { treeSets, rocks, caveWalls, ferns, byCell };
}

export function forestSolidAt(maze, terrain, x, y, z, radius = 0.05) {
  const cave = getTerrainCave(terrain, x, z);
  const floor = getTerrainHeight(terrain, x, z);
  if (y <= floor + (cave ? 0 : forestBankHeight(maze, x, z)) + 0.12) return true;
  // A cave is a finite rock roof with open east/west mouths, not a column of
  // invisible stone extending from its ceiling all the way into the sky.
  if (cave && y >= getCaveRoofHeight(terrain, cave, x, z)
    && y <= getCaveRoofTop(terrain, cave, x, z) + radius) return true;
  for (const roof of terrain.caves) {
    if (x < roof.minX - radius || x > roof.maxX + radius) continue;
    const side = z < (roof.minZ + roof.maxZ) / 2 ? -1 : 1;
    const boundary = side < 0 ? roof.minZ : roof.maxZ;
    const outer = boundary + side * getCaveWallOffset(roof, x, side, 1);
    if ((z - boundary) * side >= 0 && (z - outer) * side <= radius
      && y >= getCaveRoofHeight(terrain, roof, x, z)
      && y <= getCaveRoofTop(terrain, roof, x, z) + radius) return true;
    const heightFraction = clamp((y - floor) / roof.ceilingHeight, 0, 1);
    const wallZ = boundary + side * getCaveWallOffset(roof, x, side, heightFraction);
    if (Math.abs(z - wallZ) > 0.16 + radius) continue;
    if (y >= floor - 0.3 && y <= getCaveRoofTop(terrain, roof, x, z)) return true;
  }
  const cx = Math.round(x / CELL), cz = Math.round(z / CELL);
  for (let dz = -1; dz <= 1; dz += 1) for (let dx = -1; dx <= 1; dx += 1) {
    for (const obstacle of terrain.obstacles?.byCell[`${cx + dx},${cz + dz}`] ?? []) {
      const px = x - obstacle.x, pz = z - obstacle.z;
      const angle = obstacle.angle, cos = Math.cos(angle), sin = Math.sin(angle);
      const lx = (cos * px - sin * pz) / obstacle.sx, lz = (sin * px + cos * pz) / obstacle.sz;
      const ly = (y - obstacle.y) / obstacle.sy;
      if (obstacle.kind === 'tree') {
        if (ly < -radius || ly > 12 + radius) continue;
        const tx = lx - Math.sin(ly * 0.18) * 0.45, tz = lz - Math.sin(ly * 0.3) * 0.13;
        const a = Math.atan2(tz, tx);
        const swell = 1 + 0.14 * Math.sin(a * 5 + ly * 0.8) + 0.12 * Math.sin(a * 9 - ly * 0.3);
        const flare = ly < 1.5 ? Math.pow(1 - Math.max(0, ly) / 1.5, 2) * 0.25 : 0;
        const trunkRadius = (0.58 - 0.46 * clamp(ly / 12, 0, 1)) * swell + flare;
        if (Math.hypot(tx, tz) < trunkRadius + radius / Math.min(obstacle.sx, obstacle.sz)) return true;
      } else if ((lx / (1 + radius / obstacle.sx)) ** 2 + (lz / (1 + radius / obstacle.sz)) ** 2
        + (ly / (1.125 + radius / obstacle.sy)) ** 2 <= 1) return true;
    }
  }
  return false;
}
