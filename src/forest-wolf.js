import * as THREE from 'three';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { clone } from 'three/addons/utils/SkeletonUtils.js';

const X = new THREE.Vector3(1, 0, 0), Y = new THREE.Vector3(0, 1, 0);
const assetBase = `${import.meta.env?.BASE_URL || '/'}assets/models/forest-wolf/`;

/** NewDLC's original CC0 textured/rigged wolf. Loaded once with the photographic assets. */
export async function loadForestWolfTemplate({ manager, maxAnisotropy = 8 } = {}) {
  const textures = new THREE.TextureLoader(manager);
  const loadMap = async (name, color = false) => {
    const map = await textures.loadAsync(`${assetBase}${name}`);
    map.colorSpace = color ? THREE.SRGBColorSpace : THREE.NoColorSpace;
    map.anisotropy = Math.min(8, maxAnisotropy); return map;
  };
  const [model, map, normalMap, roughnessMap] = await Promise.all([
    new FBXLoader(manager).loadAsync(`${assetBase}dog2.FBX`),
    loadMap('dog2Color.png', true), loadMap('dog2Normal.png'), loadMap('dog2Roughness.png'),
  ]);
  const material = new THREE.MeshStandardMaterial({ name: 'NewDLC wolf · original fur textures',
    map, normalMap, roughnessMap, normalScale: new THREE.Vector2(.75, .75),
    color: 0xbcc1b8, roughness: 1, metalness: 0 });
  material.onBeforeCompile = shader => {
    shader.fragmentShader = shader.fragmentShader.replace('#include <map_fragment>', '#include <map_fragment>\nfloat furGray = dot(diffuseColor.rgb, vec3(0.2126,0.7152,0.0722)); diffuseColor.rgb = mix(vec3(furGray), diffuseColor.rgb, 0.22);');
  };
  model.traverse(object => {
    object.userData.persistentAsset = true;
    if (!object.isMesh) return;
    const oldMaterials = Array.isArray(object.material) ? object.material : [object.material];
    oldMaterials.forEach(old => { for (const value of Object.values(old)) if (value?.isTexture) value.dispose(); old.dispose(); }); object.material = material;
    object.castShadow = true; object.receiveShadow = true; object.frustumCulled = false;
  });
  return model;
}

