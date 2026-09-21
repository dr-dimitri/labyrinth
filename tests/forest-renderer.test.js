import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import { GameSimulation } from '../src/simulation.js';
import { getTerrainHeight, getTerrainCeiling, getCaveRoofTop } from '../src/forest-world.js';
import { ForestRenderer, createForestGround, createForestCrag, forestBankHeight, createForestCaveShell } from '../src/forest-renderer.js';

test('forest surface matches actor ground at every passable cell, including the deepest ravine', () => {
  for (const size of [9, 25, 51]) {
    const simulation = new GameSimulation({ biome: 'forest', size, seed: 'terrain-contract' });
    const geometry = createForestGround(simulation.maze, simulation.terrain), p = geometry.attributes.position;
    assert.ok(p.count <= 100_000, 'maximum woodland terrain stays inside its vertex budget');
    assert.ok(p.array.every(Number.isFinite));
    for (let z = 1; z < size - 1; z++) for (let x = 1; x < size - 1; x++) {
      if (simulation.maze.grid[z][x]) continue;
      const index = (z * 6 + 3) * (size * 6 + 1) + x * 6 + 3;
      assert.ok(Math.abs(p.getY(index) - getTerrainHeight(simulation.terrain, x * 3.6, z * 3.6)) < 1e-5);
      assert.equal(forestBankHeight(simulation.maze, x * 3.6, z * 3.6), 0);
    }
    geometry.dispose();
  }
});

test('forest rock photographs have valid two-dimensional UV coverage on every face', () => {
  const geometry = createForestCrag(), p = geometry.attributes.position, uv = geometry.attributes.uv;
  for (const attribute of Object.values(geometry.attributes)) assert.ok(attribute.array.every(Number.isFinite));
  for (let i = 0; i < p.count; i += 3) {
    const ux = uv.getX(i + 1) - uv.getX(i), uy = uv.getY(i + 1) - uv.getY(i);
    const vx = uv.getX(i + 2) - uv.getX(i), vy = uv.getY(i + 2) - uv.getY(i);
    assert.ok(Math.abs(ux * vy - uy * vx) > 1e-7, 'no stretched single-line projection on sloping faces');
  }
  geometry.dispose();
});

test('both forest caves have real ceilings and keep body clearance through every walkable cell', () => {
  const simulation = new GameSimulation({ biome: 'forest', size: 25, seed: 'cave-render-clearance' });
  const material = new THREE.MeshStandardMaterial({ side: THREE.DoubleSide }), root = new THREE.Group();
  const world = { world: root, iron: material, glowMap: new THREE.Texture(), assets: { trim: material, floor: material }, addTorch() {} };
  const forest = new ForestRenderer(world, simulation); root.updateMatrixWorld(true);
  const ray = new THREE.Raycaster(new THREE.Vector3(), new THREE.Vector3(0, 1, 0), 0, 12);
  for (const cave of simulation.terrain.caves) for (const cell of cave.cells) {
    const x = cell.x * 3.6, z = cell.z * 3.6, floor = getTerrainHeight(simulation.terrain, x, z);
    ray.ray.origin.set(x, floor + .3, z);
    const hit = ray.intersectObject(root, true).find(item => item.object.isMesh);
    assert.ok(hit, 'every cave cell has a physical ceiling');
    assert.ok(hit.distance > 2.1, `ceiling roots and rock teeth leave standing clearance at ${x},${z}`);
  }
  forest.dispose();
  const geometries = new Set(); root.traverse(object => { if (object.geometry) geometries.add(object.geometry); if (object.isInstancedMesh) object.dispose(); });
  geometries.forEach(geometry => geometry.dispose()); material.dispose(); world.glowMap.dispose();
});


