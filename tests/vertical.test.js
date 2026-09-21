import test from 'node:test';
import assert from 'node:assert/strict';
import { GameSimulation, CELL, LEVEL_HEIGHT } from '../src/simulation.js';
import { generateExpedition } from '../src/expedition.js';
import { findPath, reachableCells, walkable } from '../src/maze.js';

const cellOf = ({ x, z }) => ({ x: Math.round(x / CELL), z: Math.round(z / CELL) });
const key = ({ x, z }) => `${x},${z}`;
const separation = (a, b) => Math.hypot(a.x - b.x, a.z - b.z);

// Drive actual movement/collision along valid routes: mission tests never move
// the player to another floor or replace the generated expedition topology.
function walkTo(sim, point) {
  const path = findPath(sim.maze, cellOf(sim.player), cellOf(point));
  assert.ok(path.length, `Unreachable route on floor ${sim.player.level}`);
  for (const cell of path) {
    const target = { x: cell.x * CELL, z: cell.z * CELL };
    let steps = 0;
    while (separation(sim.player, target) > 0.015 && sim.status === 'playing') {
      assert.ok(steps++ < 150, `Blocked walking to ${key(cell)} on floor ${sim.player.level}`);
      const distance = separation(sim.player, target);
      sim.step(Math.min(0.12, distance / 4.5), {
        moveX: (target.x - sim.player.x) / distance,
        moveZ: (target.z - sim.player.z) / distance,
      });
    }
  }
}
function travelToFloor(sim, targetLevel) {
  while (sim.player.level !== targetLevel) {
    const level = sim.player.level;
    const ladder = sim.ladders.find((entry) => targetLevel > level ? entry.fromLevel === level : entry.toLevel === level);
    assert.ok(ladder);
    walkTo(sim, ladder);
    // Allow the escort to catch up to the ladder along its own route.
    if (sim.rescue?.following) sim.step(1);
    assert.equal(sim.interaction?.type, 'climb');
    assert.ok(sim.interact(), sim.events.at(-1)?.text);
    sim.step(3);
    assert.equal(sim.player.level, level + Math.sign(targetLevel - level));
    assert.equal(sim.player.y, sim.player.level * LEVEL_HEIGHT);
  }
}

test('up to 51 × 51 × 3 floors remain connected with clear, distinct reachable ladder landings', () => {
  for (const size of [9, 25, 51]) for (const count of [1, 2, 3]) for (const seed of ['shaft-a', 'shaft-b', 'shaft-c']) {
    const expedition = generateExpedition({ size, levels: count, seed, complexity: 100 });
    const { levels, ladders, rooms, objectives, treasures, hazards } = expedition;
    assert.equal(levels.length, count);
    assert.equal(ladders.length, (count - 1) * 2);
    assert.equal(new Set(ladders.map(key)).size, ladders.length);
    assert.equal(rooms.filter((room) => room.type === 'sanctuary').length, 1);
    assert.equal(expedition.exit.level, 0);
    assert.equal(new Set(objectives.map((objective) => objective.level)).size, count);
    const entities = [...rooms, ...objectives, ...treasures, ...hazards];
    assert.equal(new Set(entities.map((entry) => entry.id)).size, entities.length);
    for (const level of levels) {
      assert.equal(level.maze.size, size);
      const reachable = new Set(reachableCells(level.maze).map(key));
      assert.equal(reachable.size, level.maze.grid.flat().filter((cell) => cell === 0).length);
      for (let edge = 0; edge < size; edge += 1) {
        assert.equal(level.maze.grid[0][edge], 1);
        assert.equal(level.maze.grid[size - 1][edge], 1);
        assert.equal(level.maze.grid[edge][0], 1);
        assert.equal(level.maze.grid[edge][size - 1], 1);
      }
      for (const entity of entities.filter((entry) => entry.level === level.index)) {
        assert.equal(entity.y, level.index * LEVEL_HEIGHT);
        assert.ok(reachable.has(key(cellOf(entity))));
      }
      for (const ladder of ladders.filter((entry) => entry.fromLevel === level.index || entry.toLevel === level.index)) {
        assert.ok(reachable.has(key(cellOf(ladder))));
        assert.equal(ladder.topY - ladder.bottomY, LEVEL_HEIGHT);
        assert.ok(!entities.some((entity) => entity.level === level.index && key(cellOf(entity)) === key(cellOf(ladder))));
      }
    }
    if (count > 1) assert.deepEqual(cellOf(ladders[0]), { x: 3, z: 1 });
  }
});

