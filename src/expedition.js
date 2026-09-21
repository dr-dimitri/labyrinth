import { createRng, generateMaze, reachableCells, walkable } from './maze.js';
import { generateForestExpedition } from './forest-world.js';

const CELL = 3.6;
export const LEVEL_HEIGHT = 6;

export const BIOMES = Object.freeze([
  { id: 'catacombs', name: 'Katakomben', description: 'Steinerne Hallen, uralte Wächter und verborgene Bodenfallen.', unlockText: 'Von Beginn an verfügbar', hazard: 'spikes' },
  { id: 'ruins', name: 'Überwucherte Ruinen', description: 'Mondlicht fällt durch offene Gewölbe. Dornen versperren unachtsamen Reisenden den Weg.', unlockText: 'Nach deiner ersten erfolgreichen Expedition', hazard: 'thorns' },
  { id: 'mine', name: 'Verlassene Mine', description: 'Zwischen Stützbalken und Schienen sammeln sich giftige Gaswolken.', unlockText: '8 geborgene Werte oder 3 erfolgreiche Expeditionen', hazard: 'gas' },
  { id: 'forest', name: 'Dunkelwald', description: 'Fackeln zwischen alten Bäumen. Wölfe und Orks jagen durch Schluchten und Höhlen; freundliche Elfen versorgen dich mit Munition.', unlockText: 'Von Beginn an verfügbar', hazard: 'thorns' },
]);

export const MISSIONS = Object.freeze([
  { id: 'seals', name: 'Die drei Siegel', description: 'Berge drei verstreute Siegel und erreiche das Ausgangstor.', briefing: 'Drei Siegel halten den Ausgang verschlossen. Finde sie, nimm sie mit E an dich und entkomme durch das leuchtende Tor.' },
  { id: 'repair', name: 'Das Torwerk', description: 'Setze drei Mechanismen instand, um den Ausgang mit Energie zu versorgen.', briefing: 'Drei Maschinen sind verstummt. Beginne jede Reparatur mit E und bleibe einige Sekunden in ihrer Nähe. Sobald alle laufen, öffnet sich der Ausgang.' },
  { id: 'rescue', name: 'Die letzte Spur', description: 'Finde den vermissten Forscher und geleite ihn zum Ausgang.', briefing: 'Ein Forscher ist im Labyrinth eingeschlossen. Sprich ihn mit E an und geleite ihn zum Ausgang. Halte dich in seiner Nähe, damit er dir folgen kann.' },
]);

export const TOOLS = Object.freeze([
  { id: 'stone', name: 'Locksteine', description: 'Wirf einen Stein. Sein Aufprall lenkt geräuschempfindliche Wächter ab.', charges: 8, unlockText: 'Von Beginn an verfügbar' },
  { id: 'chalk', name: 'Wegkreide', description: 'Markiere den Boden, um Kreuzungen und Rückwege wiederzuerkennen.', charges: 12, unlockText: 'Von Beginn an verfügbar' },
  { id: 'machinegun', name: 'Maschinengewehr', description: 'Automatisches Feuer mit 30 Schuss pro Magazin und 180 Schuss Vorrat. Mit T nachladen.', charges: 180, magazine: 30, unlockText: 'Von Beginn an verfügbar' },
  { id: 'laser', name: 'Lasergewehr', description: 'Ein präziser Energiestrahl trifft den ersten Gegner in Schussrichtung. Wände blockieren den Strahl.', charges: 80, unlockText: 'Von Beginn an verfügbar' },
  { id: 'rocket', name: 'Raketenwerfer', description: 'Drei Raketen mit Flächenschaden. Halte Abstand zur Explosion; massive Wände bieten Deckung.', charges: 3, unlockText: 'Von Beginn an verfügbar' },
  { id: 'flare', name: 'Leuchtfackeln', description: 'Ein warmer Lichtkreis vertreibt Schatten und verschafft dir eine Atempause.', charges: 4, unlockText: 'Nach deiner ersten erfolgreichen Expedition' },
  { id: 'compass', name: 'Spurenkompass', description: 'Enthülle einen Weg zum nächsten Missionsziel oder zum Ausgang.', charges: 3, unlockText: 'Ab 6 geborgenen Werten' },
]);