test('cave vaults have curved cross sections and physical thickness matching weapon collision', () => {
  for (const size of [9, 25, 51]) {
    const simulation = new GameSimulation({ biome: 'forest', size, seed: 'volumetric-vault' });
    for (const cave of simulation.terrain.caves) {
      const shell = createForestCaveShell(simulation.terrain, cave);
      const material = new THREE.MeshBasicMaterial({ side: THREE.DoubleSide });
      const meshes = Object.values(shell).map(geometry => new THREE.Mesh(geometry, material));
      meshes.forEach(mesh => mesh.updateMatrixWorld());
      for (const geometry of Object.values(shell)) for (const attribute of Object.values(geometry.attributes)) {
        assert.ok(attribute.array.every(Number.isFinite));
      }
      const centerX = (cave.minX + cave.maxX) / 2, centerZ = (cave.minZ + cave.maxZ) / 2;
      const centerFloor = getTerrainHeight(simulation.terrain, centerX, centerZ);
      const centerHeight = getTerrainCeiling(simulation.terrain, centerX, centerZ) - centerFloor;
      const edgeHeight = getTerrainCeiling(simulation.terrain, centerX, cave.minZ) - getTerrainHeight(simulation.terrain, centerX, cave.minZ);
      assert.ok(centerHeight > edgeHeight + 1.4, 'a true arch provides changing overhead depth');
      for (const cell of cave.cells) {
        const x = cell.x * 3.6, z = cell.z * 3.6;
        const floor = getTerrainHeight(simulation.terrain, x, z);
        const origin = new THREE.Vector3(x, floor + 1.72, z), direction = new THREE.Vector3(0, 1, 0);
        const ray = new THREE.Raycaster(origin, direction, 0, 20);
        const hit = ray.intersectObjects(meshes)[0];
        const collision = simulation.getAimTarget(origin, direction, 20);
        assert.ok(Math.abs(hit.point.y - collision.y) < .015, 'rendered vault and shot collision meet at the same height');
        const top = getCaveRoofTop(simulation.terrain, cave, x, z);
        ray.ray.origin.y = top + 2; ray.ray.direction.y = -1;
        const upper = ray.intersectObjects(meshes)[0];
        assert.ok(Math.abs(upper.point.y - top) < .01);
        assert.ok(upper.point.y - hit.point.y > 2, 'the roof is a solid geological volume');
      }
      Object.values(shell).forEach(geometry => geometry.dispose()); material.dispose();
    }
  }
});


test('large forest batches share geometry but cull distant groves independently in view and shadow frusta', () => {
  const root = new THREE.Group(), geometry = new THREE.BoxGeometry(1, 2, 1);
  const material = new THREE.MeshStandardMaterial();
  const transforms = Array.from({ length: 160 }, (_, index) => ({
    x: index < 80 ? (index % 8) - 4 : 400 + index % 8,
    y: 1, z: -Math.floor(index % 80 / 8) - 3,
  }));
  const batches = ForestRenderer.prototype.batch.call({ root }, geometry, material, transforms, 'grove', { castShadow: false });
  root.updateMatrixWorld(true);
  assert.ok(batches.length > 1);
  assert.equal(batches.reduce((total, mesh) => total + mesh.count, 0), transforms.length);
  assert.equal(new Set(batches.map(mesh => mesh.geometry)).size, 1, 'GPU geometry is shared across every grove');
  assert.ok(batches.every(mesh => !mesh.castShadow && mesh.receiveShadow), 'foliage flags apply to every chunk');
  const camera = new THREE.PerspectiveCamera(65, 1, .1, 80);
  camera.position.set(0, 2, 3); camera.lookAt(0, 1, -10); camera.updateMatrixWorld();
  const frustum = new THREE.Frustum().setFromProjectionMatrix(new THREE.Matrix4().multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse));
  const visible = batches.filter(mesh => frustum.intersectsObject(mesh));
  assert.equal(visible.reduce((total, mesh) => total + mesh.count, 0), 80, 'off-screen instances do not enter the draw call');
  const shadowCamera = new THREE.OrthographicCamera(-15, 15, 15, -15, .1, 50);
  shadowCamera.position.set(0, 20, 3); shadowCamera.lookAt(0, 0, -10); shadowCamera.updateMatrixWorld();
  frustum.setFromProjectionMatrix(new THREE.Matrix4().multiplyMatrices(shadowCamera.projectionMatrix, shadowCamera.matrixWorldInverse));
  assert.equal(batches.filter(mesh => frustum.intersectsObject(mesh)).reduce((total, mesh) => total + mesh.count, 0), 80);
  let disposed = 0; geometry.addEventListener('dispose', () => disposed++);
  const geometries = new Set(); root.traverse(object => { if (object.geometry) geometries.add(object.geometry); if (object.isInstancedMesh) object.dispose(); });
  geometries.forEach(item => item.dispose());
  assert.equal(disposed, 1, 'shared geometry is released once by the existing world cleanup');
  material.dispose();
});
