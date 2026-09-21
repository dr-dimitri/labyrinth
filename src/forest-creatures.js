import * as THREE from 'three';
import { ForestWolfModel } from './forest-wolf.js';
import { MarchingCubes } from 'three/addons/objects/MarchingCubes.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

const UP = new THREE.Vector3(0, 1, 0);
const PALETTES = {
  fur: [0x292c2a, 0x52534b], skin: [0x3b4036, 0x65705c],
  leather: [0x211e18, 0x423628], cloth: [0x142d25, 0x345644],
};
const surfaceCache = new Map();
const anatomyBakeCache = new Map();

/** Original material surfaces: directional fur fibres, pores, leather grain and woven cloth. */
function acquireSurface(kind) {
  let entry = surfaceCache.get(kind);
  if (entry) { entry.users++; return entry; }
  const width = 256, height = 256, color = new Uint8Array(width * height * 4), bump = new Uint8Array(color.length);
  const dark = new THREE.Color(PALETTES[kind][0]), light = new THREE.Color(PALETTES[kind][1]);
  const hash = (x, y) => {
    const v = Math.sin(x * 127.1 + y * 311.7 + 17) * 43758.5453; return v - Math.floor(v);
  };
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const noise = hash(x, y), broad = hash(Math.floor(x / 17), Math.floor(y / 19));
    let grain = noise;
    if (kind === 'fur') {
      // Staggered, tapered strands rather than uniform parallel stripes.
      const strand = (x + Math.sin(y * .052 + x * .01) * 3.5) / 3;
      const fibre = Math.pow(Math.max(0, Math.cos(strand * Math.PI * 2)), 7);
      grain = .23 + fibre * .4 + noise * .17 + broad * .12;
    } else if (kind === 'cloth') grain = .4 + Math.sin(x * Math.PI / 2) * .09 + Math.sin(y * Math.PI / 2) * .08 + noise * .15;
    else grain = .25 + noise * .42 + broad * .18;
    const i = (y * width + x) * 4;
    color[i] = Math.round((dark.r + (light.r - dark.r) * grain) * 255);
    color[i + 1] = Math.round((dark.g + (light.g - dark.g) * grain) * 255);
    color[i + 2] = Math.round((dark.b + (light.b - dark.b) * grain) * 255);
    color[i + 3] = 255;
    bump[i] = bump[i + 1] = bump[i + 2] = Math.round(grain * 255); bump[i + 3] = 255;
  }
  const texture = data => {
    const map = new THREE.DataTexture(data, width, height, THREE.RGBAFormat);
    map.wrapS = map.wrapT = THREE.RepeatWrapping; map.magFilter = THREE.LinearFilter;
    map.minFilter = THREE.LinearMipmapLinearFilter; map.generateMipmaps = true; map.needsUpdate = true;
    return map;
  };
  const map = texture(color); // Colours are generated in linear space.
  entry = { map, bumpMap: texture(bump), users: 1 };
  surfaceCache.set(kind, entry); return entry;
}
function releaseSurface(kind) {
  const entry = surfaceCache.get(kind);
  if (entry && --entry.users === 0) { entry.map.dispose(); entry.bumpMap.dispose(); surfaceCache.delete(kind); }
}