const ROOM_TYPES = [
  { type: 'library', name: 'Archiv der Zeichen' },
  { type: 'flooded', name: 'Überflutete Halle' },
  { type: 'treasury', name: 'Vergessene Schatzkammer' },
];
const key = ({ x, z }) => `${x},${z}`;
const worldPoint = ({ x, z }) => ({ x: x * CELL, z: z * CELL });

function shuffled(values, rng) {
  const result = [...values];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const chosen = Math.floor(rng() * (index + 1));
    [result[index], result[chosen]] = [result[chosen], result[index]];
  }
  return result;
}

function distancesFrom(maze, origin) {
  const result = new Map([[key(origin), 0]]);
  const queue = [origin];
  for (let head = 0; head < queue.length; head += 1) {
    const point = queue[head];
    for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const next = { x: point.x + dx, z: point.z + dz };
      if (!walkable(maze, next.x, next.z) || result.has(key(next))) continue;
      result.set(key(next), result.get(key(point)) + 1);
      queue.push(next);
    }
  }
  return result;
}

function makeRoom(maze, definition, center, rng) {
  const cells = [];
  for (let z = center.z - 1; z <= center.z + 1; z += 1) {
    for (let x = center.x - 1; x <= center.x + 1; x += 1) {
      maze.grid[z][x] = 0;
      cells.push({ x, z });
    }
  }
  const room = { id: `room-${definition.type}`, ...definition, ...worldPoint(center), radius: CELL * 1.5, cells };
  if (room.type === 'library') {
    const sequence = shuffled([0, 1, 2], rng);
    const names = ['Sonne', 'Mond', 'Stern'];
    room.puzzle = {
      symbols: ['☀', '☾', '✦'], sequence,
      clue: `Am Anfang steht ${names[sequence[0]]}. Den Schluss bewacht ${names[sequence[2]]}. Dazwischen ruht ${names[sequence[1]]}.`,
    };
  }
  return room;
}

function createRooms(maze, rng) {
  // Every 3 × 3 rectangle intersects the connected odd-cell maze. Opening
  // these rooms therefore adds routes without leaving any isolated pocket.
  const upper = Math.max(2, Math.floor((maze.size - 4) / 2));
  const lower = maze.size - 1 - upper;
  const sample = (low, high) => low + Math.floor(rng() * (high - low + 1));
  const centers = [
    { x: sample(lower, maze.size - 3), z: sample(2, upper) },
    { x: sample(2, upper), z: sample(lower, maze.size - 3) },
    { x: sample(lower, maze.size - 3), z: sample(lower, maze.size - 3) },
  ];
  const definitions = shuffled(ROOM_TYPES, rng);
  return [
    makeRoom(maze, { type: 'sanctuary', name: 'Zuflucht' }, { x: 2, z: 2 }, rng),
    ...centers.map((center, index) => makeRoom(maze, definitions[index], center, rng)),
  ];
}

/** A reproducible expedition. Grid coordinates stay inside maze/room.cells;
 * all interactive entities are expressed in world metres. */