test('level counts normalize safely and seed reproduces independent floor layouts', () => {
  for (const levels of [undefined, NaN, Infinity, -9, 'invalid', Symbol('levels')]) {
    assert.equal(generateExpedition({ levels }).levels.length, 1);
  }
  assert.equal(generateExpedition({ levels: 99 }).levels.length, 3);
  const first = generateExpedition({ levels: 3, seed: 'stacked' });
  assert.deepEqual(first, generateExpedition({ levels: 3, seed: 'stacked' }));
  assert.notDeepEqual(first.levels[0].maze.grid, first.levels[1].maze.grid);
  assert.notDeepEqual(first.levels[1].maze.grid, first.levels[2].maze.grid);
});

test('climbing ascends and descends smoothly, locks movement and weapons, and pauses exactly', () => {
  const sim = new GameSimulation({ levels: 3, danger: 'calm', loadout: ['laser', 'rocket'] });
  const ground = sim.maze;
  const explored = sim.explored;
  walkTo(sim, sim.ladders[0]);
  const action = sim.interaction;
  assert.match(action.label, /oben.*Ebene 2/);
  sim.player.z += 0.75;
  const initial = { ...sim.player };
  assert.ok(sim.interact());
  assert.equal(sim.player.z, initial.z, 'Starting a climb must not snap the camera');
  sim.step(0.1, { moveZ: 1 });
  assert.ok(sim.player.z < initial.z && sim.player.z > sim.ladders[0].z);
  assert.equal(sim.player.y, 0);
  sim.step(1.4, { moveX: 1, moveZ: 1, sprint: true });
  assert.ok(sim.player.y > 2 && sim.player.y < 4);
  assert.equal(sim.player.level, 0);
  assert.ok(Math.abs(sim.player.x - sim.ladders[0].x) < 1e-9);
  assert.ok(Math.abs(sim.player.z - sim.ladders[0].z) < 1e-9);
  assert.equal(sim.useTool(0, 0), false);
  assert.equal(sim.useTool(1, 0), false);
  assert.equal(sim.inventory[0].charges, 80);
  assert.equal(sim.interaction, null);
  const paused = JSON.stringify({ player: sim.player, climbing: sim.climbing, elapsed: sim.elapsed });
  sim.step(0); sim.step(NaN); sim.step(-1);
  assert.equal(JSON.stringify({ player: sim.player, climbing: sim.climbing, elapsed: sim.elapsed }), paused);
  sim.step(1.5);
  assert.equal(sim.climbing, null);
  assert.equal(sim.player.level, 1);
  assert.equal(sim.player.y, 6);
  assert.equal(sim.mapRevision, 1);
  assert.equal(sim.maze, sim.levels[1].maze);
  assert.equal(sim.explored, sim.exploredByLevel[1]);
  assert.notEqual(sim.explored, explored);
  assert.equal(sim.inSanctuary, false);
  assert.match(sim.interaction.label, /unten.*Ebene 1/);
  sim.interact(); sim.step(1.5);
  assert.ok(sim.player.y > 2 && sim.player.y < 4);
  sim.step(1.5);
  assert.equal(sim.player.y, 0);
  assert.equal(sim.maze, ground);
  assert.equal(sim.explored, explored);
  assert.equal(sim.mapRevision, 2);
});