class ForestModel {
  constructor(world, name) {
    this.world = world; this.root = new THREE.Group(); this.root.name = name;
    this.body = new THREE.Group(); this.body.name = `${name} articulated body`; this.root.add(this.body);
    this.geometries = new Set(); this.materials = new Set(); this.surfaces = new Set();
    this.phase = 0; this.motion = 0; this.time = 0; this.disposed = false;
  }
  material(parameters, surface) {
    if (surface) {
      const maps = this.surfaces.has(surface) ? surfaceCache.get(surface) : acquireSurface(surface);
      this.surfaces.add(surface);
      parameters = { map: maps.map, bumpMap: maps.bumpMap, bumpScale: surface === 'fur' ? .023 : .008, ...parameters };
    }
    const material = new THREE.MeshStandardMaterial(parameters); material.userData.organic = ['fur', 'skin'].includes(surface); this.materials.add(material); return material;
  }
  joint(name, x, y, z, parent = this.body) {
    const joint = new THREE.Group(); joint.name = name; joint.position.set(x, y, z); parent.add(joint); return joint;
  }
  mesh(name, geometry, material, position, parent = this.body) {
    this.geometries.add(geometry);
    const mesh = new THREE.Mesh(geometry, material); mesh.name = name;
    mesh.position.set(...position); mesh.castShadow = true; mesh.receiveShadow = true; parent.add(mesh); return mesh;
  }
  ellipsoid(name, radius, scale, material, position, parent = this.body, rough = 0) {
    const geometry = new THREE.SphereGeometry(radius, 20, 14);
    if (rough) {
      const vertices = geometry.attributes.position;
      for (let i = 0; i < vertices.count; i++) {
        const x = vertices.getX(i), y = vertices.getY(i), z = vertices.getZ(i);
        const n = 1 + rough * (Math.sin(x * 21 + z * 17) * Math.sin(y * 29 - x * 11));
        vertices.setXYZ(i, x * n, y * n, z * n);
      }
      geometry.computeVertexNormals();
    }
    const mesh = this.mesh(name, geometry, material, position, parent); mesh.scale.set(...scale); mesh.userData.ellipsoid = radius; return mesh;
  }
  segment(name, start, end, top, bottom, material, parent = this.body, sides = 12) {
    const a = new THREE.Vector3(...start), b = new THREE.Vector3(...end), delta = b.clone().sub(a);
    const mesh = this.mesh(name, new THREE.CylinderGeometry(top, bottom, delta.length(), sides, 3), material, a.add(b).multiplyScalar(.5).toArray(), parent);
    mesh.quaternion.setFromUnitVectors(UP, delta.normalize()); return mesh;
  }
  curve(name, points, radius, material, parent = this.body, radial = 8) {
    return this.mesh(name, new THREE.TubeGeometry(new THREE.CatmullRomCurve3(points.map(p => new THREE.Vector3(...p))), 16, radius, radial, false), material, [0, 0, 0], parent);
  }
  tooth(name, x, y, z, length, material, parent, upwards = false) {
    const mesh = this.mesh(name, new THREE.ConeGeometry(.018, length, 10, 3), material, [x, y, z], parent);
    mesh.rotation.x = upwards ? -.2 : Math.PI + .12; mesh.userData.tooth = true; return mesh;
  }
  ear(name, sign, material, position, parent, long = false) {
    // A thick curved pinna with a rounded base and a fine, swept tip.
    const shape = new THREE.Shape();
    shape.moveTo(-.05, -.04); shape.bezierCurveTo(-.11, .1, -.05, .2, long ? .19 : .015, long ? .22 : .3);
    shape.bezierCurveTo(.11, .1, .13, -.015, .04, -.06); shape.closePath();
    const geometry = new THREE.ExtrudeGeometry(shape, { depth: .023, bevelEnabled: true, bevelSize: .012, bevelThickness: .012, bevelSegments: 2, curveSegments: 10, steps: 1 });
    const ear = this.mesh(name, geometry, material, position, parent); ear.scale.x = sign; return ear;
  }
  organicSurface(joint) {
    const groups = new Map();
    for (const child of joint.children) {
      if (!child.isMesh || !child.userData.ellipsoid || !child.material.userData.organic || child.userData.keepMesh) continue;
      if (!groups.has(child.material)) groups.set(child.material, []);
      groups.get(child.material).push(child);
    }
    for (const [material, parts] of groups) {
      if (parts.length < 2) continue;
      const cacheKey = `${this.type}:${joint.name}:${material.color.getHex()}:` + parts.map(p =>
        [p.name, p.userData.ellipsoid, ...p.position.toArray(), ...p.scale.toArray(), ...p.quaternion.toArray()].join(',')).join(';');
      const cached = anatomyBakeCache.get(cacheKey);
      if (cached) {
        for (const part of parts) { part.removeFromParent(); this.geometries.delete(part.geometry); part.geometry.dispose(); }
        this.mesh(`${joint.name} continuous anatomy`, cached.clone(), material, [0, 0, 0], joint); continue;
      }
      const bounds = new THREE.Box3();
      const descriptions = parts.map(part => {
        part.updateMatrix(); part.geometry.computeBoundingBox();
        bounds.union(part.geometry.boundingBox.clone().applyMatrix4(part.matrix));
        const scale = part.scale.clone().multiplyScalar(part.userData.ellipsoid);
        const inverse = new THREE.Matrix4().compose(part.position, part.quaternion, new THREE.Vector3(1, 1, 1)).invert().elements;
        return { inverse, scale, min: Math.min(scale.x, scale.y, scale.z) };
      });
      // Smooth signed-distance unions make uninterrupted anatomy, including the shoulders,
      // cheekbones and muzzle. The field is baked once, never evaluated while playing.
      bounds.expandByScalar(.095);
      const centre = bounds.getCenter(new THREE.Vector3()), extent = bounds.getSize(new THREE.Vector3()).multiplyScalar(.5);
      const resolution = 34;
      const cubes = new MarchingCubes(resolution, material, false, false, 25000);
      cubes.isolation = 0;
      const k = material === this.skin ? .07 : .055;
      for (let z = 0; z < resolution; z++) for (let y = 0; y < resolution; y++) for (let x = 0; x < resolution; x++) {
        const px = centre.x + (x / resolution * 2 - 1) * extent.x;
        const py = centre.y + (y / resolution * 2 - 1) * extent.y;
        const pz = centre.z + (z / resolution * 2 - 1) * extent.z;
        let distance = 100;
        for (const { inverse: m, scale: a, min } of descriptions) {
          const lx = (m[0] * px + m[4] * py + m[8] * pz + m[12]) / a.x;
          const ly = (m[1] * px + m[5] * py + m[9] * pz + m[13]) / a.y;
          const lz = (m[2] * px + m[6] * py + m[10] * pz + m[14]) / a.z;
          const next = (Math.sqrt(lx * lx + ly * ly + lz * lz) - 1) * min;
          const h = Math.max(k - Math.abs(distance - next), 0) / k;
          distance = Math.min(distance, next) - h * h * k * .25;
        }
        cubes.field[x + y * resolution + z * resolution * resolution] = -distance;
      }
      cubes.update();
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.BufferAttribute(cubes.positionArray.slice(0, cubes.count * 3), 3));
      geometry.setAttribute('normal', new THREE.BufferAttribute(cubes.normalArray.slice(0, cubes.count * 3), 3));
      geometry.scale(extent.x, extent.y, extent.z); geometry.translate(centre.x, centre.y, centre.z);
      const positions = geometry.attributes.position, uv = new Float32Array(positions.count * 2);
      for (let i = 0; i < positions.count; i++) {
        uv[i * 2] = Math.atan2((positions.getX(i) - centre.x) / extent.x, (positions.getZ(i) - centre.z) / extent.z) / (Math.PI * 2) + .5;
        uv[i * 2 + 1] = (positions.getY(i) - centre.y) / (extent.y * 2) + .5;
      }
      geometry.setAttribute('uv', new THREE.BufferAttribute(uv, 2)); cubes.geometry.dispose();
      for (const part of parts) { part.removeFromParent(); this.geometries.delete(part.geometry); part.geometry.dispose(); }
      anatomyBakeCache.set(cacheKey, geometry.clone());
      this.mesh(`${joint.name} continuous anatomy`, geometry, material, [0, 0, 0], joint);
    }
  }
  /** Merge only geometry local to a joint; animation pivots and semantic details remain intact. */
  batch(joint) {
    this.organicSurface(joint);
    const batches = new Map();
    for (const object of [...joint.children]) {
      if (!object.isMesh || object.userData.tooth || object.userData.keepMesh) continue;
      object.updateMatrix();
      const geometry = object.geometry.index ? object.geometry.toNonIndexed() : object.geometry.clone();
      geometry.applyMatrix4(object.matrix);
      if (!batches.has(object.material)) batches.set(object.material, []);
      batches.get(object.material).push(geometry);
      this.geometries.delete(object.geometry); object.geometry.dispose(); object.removeFromParent();
    }
    for (const [material, geometries] of batches) {
      const geometry = mergeGeometries(geometries);
      geometries.forEach(g => g.dispose());
      if (geometry) this.mesh(`${joint.name} surface`, geometry, material, [0, 0, 0], joint);
    }
  }
  follow(dt, entity, player) {
    this.time += dt;
    const dx = this.lastX === undefined ? 0 : entity.x - this.lastX;
    const dz = this.lastZ === undefined ? 0 : entity.z - this.lastZ;
    const distance = Math.hypot(dx, dz);
    this.motion = THREE.MathUtils.damp(this.motion, distance > .0001 ? 1 : 0, 9, dt);
    this.phase += distance * (this.type === 'wolf' ? 5.2 : 4.1);
    // The renderer applies entity.y - floorY once, exactly as for GuardianModel.
    this.root.position.set(entity.x, 0, entity.z);
    if (distance > .001) this.heading = Math.atan2(dx, dz);
    if (this.heading === undefined && player) this.heading = Math.atan2(player.x - entity.x, player.z - entity.z);
    if (this.heading !== undefined) {
      const delta = Math.atan2(Math.sin(this.heading - this.root.rotation.y), Math.cos(this.heading - this.root.rotation.y));
      this.root.rotation.y += delta * (1 - Math.exp(-dt * 10));
    }
    this.lastX = entity.x; this.lastZ = entity.z;
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true; this.root.removeFromParent(); this.root.clear();
    this.geometries.forEach(g => g.dispose()); this.materials.forEach(m => m.dispose());
    this.surfaces.forEach(releaseSurface);
    this.geometries.clear(); this.materials.clear(); this.surfaces.clear();
  }
}

