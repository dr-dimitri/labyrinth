import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import { ExpeditionVisuals } from '../src/expedition-visuals.js';
import { cameraAimRay, poseWeaponToward, readMuzzleShot } from '../src/weapon-aim.js';

const vector = point => new THREE.Vector3(point.x, point.y, point.z);

function fixture(ids = ['machinegun', 'rocket']) {
  const visuals = Object.create(ExpeditionVisuals.prototype);
  const camera = new THREE.PerspectiveCamera(77, 2.1, .08, 150);
  camera.position.set(20, 13.72, 25); camera.rotation.set(.12, -.8, 0, 'YXZ');
  camera.updateMatrixWorld(true);
  Object.assign(visuals, {
    root: new THREE.Group(), level: 2, geometries: new Set(), materials: new Set(), weapons: [],
    world: { camera, assets: { environment: null }, glowMap: new THREE.Texture(), composer: { insertPass() {} },
      mesh(geometry, material, x, y, z, parent) {
        const mesh = new THREE.Mesh(geometry, material); mesh.position.set(x, y, z); parent.add(mesh); return mesh;
      } },
  });
  for (const name of ['metal', 'brass', 'wood', 'cyan', 'amber']) visuals[name] = visuals.material({ color: 0x777777 });
  visuals.addWeapons(ids.map(id => ({ id })));
  visuals.weaponRoot.position.copy(camera.position); visuals.weaponRoot.quaternion.copy(camera.quaternion);
  visuals.weaponRoot.updateMatrixWorld(true);
  return { visuals, camera, dispose() {
    visuals.geometries.forEach(geometry => geometry.dispose());
    visuals.materials.forEach(material => material.dispose());
    visuals.world.glowMap.dispose(); visuals.weaponPass.dispose();
  } };
}

test('mouse aim ray projects to the cursor under sprint FOV, camera bob, pitch and wide aspect', () => {
  const camera = new THREE.PerspectiveCamera(77, 2.1, .08, 150);
  camera.position.set(8, 7.754, 12); camera.rotation.set(.32, -1.2, 0, 'YXZ');
  const rotation = camera.quaternion.clone();
  for (const [x, y] of [[0, 0], [-.9, .9], [.87, -.71]]) {
    const { origin, direction } = cameraAimRay(camera, x, y);
    const projected = origin.clone().addScaledVector(direction, 20).project(camera);
    assert.ok(Math.abs(projected.x - x) < 1e-10);
    assert.ok(Math.abs(projected.y - y) < 1e-10);
    assert.equal(origin.y, 7.754);
    assert.ok(Math.abs(direction.length() - 1) < 1e-10);
    assert.ok(camera.quaternion.equals(rotation), 'aim must never rotate the view');
  }
});

test('all three weapon muzzle markers sit on the actual front surface after mesh batching', () => {
  for (const id of ['machinegun', 'laser', 'rocket']) {
    const { visuals, dispose } = fixture([id, id]);
    for (const weapon of visuals.weapons) {
      let front = Infinity;
      weapon.group.traverse(mesh => {
        if (!mesh.isMesh) return;
        const positions = mesh.geometry.getAttribute('position');
        for (let i = 0; i < positions.count; i++) front = Math.min(front, positions.getZ(i));
      });
      assert.ok(Math.abs(front - weapon.muzzle.position.z) < 1e-6, `${id}: marker must match the barrel end`);
      assert.equal(weapon.flash.parent, weapon.muzzle);
      assert.equal(weapon.flash.position.length(), 0);
    }
    dispose();
  }
});

test('actual left and right barrels converge on the cursor even beside close cover and upstairs', () => {
  for (const id of ['machinegun', 'laser', 'rocket']) {
    const { visuals, camera, dispose } = fixture([id, id]);
    for (const distance of [.36, .8, 2, 30]) for (const [x, y] of [[0, 0], [-.9, -.9], [.9, .9], [.7, -.4]]) {
      const ray = cameraAimRay(camera, x, y);
      const target = ray.origin.clone().addScaledVector(ray.direction, distance);
      for (const weapon of visuals.weapons) {
        poseWeaponToward(weapon, target, { aimX: x, aimY: y, bob: .017, recoil: .025 });
        const shot = readMuzzleShot(weapon);
        const origin = vector(shot.origin), direction = vector(shot.direction);
        assert.ok(origin.distanceTo(weapon.muzzle.getWorldPosition(new THREE.Vector3())) < 1e-9);
        assert.ok(direction.dot(target.clone().sub(origin).normalize()) > .999999999,
          `${id}, slot ${weapon.slot}, cursor ${x}/${y}, distance ${distance}: actual barrel misses cursor target`);
        assert.ok(origin.distanceTo(camera.position) < 2.5, 'physical muzzle remains in player reach');
      }
    }
    dispose();
  }
});

test('prepared weapon shot retains its exact camera pose and slot-specific flash state', () => {
  const { visuals, camera, dispose } = fixture(['laser', 'laser']);
  const simulation = {
    player: { x: 20, y: 12, z: 25 }, elapsed: 3, inventory: [{ reloadRemaining: .1 }, {}],
    weaponEffects: [{ type: 'laser', level: 2, slot: 1, age: .01 }], projectiles: [],
  };
  const view = { aimX: .65, aimY: -.45, yaw: -.8, pitch: .12, sprinting: true, moving: true };
  const ray = cameraAimRay(camera, view.aimX, view.aimY);
  const target = ray.origin.clone().addScaledVector(ray.direction, 5);
  visuals.prepareWeapons(.016, simulation, view, target);
  const pose = camera.matrixWorld.clone();
  const right = visuals.getWeaponShot(1);
  assert.ok(camera.matrixWorld.equals(pose));
  assert.deepEqual(visuals.getWeaponShot(1), right);
  assert.equal(visuals.recentWeaponEffect(visuals.weapons[0], simulation), undefined);
  assert.ok(visuals.recentWeaponEffect(visuals.weapons[1], simulation));
  assert.ok(visuals.weapons[0].reload > 0);
  simulation.inventory[0].reloadRemaining = 0;
  visuals.prepareWeapons(0, simulation, view, target);
  assert.equal(visuals.weapons[0].reload, 0, 'first shot after reload has no residual barrel tilt');
  const left = visuals.getWeaponShot(0);
  assert.ok(vector(left.direction).dot(target.clone().sub(vector(left.origin)).normalize()) > .999999999);
  dispose();
});
