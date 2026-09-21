import test from 'node:test';
import assert from 'node:assert/strict';
import { BoxGeometry, DoubleSide, Mesh, MeshBasicMaterial, PlaneGeometry, Raycaster, Vector3 } from 'three';
import { applyMetricUvs, createArchGeometry } from '../src/architecture.js';
import { CELL } from '../src/simulation.js';

test('corridor arch leaves the full walkable width clear at body height', () => {
  const geometry = createArchGeometry();
  const material = new MeshBasicMaterial({ side: DoubleSide });
  const mesh = new Mesh(geometry, material);
  mesh.updateMatrixWorld(true);
  const ray = new Raycaster(new Vector3(), new Vector3(0, 0, 1), 0, 2);
  // Include the edges of the complete floor cell: the player's body can reach
  // those edges even though its centre stops one player radius earlier.
  for (const x of [-CELL / 2, -CELL / 4, 0, CELL / 4, CELL / 2]) {
    for (const y of [0.08, 0.5, 1.72, 1.9]) {
      ray.ray.origin.set(x, y, -1);
      assert.equal(ray.intersectObject(mesh).length, 0, `blocked at x=${x}, y=${y}`);
    }
  }
  ray.ray.origin.set(2.06, 0.09, -1);
  assert.ok(ray.intersectObject(mesh).length > 0, 'column base has real closed geometry');
  ray.ray.origin.set(0, 4.23, -1);
  assert.ok(ray.intersectObject(mesh).length > 0, 'crown has real closed geometry');
  geometry.dispose(); material.dispose();
});

test('corridor and monumental arches keep finite normals and bounded geometry', () => {
  for (const options of [{}, { radius: 5.1, pillar: 2.5, depth: 1.05, thickness: 0.48 }]) {
    const geometry = createArchGeometry(options);
    const position = geometry.getAttribute('position');
    const normal = geometry.getAttribute('normal');
    assert.ok(position.count / 3 < 10000, 'arch stays below the triangle budget');
    assert.equal(geometry.groups.length, 0, 'arch supports one material and draw call');
    for (const attribute of Object.values(geometry.attributes)) {
      assert.equal(attribute.count, position.count);
      assert.ok(attribute.array.every(Number.isFinite));
    }
    for (let vertex = 0; vertex < normal.count; vertex += 1) {
      const length = Math.hypot(normal.getX(vertex), normal.getY(vertex), normal.getZ(vertex));
      assert.ok(Math.abs(length - 1) < 1e-5, 'bevel normal is normalized');
    }
    assert.ok(Math.abs(geometry.boundingBox.min.y) < 1e-6, 'base rests on the floor');
    const maxHeight = (options.pillar ?? 2.15) + (options.radius ?? 2.06)
      + (options.thickness ?? 0.28) / 2 + 0.03;
    assert.ok(geometry.boundingBox.max.y < maxHeight);
    geometry.dispose();
  }
});

test('metric UVs preserve physical coverage and OpenGL normal-map handedness', () => {
  const floor = new PlaneGeometry(CELL, CELL, 12, 12);
  floor.rotateX(-Math.PI / 2);
  applyMetricUvs(floor, 1.8);
  const floorUV = floor.getAttribute('uv');
  const us = Array.from({ length: floorUV.count }, (_, i) => floorUV.getX(i));
  const vs = Array.from({ length: floorUV.count }, (_, i) => floorUV.getY(i));
  assert.ok(Math.abs(Math.max(...us) - Math.min(...us) - 2) < 1e-6);
  assert.ok(Math.abs(Math.max(...vs) - Math.min(...vs) - 2) < 1e-6);
  const box = applyMetricUvs(new BoxGeometry(3.5, 3.5, 3.5));
  for (const geometry of [floor, box]) {
    const uv = geometry.getAttribute('uv');
    for (let first = 0; first < uv.count; first += 3) {
      const du1 = uv.getX(first + 1) - uv.getX(first);
      const dv1 = uv.getY(first + 1) - uv.getY(first);
      const du2 = uv.getX(first + 2) - uv.getX(first);
      const dv2 = uv.getY(first + 2) - uv.getY(first);
      assert.ok(du1 * dv2 - dv1 * du2 > 0, 'UV basis must follow the outward normal');
    }
    geometry.dispose();
  }
});