/** Authored anatomical forest enemies; facing +Z, feet at local y=0. */
export class ForestCreature extends ForestModel {
  constructor(world, type) {
    super(world, type === 'wolf' ? 'Rotaugenwolf' : 'Waldork'); this.type = type;
    if (type === 'wolf' && world.assets?.forestWolf) return new ForestWolfModel(world.assets.forestWolf);
    if (type !== 'wolf' && type !== 'orc') throw new Error(`Unknown forest creature: ${type}`);
    this.bone = this.material({ color: 0xded0a4, roughness: .5 });
    this.black = this.material({ color: 0x080b0a, roughness: .37 });
    this.eye = this.material({ color: type === 'wolf' ? 0x490803 : 0x7d591d, emissive: type === 'wolf' ? 0xff0800 : 0xa86b19, emissiveIntensity: type === 'wolf' ? 1.25 : .65, roughness: .3, toneMapped: false });
    this.legs = [];
    if (type === 'wolf') this.buildWolf(); else this.buildOrc();
  }
  buildWolf() {
    this.fur = this.material({ color: 0xc0c3b3, roughness: .98 }, 'fur');
    this.darkFur = this.material({ color: 0x959d97, roughness: 1 }, 'fur');
    this.lightFur = this.material({ color: 0xd6d0bd, roughness: .96 }, 'fur');
    const inside = this.material({ color: 0x4b3733, roughness: .88 });
    this.ellipsoid('Long ribcage', .35, [.83, .89, 1.77], this.fur, [0, .89, -.02], this.body, .03);
    this.ellipsoid('Withers', .26, [.92, 1.12, 1.28], this.fur, [0, .98, .34], this.body, .045);
    this.ellipsoid('Abdomen tuck', .24, [.83, .77, 1.3], this.fur, [0, .78, -.25]);
    this.ellipsoid('Haunches', .3, [.82, .88, 1.04], this.fur, [0, .84, -.48]);
    this.neck = this.joint('Wolf neck', 0, .97, .5);
    const ruff = this.ellipsoid('Thick throat ruff', .29, [1.03, 1.24, 1.01], this.fur, [0, .11, .11], this.neck, .055); ruff.rotation.x = .32;
    this.head = this.joint('Wolf head', 0, .19, .22, this.neck);
    this.ellipsoid('Cranium', .23, [.88, .95, 1.15], this.fur, [0, 0, .035], this.head, .02);
    for (const side of [-1, 1]) {
      this.ellipsoid('Cheek fur', .14, [.75, .9, 1.12], this.fur, [side * .14, -.06, .07], this.head, .05);
      this.ellipsoid('Eye socket', .07, [1, .72, .65], this.darkFur, [side * .142, .035, .213], this.head);
      const eye = this.ellipsoid(`Wolf ${side < 0 ? 'left' : 'right'} red eye`, .028, [1, .69, .55], this.eye, [side * .151, .032, .25], this.head); eye.userData.keepMesh = true;
      this.ellipsoid('Wet pupil', .012, [.65, 1, .4], this.black, [side * .153, .032, .264], this.head);
      const brow = this.ellipsoid('Predatory brow', .065, [1.2, .32, .8], this.darkFur, [side * .145, .082, .22], this.head); brow.rotation.z = side * .21;
      this.ear(`Wolf ${side < 0 ? 'left' : 'right'} ear`, side, this.darkFur, [side * .125, .13, -.06], this.head).scale.multiplyScalar(.72);
      const innerEar = this.ear('Ear inner fur', side, inside, [side * .125, .15, -.022], this.head); innerEar.scale.multiplyScalar(.46);
    }
    this.ellipsoid('Long muzzle bridge', .17, [.65, .54, 1.54], this.fur, [0, -.057, .289], this.head);
    this.ellipsoid('Black nose', .064, [1.12, .74, .7], this.black, [0, -.037, .535], this.head);
    this.ellipsoid('Open dark mouth', .12, [.7, .28, 1.45], this.black, [0, -.14, .36], this.head);
    this.jaw = this.joint('Wolf lower jaw', 0, -.155, .14, this.head);
    this.ellipsoid('Lower muzzle', .12, [.69, .42, 1.73], this.lightFur, [0, -.015, .19], this.jaw);
    for (const side of [-1, 1]) {
      this.tooth(`Wolf long upper canine ${side}`, side * .07, -.154, .395, .115, this.bone, this.head);
      this.tooth(`Wolf lower canine ${side}`, side * .062, .032, .34, .074, this.bone, this.jaw, true);
      for (let i = 0; i < 3; i++) this.tooth('Wolf small cheek tooth', side * .07, -.13, .25 + i * .035, .032, this.bone, this.head);
    }
    for (const [front, z] of [[true, .34], [false, -.46]]) for (const side of [-1, 1]) {
      const leg = this.joint(`Wolf ${front ? 'front' : 'hind'} ${side < 0 ? 'left' : 'right'} leg`, side * .2, front ? .93 : .87, z);
      this.ellipsoid('Muscular upper leg', .145, [front ? .74 : .9, 1.63, .84], this.fur, [0, -.14, front ? -.02 : .04], leg);
      const knee = this.joint('Wolf knee', 0, -.38, front ? .025 : .17, leg);
      this.segment('Tapered lower leg', [0, 0, 0], [0, -.31, front ? -.045 : -.2], .057, .042, this.fur, knee);
      this.ellipsoid('Knee joint', .064, [1, 1.12, 1], this.fur, [0, -.02, 0], knee);
      const ankle = this.joint('Wolf hock', 0, -.31, front ? -.045 : -.2, knee);
      this.segment('Pastern', [0, 0, 0], [0, front ? -.13 : -.07, .045], .04, .046, this.fur, ankle);
      const pawY = front ? -.165 : -.105;
      this.ellipsoid('Wolf paw', .075, [1, .66, 1.5], this.darkFur, [0, pawY, .087], ankle);
      for (const dx of [-.047, 0, .047]) {
        this.ellipsoid('Toe', .034, [.8, .73, 1.4], this.fur, [dx, pawY - .005, .16], ankle);
        this.segment('Claw', [dx, pawY - .01, .18], [dx, pawY - .024, .21], .012, .001, this.black, ankle, 6);
      }
      this.legs.push({ hip: leg, knee, ankle, front, side });
      this.batch(ankle); this.batch(knee); this.batch(leg);
    }
    this.tail = this.joint('Wolf bushy tail', 0, .88, -.67);
    this.curve('Tail core', [[0, 0, 0], [0, -.08, -.22], [.025, -.28, -.42], [.05, -.48, -.46]], .105, this.darkFur, this.tail);
    const tailTip = this.ellipsoid('Tail taper', .14, [.6, 1.07, .63], this.darkFur, [.047, -.42, -.455], this.tail, .05); tailTip.rotation.x = -.14;
    this.batch(this.tail); this.batch(this.jaw); this.batch(this.head); this.batch(this.neck); this.batch(this.body);
    this.addFurTufts(this.body, [0, .89, -.02], [.297, .322, .61], 1100, .02);
    this.addFurTufts(this.neck, [0, .11, .11], [.292, .35, .286], 700, .028);
    this.addFurTufts(this.head, [0, 0, .035], [.21, .22, .253], 300, .012);
  }
  addFurTufts(parent, centre, radii, count, length) {
    const positions = [], normals = [], uv = [];
    const n = new THREE.Vector3(), tangent = new THREE.Vector3(), bitangent = new THREE.Vector3(), point = new THREE.Vector3();
    // Fine, swept silhouette fibres catch rim light. Three crossed blades share one draw call.
    for (let i = 0; i < count; i++) {
      const theta = i * 2.399963229728653, v = (i + .5) / count;
      const y = 1 - v * 2, radial = Math.sqrt(Math.max(0, 1 - y * y));
      n.set(Math.cos(theta) * radial, y, Math.sin(theta) * radial);
      if (n.y < -.58) continue;
      point.set(centre[0] + n.x * radii[0], centre[1] + n.y * radii[1], centre[2] + n.z * radii[2]);
      tangent.crossVectors(n, UP).normalize(); if (tangent.lengthSq() < .1) tangent.set(1, 0, 0);
      bitangent.crossVectors(n, tangent);
      const hairLength = length * (.65 + .35 * Math.sin(i * 13.3));
      for (const blade of [tangent, bitangent]) {
        const a = point.clone().addScaledVector(blade, .0025), b = point.clone().addScaledVector(blade, -.0025);
        const tip = point.clone().addScaledVector(n, hairLength); tip.z -= hairLength * .48;
        positions.push(...a.toArray(), ...b.toArray(), ...tip.toArray());
        normals.push(...n.toArray(), ...n.toArray(), ...n.toArray()); uv.push(0, 0, 1, 0, .5, 1);
      }
    }
    const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3)); geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    const material = this.material({ color: 0xb6bbab, map: this.fur.map, roughness: 1, side: THREE.DoubleSide });
    this.mesh('Fine swept fur silhouette', geometry, material, [0, 0, 0], parent).castShadow = false;
  }

  buildOrc() {
    this.skin = this.material({ color: 0xb5bdab, roughness: .93 }, 'skin');
    this.leather = this.material({ color: 0xb1a08a, roughness: .88 }, 'leather');
    this.iron = this.material({ color: 0x343d3b, metalness: .76, roughness: .62 });
    const edge = this.material({ color: 0x777968, metalness: .78, roughness: .38 });
    const hair = this.material({ color: 0x1a1d17, roughness: 1 }, 'fur');
    this.torso = this.joint('Orc chest', 0, 1.43, 0);
    this.ellipsoid('Massive thorax', .35, [1.28, 1.18, .71], this.skin, [0, .03, 0], this.torso, .013);
    this.ellipsoid('Abdomen', .26, [1.13, 1.02, .7], this.skin, [0, -.28, .025], this.torso);
    for (const side of [-1, 1]) {
      this.ellipsoid('Pectoral muscle', .19, [1.05, .67, .4], this.skin, [side * .175, .07, .155], this.torso);
      for (let i = 0; i < 3; i++) this.ellipsoid('Abdominal muscle', .063, [1.23, .65, .3], this.skin, [side * .074, -.17 - i * .09, .169], this.torso);
    }
    const breastplate = new THREE.PlaneGeometry(1, 1, 28, 14);
    const armorVertices = breastplate.attributes.position;
    for (let i = 0; i < armorVertices.count; i++) {
      const u = armorVertices.getX(i) + .5, v = armorVertices.getY(i) + .5;
      const angle = (u - .5) * 2.55, width = .30 + Math.sin(v * Math.PI * .7) * .13;
      armorVertices.setXYZ(i, Math.sin(angle) * width, -.3 + v * .58,
        Math.cos(angle) * (.23 + v * .025) + .047 + Math.sin(v * 14) * .004);
    }
    breastplate.computeVertexNormals();
    this.mesh('Worn moulded leather breastplate', breastplate, this.leather, [0, 0, 0], this.torso);
    for (const side of [-1, 1]) {
      this.curve('Breastplate bound edge', [[side * .29, -.3, .13], [side * .4, .01, .16], [side * .395, .28, .16]], .014, this.leather, this.torso);
      for (let i = 0; i < 6; i++) this.ellipsoid('Hammered chest rivet', .012, [1, 1, .5], edge,
        [side * (.064 + i * .054), .252, .294 - i * i * .004], this.torso);
    }
    // Three separate diagonal hide straps sit against the chest, with metal studs.
    for (let i = 0; i < 3; i++) this.segment('Chest harness', [-.35 + i * .014, .26, .16], [.26 + i * .014, -.3, .23], .025, .025, this.leather, this.torso, 8);
    this.head = this.joint('Orc head', 0, 1.93, .055);
    this.ellipsoid('Orc neck', .145, [1.08, 1.37, .95], this.skin, [0, -.16, -.02], this.head);
    this.ellipsoid('Heavy skull', .2, [.9, 1.11, .92], this.skin, [0, .025, 0], this.head, .02);
    this.ellipsoid('Strong lower jaw', .15, [1.15, .82, .92], this.skin, [0, -.105, .075], this.head);
    this.ellipsoid('Broad nose', .075, [.99, .91, .8], this.skin, [0, -.003, .193], this.head);
    this.ellipsoid('Mouth', .09, [1.3, .21, .37], this.black, [0, -.103, .213], this.head);
    for (const side of [-1, 1]) {
      this.ellipsoid('Nostril', .018, [1, .65, .5], this.black, [side * .046, -.029, .245], this.head);
      this.ellipsoid('Deep eye socket', .052, [1.15, .72, .54], this.black, [side * .093, .069, .16], this.head);
      const eye = this.ellipsoid('Orc amber eye', .019, [1.2, .75, .55], this.eye, [side * .096, .069, .187], this.head); eye.userData.keepMesh = true;
      const brow = this.ellipsoid('Orc brow ridge', .07, [1.22, .43, .53], this.skin, [side * .1, .108, .144], this.head); brow.rotation.z = side * .16;
      this.ear('Orc pointed ear', side, this.skin, [side * .175, .025, -.035], this.head, true).scale.multiplyScalar(.58);
      const tusk = this.tooth('Orc curved tusk', side * .087, -.061, .225, .122, this.bone, this.head, true); tusk.rotation.z = side * -.21;
      for (let i = 0; i < 4; i++) this.curve('Braided hair', [[side * .14, .19 - i * .018, -.035 - i * .022], [side * .2, .06, -.12 - i * .02], [side * .18, -.18 - i * .035, -.12]], .024, hair, this.head);
    }
    this.ellipsoid('Hair crown', .204, [.95, .46, .97], hair, [0, .171, -.035], this.head);
    this.curve('Cheek scar', [[-.146, .02, .139], [-.152, -.028, .141], [-.14, -.076, .159]], .007, this.leather, this.head, 5);
    const belt = this.mesh('Wide hide belt', new THREE.CylinderGeometry(.305, .31, .16, 24, 1, true), this.leather, [0, 1.105, .01]); belt.scale.z = .72;
    this.ellipsoid('Iron belt clasp', .08, [1.08, .85, .3], edge, [0, 1.105, .239]);
    const skirt = new THREE.CylinderGeometry(.29, .39, .39, 32, 5, true);
    const vertices = skirt.attributes.position;
    for (let i = 0; i < vertices.count; i++) {
      const angle = Math.atan2(vertices.getX(i), vertices.getZ(i));
      const scale = 1 + Math.sin(angle * 12) * .035;
      vertices.setXYZ(i, vertices.getX(i) * scale, vertices.getY(i) + (vertices.getY(i) < -.17 ? Math.sin(angle * 7) * .042 : 0), vertices.getZ(i) * scale * .78);
    }
    skirt.computeVertexNormals(); this.mesh('Ragged hide battle skirt', skirt, this.leather, [0, .86, .01]);
    this.arms = [];
    for (const side of [-1, 1]) {
      const arm = this.joint(`Orc ${side < 0 ? 'left' : 'right'} arm`, side * .4, 1.64, .01);
      this.ellipsoid('Deltoid', .18, [1.05, 1.12, .98], this.skin, [side * .035, -.025, 0], arm);
      this.ellipsoid('Upper arm biceps', .139, [.92, 1.74, .97], this.skin, [side * .058, -.18, .015], arm);
      const forearm = this.joint('Orc elbow', side * .071, -.38, .025, arm);
      this.ellipsoid('Strong forearm', .123, [.85, 1.63, 1], this.skin, [side * .01, -.13, .05], forearm);
      this.ellipsoid('Iron vambrace', .13, [.91, .92, 1.04], this.iron, [side * .02, -.23, .08], forearm);
      this.ellipsoid('Fist', .093, [1.06, 1.23, .94], this.skin, [side * .025, -.355, .094], forearm);
      for (let i = 0; i < 4; i++) this.ellipsoid('Knuckle', .029, [.72, .9, 1], this.skin, [side * .025 + (i - 1.5) * .037, -.367, .17], forearm);
      if (side === -1) {
        const pauldron = this.mesh('Forged shoulder armour', new THREE.SphereGeometry(.24, 20, 10, 0, Math.PI * 2, 0, Math.PI * .55), this.iron, [-.05, .015, -.01], arm);
        pauldron.scale.set(1.22, .8, 1.22);
        for (let i = 0; i < 4; i++) this.ellipsoid('Armour rivet', .022, [1, .7, 1], edge, [-.17 + i * .082, .03, .238], arm);
        for (let i = 0; i < 3; i++) this.segment('Blunt armour spike', [-.1 + i * .08, .15, -.03], [-.15 + i * .1, .29 + (i % 2) * .035, -.03], .002, .039, this.iron, arm, 9);
      } else {
        this.weapon = this.joint('Orc iron axe', .025, -.355, .09, forearm);
        this.segment('Axe hardwood haft', [0, -.28, -.06], [0, .58, .12], .032, .036, this.leather, this.weapon);
        const blade = new THREE.Shape();
        blade.moveTo(-.035, .46); blade.quadraticCurveTo(.22, .62, .34, .62); blade.quadraticCurveTo(.29, .37, .34, .27); blade.quadraticCurveTo(.14, .32, -.035, .34); blade.closePath();
        this.mesh('Weathered axe blade', new THREE.ExtrudeGeometry(blade, { depth: .047, bevelEnabled: true, bevelSize: .017, bevelThickness: .012, bevelSegments: 2, curveSegments: 12 }), edge, [0, 0, .045], this.weapon);
        this.batch(this.weapon);
      }
      arm.rotation.z = side * .11; this.arms.push({ shoulder: arm, elbow: forearm, side });
      this.batch(forearm); this.batch(arm);
      const hip = this.joint(`Orc ${side < 0 ? 'left' : 'right'} leg`, side * .18, .92, 0);
      this.ellipsoid('Powerful thigh', .17, [.91, 1.67, .96], this.skin, [0, -.19, 0], hip);
      const knee = this.joint('Orc knee', 0, -.44, .015, hip);
      this.ellipsoid('Leather boot shaft', .12, [1, 1.72, 1.07], this.leather, [0, -.2, -.005], knee);
      this.ellipsoid('Boot toe', .135, [.96, .57, 1.6], this.leather, [0, -.415, .075], knee);
      this.ellipsoid('Iron knee guard', .121, [1, 1.1, .41], this.iron, [0, 0, .108], knee);
      for (const y of [-.11, -.3]) this.curve('Boot binding', [[-.108, y, -.025], [-.09, y, .075], [0, y, .125], [.09, y, .075], [.108, y, -.025]], .013, this.leather, knee);
      this.legs.push({ hip, knee, side }); this.batch(knee); this.batch(hip);
    }
    this.batch(this.head); this.batch(this.torso); this.batch(this.body);
  }
  update(dt, entity, player) {
    if (this.disposed) return; this.follow(dt, entity, player);
    const stride = Math.sin(this.phase) * this.motion;
    if (this.type === 'wolf') {
      this.body.position.y = Math.abs(Math.sin(this.phase)) * .034 * this.motion;
      this.body.rotation.x = Math.sin(this.phase * 2) * .024 * this.motion;
      for (const leg of this.legs) {
        const phase = this.phase + (leg.side < 0 ? Math.PI : 0) + (leg.front ? 0 : Math.PI);
        leg.hip.rotation.x = Math.sin(phase) * .48 * this.motion;
        leg.knee.rotation.x = Math.max(0, -Math.sin(phase)) * (leg.front ? .47 : -.6) * this.motion;
        leg.ankle.rotation.x = -leg.hip.rotation.x * .35;
      }
      this.neck.rotation.x = -.05 + Math.sin(this.time * 1.7) * .018;
      this.head.rotation.y = Math.sin(this.time * .7) * .025;
      this.jaw.rotation.x = .09 + Math.sin(this.time * 5.6) * .045;
      this.tail.rotation.y = Math.sin(this.time * 2.1) * .15 + stride * .1;
    } else {
      this.body.position.y = Math.abs(stride) * .029;
      this.torso.rotation.y = stride * .065;
      for (const leg of this.legs) {
        leg.hip.rotation.x = stride * leg.side * .37;
        leg.knee.rotation.x = Math.max(0, -stride * leg.side) * .43;
      }
      for (const arm of this.arms) {
        arm.shoulder.rotation.x = -.12 - stride * arm.side * .31;
        arm.elbow.rotation.x = -.1 - Math.max(0, stride * arm.side) * .13;
      }
      this.head.rotation.z = Math.sin(this.time * 1.2) * .012;
    }
  }
}