for (const mission of ['seals', 'repair', 'rescue']) test(`three-floor ${mission} mission is completable by walking, interacting and climbing back to ground`, () => {
  const sim = new GameSimulation({ size: 25, levels: 3, mission, danger: 'calm', seed: `vertical-${mission}`, loadout: ['compass', 'chalk'] });
  if (mission === 'rescue') assert.equal(sim.rescue.level, 2);
  for (const objective of sim.objectives) {
    travelToFloor(sim, objective.level);
    walkTo(sim, objective);
    assert.ok(sim.interact());
    if (mission === 'repair') sim.step(4.1);
  }
  if (mission !== 'rescue') {
    assert.ok(sim.missionProgress.ready);
    walkTo(sim, { x: sim.maze.exit.x * CELL, z: sim.maze.exit.z * CELL });
    assert.equal(sim.status, 'playing', 'An upper floor exit must never finish the expedition');
  }
  assert.ok(sim.useTool(0));
  assert.equal(sim.compassTarget.type, 'ladder');
  assert.equal(sim.compassTarget.level, 1);
  assert.ok(sim.ladders.some((ladder) => ladder.toLevel === 2 && key(cellOf(ladder)) === key(sim.compassPath.at(-1))));
  travelToFloor(sim, 0);
  if (mission === 'rescue') {
    assert.equal(sim.rescue.level, 0);
    assert.equal(sim.rescue.y, 0);
  }
  walkTo(sim, { x: sim.exit.x * CELL, z: sim.exit.z * CELL });
  sim.step(1);
  assert.equal(sim.status, 'won');
  assert.equal(sim.missionProgress.ready, true);
  assert.equal(sim.result.levels, 3);
  assert.equal(sim.events.filter((event) => event.type === 'win').length, 1);
});

function stackedArena(loadout = ['laser', 'rocket']) {
  const sim = new GameSimulation({ size: 15, levels: 3, danger: 'normal', loadout, seed: 'isolation' });
  for (const level of sim.levels) level.maze.grid = level.maze.grid.map((row, z) => row.map((_, x) =>
    x === 0 || z === 0 || x === sim.maze.size - 1 || z === sim.maze.size - 1 ? 1 : 0));
  sim.rooms = [];
  sim.hazards = [];
  sim.treasures = [];
  sim._nextSpawn = Infinity;
  sim._nextWorldEvent = Infinity;
  sim._floors = reachableCells(sim.maze);
  sim.player.x = 7 * CELL;
  sim.player.z = 7 * CELL;
  return sim;
}

test('interactions, monsters, hazards and all weapons are isolated by floor and absolute height', () => {
  const sim = stackedArena();
  const remoteObjective = sim.objectives.find((objective) => objective.level === 1);
  Object.assign(remoteObjective, { x: sim.player.x, z: sim.player.z });
  const remoteMonster = { id: 777, type: 'listener', level: 1, y: 6,
    x: sim.player.x, z: sim.player.z - 5, health: 110, age: 0 };
  sim.monsters.push(remoteMonster);
  sim.hazards.push({ id: 'remote-trap', type: 'spikes', x: sim.player.x, z: sim.player.z,
    y: 6, level: 1, radius: 5, active: true, remaining: 10 });
  assert.equal(sim.nearbyRelic, -1);
  assert.equal(sim.collectRelic(), false);
  assert.equal(sim.interaction, null);
  assert.equal(sim.threat, 0);
  sim.useTool(0, 0);
  assert.equal(remoteMonster.health, 110);
  sim.useTool(1, 0);
  sim.step(1);
  assert.equal(remoteMonster.health, 110);
  assert.equal(remoteMonster.age, 0);
  assert.equal(sim.player.health, 100);
  // Reach upper floor through the same public ladder interaction; shots start
  // at its absolute eye height and local enemies can now be hit.
  travelToFloor(sim, 1);
  sim.player.x = remoteMonster.x;
  sim.player.z = remoteMonster.z + 5;
  sim.useTool(0, 0);
  assert.equal(remoteMonster.health, 72);
  const beam = sim.weaponEffects.at(-1);
  assert.equal(beam.level, 1);
  assert.ok(beam.y > 7 && beam.toY > 7);
  sim.step(0.3);
  sim.useTool(0, 0, -1.4);
  assert.ok(sim.weaponEffects.at(-1).toY >= 6.1);
});

