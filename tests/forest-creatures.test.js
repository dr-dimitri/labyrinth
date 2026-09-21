import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import { ForestCreature, ForestElf } from '../src/forest-creatures.js';

function meshes(root) {
  const result = []; root.traverse(object => { if (object.isMesh) result.push(object); }); return result;
}

// Construct with no DOM or renderer so resource ownership is independent of a running game.
test('forest creatures have finite PBR surfaces and distinct life-sized silhouettes', () => {
  const wolf = new ForestCreature({}, 'wolf'), orc = new ForestCreature({}, 'orc'), elf = new ForestElf({ floorY: 0 });
  try {
    for (const model of [wolf, orc, elf]) {
      for (const mesh of meshes(model.root)) {
        assert.ok(mesh.material.isMeshStandardMaterial);
        for (const attribute of Object.values(mesh.geometry.attributes)) assert.ok(attribute.array.every(Number.isFinite));
      }
      const bounds = new THREE.Box3().setFromObject(model.root);
      assert.ok(bounds.min.y >= -.025 && bounds.min.y < .04, 'feet rest on terrain');
      assert.ok(meshes(model.root).length < 50, 'joint surfaces are batched for enemy waves');
    }
    const wolfSize = new THREE.Box3().setFromObject(wolf.root).getSize(new THREE.Vector3());
    const orcSize = new THREE.Box3().setFromObject(orc.root).getSize(new THREE.Vector3());
    const elfSize = new THREE.Box3().setFromObject(elf.root).getSize(new THREE.Vector3());
    assert.ok(wolfSize.z > wolfSize.y * 1.4 && wolfSize.z > wolfSize.x * 2.5, 'wolf is a long quadruped');
    assert.ok(orcSize.y > 2 && orcSize.y < 2.35);
    assert.ok(elfSize.y > 1.7 && elfSize.y < 1.95);
    assert.ok(elfSize.y < orcSize.y);
  } finally { wolf.dispose(); orc.dispose(); elf.dispose(); }
});

test('wolves expose glowing red eyes and long upper/lower canines on articulated jaws', () => {
  const wolf = new ForestCreature({}, 'wolf');
  try {
    const eyes = meshes(wolf.root).filter(mesh => mesh.name.includes('red eye'));
    assert.equal(eyes.length, 2);
    assert.ok(eyes.every(eye => eye.material.emissive.r > eye.material.emissive.g * 5 && eye.material.emissiveIntensity >= 1));
    const canines = meshes(wolf.root).filter(mesh => mesh.name.includes('canine'));
    assert.equal(canines.length, 4);
    assert.ok(canines.every(tooth => tooth.geometry.parameters.height >= .07));
    assert.equal(canines.filter(tooth => tooth.parent === wolf.jaw).length, 2);
    assert.equal(wolf.legs.length, 4);
    const limb = wolf.legs[0].hip;
    wolf.update(.016, { x: 1, z: 1 }, { x: 0, z: 2 });
    for (let i = 0; i < 10; i++) wolf.update(.05, { x: 1, z: 1 + i * .08 }, { x: 0, z: 2 });
    assert.ok(Math.abs(limb.rotation.x) > .02);
    assert.ok(wolf.legs.some(leg => Math.abs(leg.knee.rotation.x) > .05));
  } finally { wolf.dispose(); }
});

test('enemy updates leave terrain offset to renderer without accumulating vertical drift', () => {
  for (const type of ['wolf', 'orc']) {
    const model = new ForestCreature({ floorY: 6 }, type);
    try {
      for (let i = 0; i < 100; i++) {
        model.update(.016, { x: 3 + i * .02, y: -5, z: 8 }, { x: 4, y: -5, z: 9 });
        model.root.position.y += -5 - 6;
        assert.equal(model.root.position.y, -11);
      }
      assert.ok(Math.abs(model.root.rotation.y - Math.PI / 2) < .05, 'moving enemy faces its movement');
      const phase = model.phase;
      model.update(0, { x: 4.98, y: -5, z: 8 }, { x: 4, z: 9 });
      assert.equal(model.phase, phase, 'pause freezes walking phase');
    } finally { model.dispose(); }
  }
});

test('friendly elf hands out visible ammunition only when the cooldown is ready', () => {
  const world = { floorY: 0 }, elf = new ForestElf(world);
  try {
    const entity = { x: 10, y: -7, z: 12, cooldown: 0 };
    for (let i = 0; i < 30; i++) elf.update(.05, entity, { x: 10, z: 14 });
    assert.equal(elf.root.position.y, -7);
    assert.equal(elf.gift.visible, true);
    assert.ok(elf.arms[1].rotation.x < -.8);
    assert.equal(elf.halo.visible, true);
    elf.update(.1, { ...entity, cooldown: 45 }, { x: 10, z: 14 });
    assert.equal(elf.gift.visible, false);
    assert.ok(elf.glow.emissiveIntensity < .3);
    elf.update(.1, entity, { x: 40, z: 40 });
    assert.equal(elf.gift.visible, true);
    assert.equal(elf.halo.visible, false);
  } finally { elf.dispose(); }
});

test('shared material maps live until their last creature is disposed', () => {
  const first = new ForestCreature({}, 'wolf'), second = new ForestCreature({}, 'wolf');
  const map = first.fur.map;
  assert.equal(map, second.fur.map);
  let mapDisposals = 0, geometryDisposals = 0;
  map.addEventListener('dispose', () => mapDisposals++);
  for (const geometry of first.geometries) geometry.addEventListener('dispose', () => geometryDisposals++);
  const expectedGeometry = first.geometries.size;
  first.dispose(); first.dispose();
  assert.equal(mapDisposals, 0);
  assert.equal(geometryDisposals, expectedGeometry);
  second.update(.1, { x: 1, z: 2 }, { x: 1, z: 4 });
  assert.ok(second.root.children.length > 0);
  second.dispose();
  assert.equal(mapDisposals, 1);
});