/** Friendly ammunition keeper, separate from enemy targeting and damage. */
export class ForestElf extends ForestModel {
  constructor(world) {
    super(world, 'Elfenhüterin'); this.type = 'elf';
    this.skin = this.material({ color: 0x947f66, roughness: .92 });
    this.cloth = this.material({ color: 0xa0aaa0, roughness: .99, side: THREE.DoubleSide }, 'cloth');
    this.leather = this.material({ color: 0xb9a489, roughness: .93 }, 'leather');
    const hair = this.material({ color: 0xb2a795, roughness: .93 }, 'fur');
    const bronze = this.material({ color: 0x91805b, metalness: .65, roughness: .53 });
    const dark = this.material({ color: 0x273332, roughness: .8 });
    this.glow = this.material({ color: 0x8aa576, emissive: 0x53783b, emissiveIntensity: .5, roughness: .64 });
    this.ellipsoid('Slender tunic', .215, [.88, 1.56, .58], this.cloth, [0, 1.15, 0]);

    const tunicHem = new THREE.CylinderGeometry(.178, .247, .58, 32, 12, true);
    const hemVertices = tunicHem.attributes.position;
    for (let i = 0; i < hemVertices.count; i++) {
      const angle = Math.atan2(hemVertices.getX(i), hemVertices.getZ(i));
      const wave = Math.sin(angle * 10 + hemVertices.getY(i)) * .011;
      hemVertices.setXYZ(i, hemVertices.getX(i) + Math.sin(angle) * wave, hemVertices.getY(i), (hemVertices.getZ(i) + Math.cos(angle) * wave) * .75);
    }
    tunicHem.computeVertexNormals(); this.mesh('Woven tunic hem', tunicHem, this.cloth, [0, .78, 0]);
    for (const side of [-1, 1]) {
      this.ellipsoid('Legging', .058, [1, 5.1, 1.12], this.leather, [side * .105, .36, 0]);
      this.ellipsoid('Soft leather boot', .09, [.82, .65, 1.63], this.leather, [side * .105, .06, .04]);
    }
    this.head = this.joint('Elf head', 0, 1.65, .005);
    this.ellipsoid('Graceful neck', .06, [1, 1.8, 1], this.skin, [0, -.17, 0], this.head);
    const face = this.ellipsoid('Elf face', .138, [.72, 1.16, .81], this.skin, [0, 0, .016], this.head);
    const facePoints = face.geometry.attributes.position;
    for (let i = 0; i < facePoints.count; i++) if (facePoints.getY(i) < -.018) facePoints.setX(i, facePoints.getX(i) * (1 + (facePoints.getY(i) + .018) * 2.8));
    face.geometry.computeVertexNormals();
    this.ellipsoid('Elf nose', .026, [.63, 1.23, .91], this.skin, [0, -.025, .126], this.head);
    this.ellipsoid('Soft lips', .025, [1.15, .22, .47], this.leather, [0, -.075, .112], this.head);
    this.ellipsoid('Hair cap', .145, [.94, .82, .94], hair, [0, .063, -.033], this.head);
    for (const side of [-1, 1]) {
      const ear = this.ear('Elf long pointed ear', side, this.skin, [side * .1, .01, -.01], this.head, true); ear.scale.multiplyScalar(.37);
      this.ellipsoid('Kind eyes', .017, [1.18, .37, .36], dark, [side * .044, .017, .117], this.head);
      this.ellipsoid('Iris', .006, [.65, .83, .33], dark, [side * .044, .017, .123], this.head);
      this.curve('Fine eyebrow', [[side * .033, .05, .122], [side * .06, .055, .12], [side * .079, .046, .107]], .005, this.leather, this.head, 5);
      for (let i = 0; i < 3; i++) this.curve('Long hair braid', [[side * .11, .09, -.046 - i * .02], [side * .135, -.08, -.054 - i * .02], [side * .125, -.32, -.04 - i * .017]], .018, hair, this.head);
    }
    // Open-front draped cloak with real folds, its hem sitting above the ground.
    const cloakGeometry = new THREE.CylinderGeometry(.218, .38, 1.24, 40, 18, true, Math.PI * .11, Math.PI * 1.78);
    const positions = cloakGeometry.attributes.position;
    for (let i = 0; i < positions.count; i++) {
      const angle = Math.atan2(positions.getX(i), positions.getZ(i));
      const t = (.62 - positions.getY(i)) / 1.24;
      const ripple = Math.sin(angle * 11 + t * .65) * (.012 + t * .032);
      positions.setXYZ(i, positions.getX(i) + Math.sin(angle) * ripple, positions.getY(i) + (t > .95 ? Math.cos(angle * 7) * .03 : 0), (positions.getZ(i) + Math.cos(angle) * ripple) * .65 - .05);
    }
    cloakGeometry.computeVertexNormals();
    this.cloak = this.mesh('Draped forest cloak', cloakGeometry, this.cloth, [0, .84, -.035]); this.cloak.userData.keepMesh = true;
    this.ellipsoid('Cloak clasp', .034, [1, 1, .4], bronze, [0, 1.43, .15]);
    this.ellipsoid('Amber lantern pendant', .022, [.85, 1.3, .7], this.glow, [0, 1.32, .155]);
    this.curve('Satchel strap', [[-.19, 1.4, .05], [-.07, 1.22, .168], [.13, .98, .18], [.23, .84, .06]], .022, this.leather);
    this.ellipsoid('Ammunition satchel', .16, [1.03, 1.03, .51], this.leather, [.245, .85, .04]);
    this.ellipsoid('Satchel flap', .15, [1.06, .52, .52], this.leather, [.248, .924, .066]);
    this.ellipsoid('Satchel buckle', .027, [.7, 1, .35], bronze, [.245, .87, .128]);
    this.segment('Quiver', [-.2, .95, -.15], [-.18, 1.4, -.19], .076, .095, this.leather);
    for (let i = 0; i < 5; i++) {
      const x = -.22 + i * .023;
      this.segment('Arrow shaft', [x, 1.23, -.18], [x, 1.6 + (i % 3) * .03, -.22], .005, .005, bronze);
      this.ellipsoid('Arrow feather', .035, [.18, 1.25, .7], this.cloth, [x, 1.58 + (i % 3) * .03, -.22]);
    }
    this.arms = [];
    for (const side of [-1, 1]) {
      const arm = this.joint(`Elf ${side < 0 ? 'left' : 'right'} arm`, side * .19, 1.38, 0);
      this.ellipsoid('Sleeve', .058, [1, 2.75, 1], this.cloth, [side * .032, -.16, 0], arm);
      this.ellipsoid('Wrist cuff', .049, [1, .55, 1], this.leather, [side * .052, -.32, .012], arm);
      this.ellipsoid('Hand', .042, [.82, 1.4, .7], this.skin, [side * .053, -.39, .027], arm);
      for (let i = 0; i < 4; i++) this.ellipsoid('Finger', .012, [.66, 2, .74], this.skin, [side * .054 + (i - 1.5) * .015, -.428, .029], arm);
      this.arms.push(arm); this.batch(arm);
    }
    this.gift = this.joint('Elf ammunition gift', 0, -.4, .105, this.arms[1]);
    for (let i = 0; i < 5; i++) {
      const x = (i - 2) * .026;
      this.segment('Gift cartridge', [x, -.04, 0], [x, .043, 0], .012, .013, bronze, this.gift);
      this.mesh('Gift bullet tip', new THREE.ConeGeometry(.012, .025, 8), bronze, [x, .055, 0], this.gift);
    }
    this.batch(this.gift); this.batch(this.head); this.batch(this.body);
    const ringGeometry = new THREE.TorusGeometry(.52, .012, 6, 64);
    this.halo = this.mesh('Friendly elf interaction ring', ringGeometry, this.glow, [0, .024, 0], this.root); this.halo.rotation.x = -Math.PI / 2;
    this.lantern = new THREE.PointLight(0xc1b88b, .25, 2.4, 2); this.lantern.position.set(0, 1.3, .4); this.root.add(this.lantern);
  }
  update(dt, entity, player) {
    if (this.disposed) return; this.follow(dt, entity, player);
    this.root.position.y = (entity.y ?? this.world?.floorY ?? 0) - (this.world?.floorY || 0);
    const distance = player ? Math.hypot(player.x - entity.x, player.z - entity.z) : Infinity;
    if (distance < 7 && player) this.heading = Math.atan2(player.x - entity.x, player.z - entity.z);
    this.body.scale.y = 1 + Math.sin(this.time * 1.6) * .002;
    this.head.rotation.x = distance < 3 ? -.035 : .025;
    const ready = !(entity.cooldown > 0);
    this.arms[0].rotation.x = Math.sin(this.time * .8) * .02;
    this.arms[1].rotation.x = THREE.MathUtils.damp(this.arms[1].rotation.x, ready && distance < 3 ? -.93 : -.14, 4, dt);
    this.gift.visible = ready;
    this.glow.emissiveIntensity = ready ? .4 + Math.sin(this.time * 1.9) * .07 : .13;
    this.halo.visible = distance < 6; this.lantern.intensity = ready ? .25 : .08;
    this.cloak.rotation.x = Math.sin(this.time * .7) * .009;
  }
}