function generateSingleExpedition(options = {}) {
  const config = options && typeof options === 'object' ? options : {};
  const biome = BIOMES.find((entry) => entry.id === config.biome) ?? BIOMES.find((entry) => entry.id === 'catacombs');
  const mission = MISSIONS.find((entry) => entry.id === config.mission) ?? MISSIONS[0];
  const maze = generateMaze(config);
  const rng = createRng(`${maze.seed}:expedition:${biome.id}`);
  const rooms = createRooms(maze, rng);
  const sanctuary = rooms[0];
  const sanctuaryCells = new Set(sanctuary.cells.map(key));
  const roomCenters = new Set(rooms.map((room) => key({ x: Math.round(room.x / CELL), z: Math.round(room.z / CELL) })));
  const floors = reachableCells(maze);
  const distances = distancesFrom(maze, maze.start);

  // Rooms introduce shortcuts, so choose the finale and spread mission items
  // using the resulting routes, rather than the original uncarved maze.
  const farthest = [...floors].filter((point) => !roomCenters.has(key(point)) && !sanctuaryCells.has(key(point)))
    .sort((a, b) => distances.get(key(b)) - distances.get(key(a)));
  maze.exit = { ...farthest[0] };
  const reserved = new Set([key(maze.start), key(maze.exit), ...roomCenters]);
  const candidates = floors.filter((point) => !reserved.has(key(point))
    && !sanctuaryCells.has(key(point))
    && Math.hypot(point.x * CELL - sanctuary.x, point.z * CELL - sanctuary.z) > sanctuary.radius + 1);
  const separation = distancesFrom(maze, maze.exit);
  const scores = new Map(candidates.map((point) => [key(point), Math.min(distances.get(key(point)), separation.get(key(point)))]));
  const itemCells = [];
  for (let count = 0; count < 3; count += 1) {
    const available = candidates.filter((point) => !reserved.has(key(point)));
    available.sort((a, b) => scores.get(key(b)) - scores.get(key(a))
      || distances.get(key(b)) - distances.get(key(a)));
    const point = available[0];
    itemCells.push({ ...point });
    reserved.add(key(point));
    const fromItem = distancesFrom(maze, point);
    for (const cell of candidates) scores.set(key(cell), Math.min(scores.get(key(cell)), fromItem.get(key(cell))));
  }
  itemCells.sort((a, b) => distances.get(key(a)) - distances.get(key(b)));
  maze.relics = itemCells.map((point) => ({ ...point }));

  const targetCells = mission.id === 'rescue' ? [itemCells.at(-1)] : itemCells;
  const objectives = targetCells.map((point, index) => ({
    id: `${mission.id}-${index + 1}`,
    type: mission.id === 'repair' ? 'mechanism' : mission.id === 'rescue' ? 'survivor' : 'seal',
    ...worldPoint(point),
    label: mission.id === 'repair' ? `Torwerk ${index + 1}` : mission.id === 'rescue' ? 'Vermisster Forscher' : `Siegel ${index + 1}`,
    completed: false,
  }));
  const rescue = mission.id === 'rescue' ? { ...worldPoint(targetCells[0]), following: false, rescued: false } : null;

  const treasury = rooms.find((room) => room.type === 'treasury');
  const treasureCandidates = shuffled(treasury.cells.filter((point) => !reserved.has(key(point))), rng);
  // A 3 × 3 treasury always has enough free cells even if all three mission
  // targets and the exit happen to be nearby.
  const treasures = treasureCandidates.slice(0, 2).map((point, index) => {
    reserved.add(key(point));
    return { id: `treasure-${index + 1}`, ...worldPoint(point), value: index ? 4 : 2,
      trapped: index === 1, label: index ? 'Versiegelte Prunktruhe' : 'Alte Reisekasse', collected: false };
  });
  if (maze.size >= 19) {
    const extra = shuffled(candidates.filter((point) => !reserved.has(key(point))), rng)[0];
    reserved.add(key(extra));
    treasures.push({ id: 'treasure-3', ...worldPoint(extra), value: 3, trapped: true, label: 'Verlorener Hort', collected: false });
  }

  // Hazards occupy open areas with room to walk around them. Interactions,
  // sanctuary and exit remain clear; a hazard is never a required choke point.
  const hazardCandidates = shuffled(floors.filter((point) => !reserved.has(key(point))
    && !sanctuaryCells.has(key(point))
    && Math.hypot(point.x - maze.start.x, point.z - maze.start.z) >= 5
    && [[1, 0], [-1, 0], [0, 1], [0, -1]].filter(([dx, dz]) => walkable(maze, point.x + dx, point.z + dz)).length >= 3), rng);
  const hazards = [];
  for (const point of hazardCandidates) {
    if (hazards.length >= Math.min(7, Math.max(2, Math.floor(maze.size / 5)))) break;
    if (hazards.some((hazard) => Math.hypot(hazard.x - point.x * CELL, hazard.z - point.z * CELL) < CELL * 2)) continue;
    hazards.push({ id: `hazard-${hazards.length + 1}`, type: biome.hazard, ...worldPoint(point), radius: biome.id === 'mine' ? 1.35 : 0.95 });
  }

  return { maze, rooms, objectives, treasures, hazards, mission, biome, rescue };
}


/** Stacked, independently generated floors joined by two reachable ladder shafts.
 * Existing single-floor generation stays deterministic; interactive state lives in
 * the global arrays so leaving a floor never regenerates or resets it. */