/** Independent bone pose, shared original mesh/maps. Heading is +Z, feet local y=0. */
export class ForestWolfModel {
  constructor(template) {
    this.type = 'wolf'; this.root = new THREE.Group(); this.root.name = 'Rotaugenwolf · NewDLC';
    this.model = clone(template); this.root.add(this.model);
    this.bones = new Map(); this.geometries = new Set(); this.materials = new Set();
    this.model.updateMatrixWorld(true);
    this.model.traverse(object => {
      if (!object.isBone) return;
      const inverse = object.parent.getWorldQuaternion(new THREE.Quaternion()).invert();
      this.bones.set(object.name, { bone: object, rest: object.quaternion.clone(),
        x: X.clone().applyQuaternion(inverse), y: Y.clone().applyQuaternion(inverse) });
    });
    this.phase = 0; this.motion = 0; this.time = 0; this.rotation = new THREE.Quaternion();
    this.eyeMaterial = new THREE.MeshStandardMaterial({ color: 0x280000, emissive: 0xff0900,
      emissiveIntensity: 1.25, roughness: .28, toneMapped: false });
    this.toothMaterial = new THREE.MeshStandardMaterial({ color: 0xdbd1b4, roughness: .43 });
    this.materials.add(this.eyeMaterial); this.materials.add(this.toothMaterial);
    for (const side of ['Left', 'Right']) {
      const bone = this.bones.get(`b_${side}Eye`)?.bone;
      if (bone) {
        const geometry = new THREE.SphereGeometry(1.28, 12, 8); this.geometries.add(geometry);
        const eye = new THREE.Mesh(geometry, this.eyeMaterial); eye.name = `Wolf ${side} red eye`;
        const centre = bone.getWorldPosition(new THREE.Vector3());
        const outward = new THREE.Vector3(0, 0, 1);
        const ray = new THREE.Raycaster(centre.clone().addScaledVector(outward, 20), outward.clone().negate(), 0, 30);
        const surface = ray.intersectObject(this.model.getObjectByName('dog2'), false)[0];
        const point = surface ? surface.point.clone().addScaledVector(outward, .2) : centre.addScaledVector(outward, 3);
        eye.position.copy(bone.worldToLocal(point)); bone.add(eye);
      }
    }
    this.model.updateMatrixWorld(true);
    for (const side of [-1, 1]) for (const upper of [true]) {
      const bone = this.bones.get(upper ? 'b_Head' : 'b_Jaw')?.bone; if (!bone) continue;
      const geometry = new THREE.ConeGeometry(.91, upper ? 7.5 : 3.8, 12, 3); this.geometries.add(geometry);
      const tooth = new THREE.Mesh(geometry, this.toothMaterial); tooth.name = `Wolf ${upper ? 'upper' : 'lower'} long canine ${side}`;
      const point = new THREE.Vector3(side * 6.0, upper ? 90.9 : 90.7, 65.6);
      tooth.position.copy(bone.worldToLocal(point));
      tooth.quaternion.copy(bone.getWorldQuaternion(new THREE.Quaternion()).invert())
        .multiply(new THREE.Quaternion().setFromAxisAngle(X, upper ? Math.PI : .12));
      bone.add(tooth); tooth.castShadow = true;
    }
    // The original FBX is centimetres, a natural 1.29m from paws to ear tips.
    this.model.scale.setScalar(.01); this.model.position.set(0, .0045, .2);
  }
  rotate(name, axis, angle) {
    const joint = this.bones.get(name);
    if (joint) joint.bone.quaternion.premultiply(this.rotation.setFromAxisAngle(joint[axis], angle));
  }
  pose() {
    for (const { bone, rest } of this.bones.values()) bone.quaternion.copy(rest);
    for (const [side, phase] of [['Left', this.phase], ['Right', this.phase + Math.PI]]) {
      const front = Math.sin(phase) * this.motion, hind = Math.sin(phase + Math.PI) * this.motion;
      this.rotate(`b_${side}UpperArm`, 'x', front * .42);
      this.rotate(`b_${side}ForeArm`, 'x', Math.max(0, -front) * -.58);
      this.rotate(`b_${side}Hand01`, 'x', Math.max(0, front) * .16);
      this.rotate(`b_${side}Leg01`, 'x', hind * .41);
      this.rotate(`b_${side}Leg02`, 'x', Math.max(0, hind) * .5);
      this.rotate(`b_${side}Foot01`, 'x', Math.max(0, -hind) * -.17);
    }
    this.rotate('b_Spine03', 'x', Math.sin(this.phase * 2) * .017 * this.motion);
    this.rotate('b_Neck', 'x', -.025 + Math.sin(this.time * 1.7) * .012);
    this.rotate('b_Jaw', 'x', .12 + Math.sin(this.time * 5.1) * .03);
    this.rotate('b_Tail01', 'y', Math.sin(this.time * 1.7) * .08);
    this.rotate('b_Tail02', 'y', Math.sin(this.time * 1.7 + .5) * .07);
  }
  update(dt, entity, player) {
    if (this.disposed) return;
    const dx = this.lastX === undefined ? 0 : entity.x - this.lastX, dz = this.lastZ === undefined ? 0 : entity.z - this.lastZ;
    const distance = Math.hypot(dx, dz); this.time += dt;
    this.motion = THREE.MathUtils.damp(this.motion, distance > .0001 ? 1 : 0, 9, dt);
    this.phase += distance * 5.2; this.pose();
    this.model.position.y = .0045 + Math.abs(Math.sin(this.phase)) * .017 * this.motion;
    this.root.position.set(entity.x, 0, entity.z);
    if (distance > .001) this.heading = Math.atan2(dx, dz);
    if (this.heading === undefined && player) this.heading = Math.atan2(player.x - entity.x, player.z - entity.z);
    const delta = Math.atan2(Math.sin((this.heading || 0) - this.root.rotation.y), Math.cos((this.heading || 0) - this.root.rotation.y));
    this.root.rotation.y += delta * (1 - Math.exp(-dt * 10));
    this.lastX = entity.x; this.lastZ = entity.z;
  }
  dispose() {
    if (this.disposed) return; this.disposed = true;
    const skeletons = new Set(); this.model.traverse(object => { if (object.isSkinnedMesh) skeletons.add(object.skeleton); });
    skeletons.forEach(skeleton => skeleton.dispose());
    this.geometries.forEach(geometry => geometry.dispose()); this.materials.forEach(material => material.dispose());
    this.root.removeFromParent(); this.root.clear();
  }
}
