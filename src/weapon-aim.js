import * as THREE from 'three';

const forward = new THREE.Vector3(0, 0, -1);

/** Use the rendered camera projection, including sprint FOV and aspect ratio. */
export function cameraAimRay(camera, aimX = 0, aimY = 0) {
  camera.updateMatrixWorld(true);
  const origin = camera.getWorldPosition(new THREE.Vector3());
  const direction = new THREE.Vector3(
    THREE.MathUtils.clamp(aimX, -.9, .9),
    THREE.MathUtils.clamp(aimY, -.9, .9), .5,
  ).unproject(camera).sub(origin).normalize();
  return { origin, direction };
}

/** Align the actual barrel axis with the cursor hit, compensating for its offset. */
export function poseWeaponToward(weapon, target, { aimX = 0, aimY = 0, bob = 0, recoil = 0, reload = 0 } = {}) {
  const { group, muzzle, slot } = weapon;
  const localTarget = group.parent.worldToLocal(target.clone());
  const near = 1 - THREE.MathUtils.clamp((localTarget.length() - .65) / .85, 0, 1);
  const pivot = new THREE.Vector3((slot ? .26 : -.26) + aimX * .12,
    -.31 + aimY * .1 + bob - near * .2 - reload * .18, -.74 + near * .58 + recoil);
  // Lower the hands beside very close cover so the muzzle remains behind the
  // point of convergence, instead of pointing out through that surface.
  const barrelLength = -muzzle.position.z * group.scale.z;
  if (pivot.distanceTo(localTarget) < barrelLength + .06) {
    pivot.y = localTarget.y - Math.sqrt(Math.max(0, (barrelLength + .06) ** 2
      - (pivot.x - localTarget.x) ** 2 - (pivot.z - localTarget.z) ** 2));
  }
  const direction = localTarget.clone().sub(pivot).normalize();
  group.quaternion.setFromUnitVectors(forward, direction);
  if (reload) group.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), -.5 * reload));
  // The barrel is not centred vertically on every weapon's receiver.
  group.position.copy(pivot).sub(new THREE.Vector3(muzzle.position.x * group.scale.x,
    muzzle.position.y * group.scale.y, 0).applyQuaternion(group.quaternion));
  group.updateWorldMatrix(true, true);
}

export function readMuzzleShot(weapon) {
  const origin = weapon.muzzle.getWorldPosition(new THREE.Vector3());
  const direction = forward.clone().applyQuaternion(weapon.muzzle.getWorldQuaternion(new THREE.Quaternion())).normalize();
  return { origin: { x: origin.x, y: origin.y, z: origin.z }, direction: { x: direction.x, y: direction.y, z: direction.z } };
}
