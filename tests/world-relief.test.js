import test from 'node:test';
import assert from 'node:assert/strict';
import { Box3, DoubleSide, Group, Matrix4, Mesh, MeshStandardMaterial, Raycaster, Texture, Vector3 } from 'three';
import { createReliefBlockGeometry } from '../src/architecture.js';
import { WorldRelief, createWallReliefGeometry, createPavingReliefGeometry, createOverheadRibGeometry } from '../src/world-relief.js';
import { generateExpedition } from '../src/expedition.js';
import { walkable } from '../src/maze.js';
import { meshIntersectsOpening } from '../src/vertical-architecture.js';

const CELL = 3.6;
function fixture(biome, size, level = 0) {
  const expedition = generateExpedition({ biome, size, levels: 3, seed: 'physical-depth-qa' });
  const material = new MeshStandardMaterial({ map: new Texture(), displacementScale: .055 });
  const world = { world: new Group(), biomeId: biome, levelIndex: level, stone: material, trim: material,
    assets: { floor: material, forest: { rock: material, bark: material } } };
  const simulation = { ...expedition, player: { level }, config: { biome } };
  const maze = expedition.levels[level].maze;
  const relief = new WorldRelief(world, maze, simulation, { wallHeight: biome === 'ruins' ? 3.4 : 4.5 });
  return { relief, world, maze, simulation, material };
}

function dispose({ relief, material }) {
  const geometries = new Set();
  relief.root.traverse(object => {
    if (object.geometry) geometries.add(object.geometry);
    if (object.isInstancedMesh) object.dispose();
  });
  geometries.forEach(geometry => geometry.dispose());
  relief.dispose(); material.map.dispose(); material.dispose();
}

test('front-bevel blocks are finite closed surfaces with a bounded twenty-triangle budget', () => {
  const geometry = createReliefBlockGeometry(1.2, .62, .17, .013);
  assert.equal(geometry.attributes.position.count / 3, 20);
  geometry.computeBoundingBox();
  assert.equal(geometry.boundingBox.max.z, 0);
  assert.ok(Math.abs(geometry.boundingBox.min.z + .17) < 1e-6);
  const edges = new Map(), positions = geometry.attributes.position;
  const point = index => [positions.getX(index), positions.getY(index), positions.getZ(index)].map(v => v.toFixed(6)).join(',');
  for (let first = 0; first < positions.count; first += 3) {
    for (let edge = 0; edge < 3; edge++) {
      const key = [point(first + edge), point(first + (edge + 1) % 3)].sort().join('|');
      edges.set(key, (edges.get(key) || 0) + 1);
    }
  }
  assert.ok([...edges.values()].every(count => count === 2), 'every edge belongs to two triangles');
  for (const attribute of Object.values(geometry.attributes)) assert.ok(attribute.array.every(Number.isFinite));
  geometry.dispose();
});

test('wall relief is actually recessed and paving cannot hide floor markers', () => {
  for (const options of [{}, { mine: true }, { ruins: true, height: 3.4 }]) {
    const geometry = createWallReliefGeometry(options), bounds = geometry.boundingBox;
    assert.ok(bounds.max.z <= 0, 'stone never enters a walkable cell');
    assert.ok(bounds.min.z < -.15, 'stone connects to the inset structural core');
    assert.ok(bounds.min.x >= -CELL / 2 && bounds.max.x <= CELL / 2);
    assert.ok(bounds.max.z - bounds.min.z >= .16, 'relief has physical depth');
    for (const attribute of Object.values(geometry.attributes)) assert.ok(attribute.array.every(Number.isFinite));
    geometry.dispose();
  }
  const paving = createPavingReliefGeometry();
  assert.ok(paving.boundingBox.max.y < .03, 'chalk, trap warnings and treasures remain above the paving');
  assert.ok(paving.boundingBox.min.y < 0, 'pavers embed into the underlying floor');
  paving.dispose();
});

test('vault ribs and timber braces leave the entire corridor width clear below 2.5 metres', () => {
  const opening = new Box3(new Vector3(-CELL / 2, .03, -.6), new Vector3(CELL / 2, 2.5, .6));
  for (const mine of [false, true]) {
    const geometry = createOverheadRibGeometry({ mine }), material = new MeshStandardMaterial();
    const mesh = new Mesh(geometry, material); mesh.updateMatrixWorld(true);
    assert.equal(meshIntersectsOpening(mesh, opening), false);
    assert.ok(geometry.boundingBox.max.y < 4.5, 'ribs fit below the existing ceiling');
    geometry.dispose(); material.dispose();
  }
});

