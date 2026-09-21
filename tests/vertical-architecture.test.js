import test from 'node:test';
import assert from 'node:assert/strict';
import { Box3, BoxGeometry, DoubleSide, Mesh, MeshBasicMaterial, Raycaster, TorusGeometry, Vector3 } from 'three';
import { createLandingTile, meshIntersectsOpening } from '../src/vertical-architecture.js';

test('ladder landings and ceilings leave a real shaft open but retain surrounding floor', () => {
  for (const ceiling of [false, true]) {
    const geometry = createLandingTile({ ceiling });
    const material = new MeshBasicMaterial({ side: DoubleSide });
    const mesh = new Mesh(geometry, material); mesh.updateMatrixWorld(true);
    const ray = new Raycaster(new Vector3(0, 2, 0), new Vector3(0, -1, 0), 0, 4);
    for (const x of [-.95, 0, .95]) for (const z of [-.95, 0, .95]) {
      ray.ray.origin.set(x, 2, z);
      assert.equal(ray.intersectObject(mesh).length, 0, `shaft blocked at ${x},${z}`);
    }
    for (const [x, z] of [[-1.5, 0], [1.5, 0], [0, -1.5], [0, 1.5], [1.5, 1.5]]) {
      ray.ray.origin.set(x, 2, z);
      assert.ok(ray.intersectObject(mesh).length > 0, `missing landing at ${x},${z}`);
    }
    for (const attribute of Object.values(geometry.attributes)) assert.ok(attribute.array.every(Number.isFinite));
    const normals = geometry.getAttribute('normal');
    assert.ok(normals.getY(0) * (ceiling ? -1 : 1) > .999);
    geometry.dispose(); material.dispose();
  }
});


test('shaft decoration checks actual surfaces, preserving clear space inside curved props', () => {
  const opening = new Box3(new Vector3(-.5, -.5, -.5), new Vector3(.5, .5, .5));
  const ring = new Mesh(new TorusGeometry(2, .05, 4, 24)); ring.updateMatrixWorld(true);
  assert.equal(meshIntersectsOpening(ring, opening), false);
  const shelf = new Mesh(new BoxGeometry(.4, 2, 1)); shelf.position.x = .55; shelf.updateMatrixWorld(true);
  assert.equal(meshIntersectsOpening(shelf, opening), true);
  shelf.position.x = 2; shelf.updateMatrixWorld(true);
  assert.equal(meshIntersectsOpening(shelf, opening), false);
  ring.geometry.dispose(); ring.material.dispose(); shelf.geometry.dispose(); shelf.material.dispose();
});
