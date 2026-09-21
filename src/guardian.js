import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { clone } from 'three/addons/utils/SkeletonUtils.js';

const assetBase = `${import.meta.env.BASE_URL}assets/models/creature/`;
const xAxis = new THREE.Vector3(1, 0, 0);
const zAxis = new THREE.Vector3(0, 0, 1);

/** One shared, locally bundled Pok sculpture and its original CC0 stone maps. */
export async function loadGuardianTemplate({ manager, maxAnisotropy = 8 } = {}) {
  const textures = new THREE.TextureLoader(manager);
  const texture = async (name, color = false, repeat = 1) => {
    const map = await textures.loadAsync(`${assetBase}${name}`);
    map.colorSpace = color ? THREE.SRGBColorSpace : THREE.NoColorSpace;
    map.wrapS = map.wrapT = THREE.RepeatWrapping;
    map.repeat.set(repeat, repeat);
    map.anisotropy = Math.min(8, maxAnisotropy);
    // The geometry was exported from FBX without altering its original UVs.
    map.flipY = true;
    return map;
  };
  const [gltf, carvedAo, carvedNormal, smoothColor, smoothNormal,
    smoothRoughness, smoothAo, roughColor, roughNormal, roughRoughness, roughAo] = await Promise.all([
    new GLTFLoader(manager).loadAsync(`${assetBase}stone-guardian.glb`),
    texture('carved-ao.png'), texture('carved-normal.png'),
    texture('smooth-color.jpg', true, 5), texture('smooth-normal.jpg', false, 5),
    texture('smooth-roughness.jpg', false, 5), texture('smooth-ao.jpg', false, 5),
    texture('rough-color.jpg', true, 4), texture('rough-normal.jpg', false, 4),
    texture('rough-roughness.jpg', false, 4), texture('rough-ao.jpg', false, 4),
  ]);
  const materials = {
    'carved stone': new THREE.MeshStandardMaterial({ name: 'Carved weathered stone',
      color: 0x989e9a, map: roughColor, normalMap: carvedNormal, aoMap: carvedAo,
      roughnessMap: roughRoughness, aoMapIntensity: .65,
      normalScale: new THREE.Vector2(.85, .85), roughness: .95 }),
    'smooth stone': new THREE.MeshStandardMaterial({ name: 'Natural rounded stone',
      color: 0xb4b6ad, map: smoothColor, normalMap: smoothNormal, roughnessMap: smoothRoughness,
      aoMap: smoothAo, aoMapIntensity: .55, roughness: .95 }),
    'poky stone': new THREE.MeshStandardMaterial({ name: 'Rough stone joints',
      color: 0xb0a69a, map: roughColor, normalMap: roughNormal, roughnessMap: roughRoughness,
      aoMap: roughAo, aoMapIntensity: .55, roughness: 1 }),
  };
  gltf.scene.traverse(object => {
    object.userData.persistentAsset = true;
    if (!object.isMesh) return;
    const replace = old => {
      const material = materials[old.name];
      if (!material) throw new Error(`Unknown guardian material: ${old.name}`);
      old.dispose();
      return material;
    };
    object.material = Array.isArray(object.material) ? object.material.map(replace) : replace(object.material);
    object.castShadow = true;
    object.receiveShadow = true;
    // Animated limbs can move outside the original T-pose bounds.
    object.frustumCulled = false;
  });
  return gltf.scene;
}

/** Independent skeleton, shared immutable geometry/maps. Position is in world metres. */
export class GuardianModel {
  constructor(template) {
    this.root = new THREE.Group();
    this.root.name = 'Stone guardian';
    this.group = this.root;
    this.model = clone(template);
    this.root.add(this.model);
    this.bones = new Map();
    this.model.updateMatrixWorld(true);
    this.model.traverse(object => {
      object.userData.persistentAsset = true;
      if (!object.isBone) return;
      // Convert a rotation in the model's upright axes into each bone's parent frame.
      const parentInverse = object.parent.getWorldQuaternion(new THREE.Quaternion()).invert();
      this.bones.set(object.name, { bone: object, rest: object.quaternion.clone(),
        x: xAxis.clone().applyQuaternion(parentInverse),
        z: zAxis.clone().applyQuaternion(parentInverse) });
    });
    this.phase = 0;
    this.motion = 0;
    this.disposed = false;
    this.rotation = new THREE.Quaternion();
    this.pose(0, 0);
    // Blender's character faces -Z; gameplay heading uses +Z.
    this.model.rotation.y = Math.PI;
    this.model.updateMatrixWorld(true);
    const bounds = new THREE.Box3().setFromObject(this.model);
    const size = bounds.getSize(new THREE.Vector3());
    const scale = Math.min(2.25 / size.y, 1.3 / size.x);
    this.model.scale.multiplyScalar(scale);
    this.model.position.addScaledVector(bounds.getCenter(new THREE.Vector3()), -scale);
    this.model.position.y += size.y * scale / 2;
    this.baseY = this.model.position.y;
    this.root.userData.persistentAsset = true;
  }

  rotate(name, axis, angle) {
    const joint = this.bones.get(name);
    if (joint) joint.bone.quaternion.premultiply(this.rotation.setFromAxisAngle(joint[axis], angle));
  }

  pose(phase, motion) {
    for (const { bone, rest } of this.bones.values()) bone.quaternion.copy(rest);
    const stride = Math.sin(phase) * motion;
    // Rest arms hang by the sides rather than preserving the imported T-pose.
    this.rotate('Left_arm', 'z', -1.3);
    this.rotate('Right_arm', 'z', 1.3);
    this.rotate('Left_arm', 'x', -.3 * stride);
    this.rotate('Right_arm', 'x', .3 * stride);
    this.rotate('Left_leg', 'x', .31 * stride);
    this.rotate('Right_leg', 'x', -.31 * stride);
    this.rotate('Left_knee', 'x', -.18 * Math.max(0, -stride));
    this.rotate('Right_knee', 'x', -.18 * Math.max(0, stride));
    this.rotate('Chest', 'z', .022 * stride);
    this.rotate('Head', 'x', -.06);
  }

  update(dt, entity, player) {
    if (this.disposed) return;
    const dx = this.lastX === undefined ? 0 : entity.x - this.lastX;
    const dz = this.lastZ === undefined ? 0 : entity.z - this.lastZ;
    const distance = Math.hypot(dx, dz);
    if (dt > 0) {
      this.motion = THREE.MathUtils.damp(this.motion, distance > .0001 ? 1 : 0, 9, dt);
      this.phase += distance * 4.4;
      this.pose(this.phase, this.motion);
      this.model.position.y = this.baseY + Math.abs(Math.sin(this.phase)) * .032 * this.motion;
    }
    this.root.position.set(entity.x, 0, entity.z);
    if (distance > .001) this.heading = Math.atan2(dx, dz);
    else if (this.heading === undefined && player) this.heading = Math.atan2(player.x - entity.x, player.z - entity.z);
    if (this.heading !== undefined) {
      const delta = Math.atan2(Math.sin(this.heading - this.root.rotation.y), Math.cos(this.heading - this.root.rotation.y));
      this.root.rotation.y += delta * (dt > 0 ? 1 - Math.exp(-dt * 9) : 0);
    }
    this.lastX = entity.x;
    this.lastZ = entity.z;
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    const skeletons = new Set();
    this.model.traverse(object => { if (object.isSkinnedMesh) skeletons.add(object.skeleton); });
    for (const skeleton of skeletons) skeleton.dispose();
    this.root.removeFromParent();
    this.root.clear();
  }
}