test('climbing preserves cleared rooms, treasure, chalk and separate floor events; shifts protect every shaft', () => {
  const sim = new GameSimulation({ size: 51, levels: 3, danger: 'normal', seed: 'persistent-shafts', loadout: ['chalk', 'compass'] });
  sim._nextSpawn = Infinity;
  sim._nextWorldEvent = Infinity;
  const ground = sim.maze;
  const treasury = sim.treasures[0];
  treasury.collected = true;
  const library = sim.rooms.find((room) => room.type === 'library' && room.level === 0);
  library.solved = true;
  sim.useTool(0, 0);
  assert.ok(sim.queueWorldEvent('blackout'));
  sim.step(8.1);
  const event = sim.worldEvent;
  travelToFloor(sim, 1);
  assert.equal(sim.worldEvent, null);
  const upper = sim.maze;
  for (let count = 0; count < 6; count += 1) {
    sim._shiftWalls();
    for (const ladder of sim.ladders) {
      for (const index of [ladder.fromLevel, ladder.toLevel]) {
        const maze = sim.levels[index].maze;
        assert.ok(findPath(maze, maze.start, cellOf(ladder)).length);
      }
    }
    assert.equal(reachableCells(upper).length, upper.grid.flat().filter((cell) => cell === 0).length);
  }
  travelToFloor(sim, 0);
  assert.equal(sim.maze, ground);
  assert.equal(sim.worldEvent, event);
  assert.equal(library.solved, true);
  assert.equal(treasury.collected, true);
  assert.equal(sim.markers[0].level, 0);
  assert.equal(sim.markers[0].y, 0);
});

test('escort must be nearby to climb and then follows the same continuous ascent and descent', () => {
  const sim = new GameSimulation({ size: 15, levels: 3, danger: 'calm', mission: 'rescue', seed: 'escort-shaft' });
  travelToFloor(sim, 2);
  walkTo(sim, sim.rescue); sim.interact();
  const ladder = sim.ladders.find((entry) => entry.toLevel === 2);
  walkTo(sim, ladder); sim.step(1);
  const previous = { ...sim.rescue };
  sim.rescue.x = sim.player.x + 30;
  assert.equal(sim.interact(), false);
  assert.equal(sim.climbing, null);
  Object.assign(sim.rescue, previous);
  assert.ok(sim.interact());
  sim.step(1.5);
  assert.ok(sim.rescue.y > 8 && sim.rescue.y < 10);
  assert.equal(sim.rescue.level, 2);
  sim.step(1.5);
  assert.equal(sim.rescue.y, 6);
  assert.equal(sim.rescue.level, 1);
  assert.equal(sim.objectives[0].level, 1);
  assert.ok(walkable(sim.maze, ...Object.values(cellOf(sim.rescue))));
});

test('upper-floor machinegun fire and rocket explosions hit local enemies at absolute height only', () => {
  const sim = stackedArena(['machinegun', 'rocket']);
  travelToFloor(sim, 1);
  sim.player.x = 7 * CELL;
  sim.player.z = 7 * CELL;
  sim.step(2); // Let the landing protection end before checking blast damage.
  const enemies = [0, 1, 2].map((level) => ({ id: 800 + level, type: 'listener',
    level, y: level * LEVEL_HEIGHT, x: sim.player.x, z: sim.player.z - 3,
    health: 110, maxHealth: 110, age: 0 }));
  sim.monsters.push(...enemies);
  assert.ok(sim.useTool(0, 0));
  assert.equal(enemies[0].health, 110);
  assert.equal(enemies[1].health, 89);
  assert.equal(enemies[2].health, 110);
  assert.ok(sim.useTool(1, 0));
  assert.ok(sim.projectiles[0].y > 7);
  sim.step(0.2);
  assert.equal(enemies[1].health, 0);
  assert.equal(enemies[0].health, 110);
  assert.equal(enemies[2].health, 110);
  const explosion = sim.weaponEffects.find((effect) => effect.type === 'explosion');
  assert.ok(explosion.y > 7);
  assert.equal(explosion.level, 1);
  assert.ok(sim.player.health < 100);
});