test('continuous wall caps close floor and ceiling seams above the recessed core', () => {
  for (const mine of [false, true]) {
    const geometry = createWallReliefGeometry({ height: 4.5, mine });
    const material = new MeshStandardMaterial({ side: DoubleSide });
    const mesh = new Mesh(geometry, material); mesh.updateMatrixWorld(true);
    const ray = new Raycaster(new Vector3(), new Vector3(0, 0, -1), 0, .1);
    for (const x of [-1.799, -1.2, -.9, 0, .9, 1.2, 1.799]) {
      for (const y of [-.025, 0, .025, 4.47, 4.499]) {
        ray.ray.origin.set(x, y, .05);
        assert.ok(ray.intersectObject(mesh).length > 0, `open seam at ${x},${y} (mine=${mine})`);
      }
    }
    geometry.dispose(); material.dispose();
  }
});

test('added architecture preserves every walkable cell and all ladder shafts on all dungeon levels', () => {
  const instanceMatrix = new Matrix4();
  for (const biome of ['catacombs', 'ruins', 'mine']) for (const level of [0, 1, 2]) {
    const item = fixture(biome, 15, level), { relief, maze, simulation } = item;
    const shafts = simulation.ladders.filter(ladder => ladder.fromLevel === level || ladder.toLevel === level)
      .map(ladder => new Box3(new Vector3(ladder.x - 1.1, -.1, ladder.z - 1.1),
        new Vector3(ladder.x + 1.1, 6.2, ladder.z + 1.1)));
    for (const batch of relief.batches) {
      const mesh = new Mesh(batch.geometry, batch.material); mesh.matrixAutoUpdate = false;
      for (let index = 0; index < batch.count; index++) {
        batch.getMatrixAt(index, instanceMatrix); mesh.matrixWorld.copy(instanceMatrix);
        const bounds = batch.geometry.boundingBox.clone().applyMatrix4(instanceMatrix);
        const minX = Math.max(0, Math.floor(bounds.min.x / CELL));
        const maxX = Math.min(maze.size - 1, Math.ceil(bounds.max.x / CELL));
        const minZ = Math.max(0, Math.floor(bounds.min.z / CELL));
        const maxZ = Math.min(maze.size - 1, Math.ceil(bounds.max.z / CELL));
        for (let z = minZ; z <= maxZ; z++) for (let x = minX; x <= maxX; x++) {
          if (!walkable(maze, x, z)) continue;
          const corridor = new Box3(new Vector3(x * CELL - CELL / 2 + .0001, .035, z * CELL - CELL / 2 + .0001),
            new Vector3(x * CELL + CELL / 2 - .0001, 2.5, z * CELL + CELL / 2 - .0001));
          assert.equal(meshIntersectsOpening(mesh, corridor), false,
            `${biome} level ${level}: ${batch.name} blocks corridor ${x},${z}`);
        }
        for (const shaft of shafts) assert.equal(meshIntersectsOpening(mesh, shaft), false,
          `${biome} level ${level}: ${batch.name} blocks a ladder opening`);
      }
    }
    dispose(item);
  }
});

test('largest dungeons use spatially bounded instance batches and share photographed source maps', () => {
  for (const biome of ['catacombs', 'ruins', 'mine']) {
    const item = fixture(biome, 51), { relief, material } = item;
    const triangles = relief.batches.reduce((sum, batch) => sum + batch.count * batch.geometry.attributes.position.count / 3, 0);
    assert.ok(relief.batches.length < 160, `${biome}: ${relief.batches.length} batches`);
    assert.ok(triangles < 2_300_000, `${biome}: ${triangles} triangles`);
    const uniqueGeometries = new Set(relief.batches.map(batch => batch.geometry));
    assert.ok(uniqueGeometries.size <= 7, 'geometry buffers are reused across chunks');
    for (const batch of relief.batches) {
      assert.ok(batch.boundingBox && batch.boundingSphere && batch.frustumCulled);
      const dimensions = batch.boundingBox.getSize(new Vector3());
      assert.ok(dimensions.x < CELL * 10 && dimensions.z < CELL * 10, 'no full-world culling bound');
      assert.equal(batch.material.map, material.map, 'no large photographic texture duplication');
      assert.equal(batch.material.displacementScale, 0, 'low-poly relief does not reuse dense-floor displacement');
    }
    let textureDisposals = 0;
    material.map.addEventListener('dispose', () => { textureDisposals++; });
    relief.dispose();
    assert.equal(textureDisposals, 0, 'clearing relief preserves the shared source assets');
    dispose(item);
  }
});