export function generateExpedition(options = {}) {
  const config = options && typeof options === 'object' ? options : {};
  let requested;
  try { requested = Number(config.levels); } catch { requested = NaN; }
  const count = Number.isFinite(requested) ? Math.max(1, Math.min(3, Math.round(requested))) : 1;
  if (config.biome === 'forest') return generateForestExpedition(config, BIOMES.find((entry) => entry.id === 'forest'),
    MISSIONS.find((entry) => entry.id === config.mission) ?? MISSIONS[0]);
  const ground = generateSingleExpedition(config);
  const floors = [ground];
  for (let index = 1; index < count; index += 1) floors.push(generateSingleExpedition({
    ...config, seed: `${ground.maze.seed}:floor:${index}`,
  }));
  const levels = floors.map((floor, index) => ({ index, y: index * LEVEL_HEIGHT, maze: floor.maze }));
  for (const [index, floor] of floors.entries()) {
    for (const entity of [...floor.rooms, ...floor.objectives, ...floor.treasures, ...floor.hazards]) {
      entity.level = index;
      entity.y = index * LEVEL_HEIGHT;
      if (count > 1) entity.id += `-level-${index}`;
    }
    if (index > 0) {
      // The starting room remains a clear landing, but only the ground-floor
      // sanctuary confers healing and protection.
      const landing = floor.rooms.find((room) => room.type === 'sanctuary');
      landing.type = 'landing';
      landing.name = `Vorhalle · Ebene ${index + 1}`;
    }
    if (floor.rescue) Object.assign(floor.rescue, { level: index, y: index * LEVEL_HEIGHT });
  }
  const objectives = ground.mission.id === 'rescue'
    ? floors.at(-1).objectives
    : Array.from({ length: 3 }, (_, index) => {
      const floor = Math.round(index * (count - 1) / 2);
      return floors[floor].objectives[index];
    });
  const rescue = ground.mission.id === 'rescue' ? floors.at(-1).rescue : null;
  const rooms = floors.flatMap((floor) => floor.rooms);
  const treasures = floors.flatMap((floor) => floor.treasures);
  const hazards = floors.flatMap((floor) => floor.hazards);
  const ladders = [];
  const used = new Set();
  const cell = (entity) => ({ x: Math.round(entity.x / CELL), z: Math.round(entity.z / CELL) });
  for (let lower = 0; lower < count - 1; lower += 1) {
    const reserved = new Set([...rooms, ...objectives, ...treasures, ...hazards]
      .filter((entity) => entity.level === lower || entity.level === lower + 1).map((entity) => key(cell(entity))));
    for (const floor of [floors[lower], floors[lower + 1]]) {
      reserved.add(key(floor.maze.start));
      reserved.add(key(floor.maze.exit));
    }
    const candidates = reachableCells(floors[lower].maze).filter((point) =>
      walkable(floors[lower + 1].maze, point.x, point.z) && !reserved.has(key(point)) && !used.has(key(point)));
    for (let connector = 0; connector < 2; connector += 1) {
      const available = candidates.filter((point) => !used.has(key(point)));
      let chosen;
      if (lower === 0 && connector === 0) {
        // A straight, visible route from the spawn introduces vertical travel.
        chosen = available.find((point) => point.x === 3 && point.z === 1);
        chosen ??= available.sort((a, b) => (a.x + a.z) - (b.x + b.z))[0];
      } else {
        available.sort((a, b) => {
          const score = (point) => Math.min(...[{ x: 1, z: 1 }, ...ladders.map(cell)]
            .map((other) => Math.abs(point.x - other.x) + Math.abs(point.z - other.z)));
          return score(b) - score(a);
        });
        chosen = available[0];
      }
      if (!chosen) throw new Error('Keine freie Verbindung zwischen den Ebenen gefunden.');
      used.add(key(chosen));
      ladders.push({ id: `ladder-${lower}-${connector}`, ...worldPoint(chosen),
        fromLevel: lower, toLevel: lower + 1, bottomY: lower * LEVEL_HEIGHT, topY: (lower + 1) * LEVEL_HEIGHT });
    }
  }
  return { maze: ground.maze, levels, ladders, exit: { ...ground.maze.exit, level: 0 },
    rooms, objectives, treasures, hazards, mission: ground.mission, biome: ground.biome, rescue };
}
