import * as THREE from 'three';
import { mergeGeometries, mergeVertices } from 'three/addons/utils/BufferGeometryUtils.js';
import { applyMetricUvs } from './architecture.js';
import { createRng, walkable } from './maze.js';
import { getTerrainHeight, getTerrainCave, getTerrainZone, forestBankHeight, getCaveWallOffset, getCaveRoofHeight, getCaveRoofTop } from './forest-world.js';

const CELL = 3.6;
const UP = new THREE.Vector3(0, 1, 0);
const temp = new THREE.Object3D();
export { forestBankHeight } from './forest-world.js';

function colorize(geometry, color = 0xffffff) {
  const c = new THREE.Color(color), count = geometry.attributes.position.count;
  const colors = new Float32Array(count * 3);
  for (let i = 0; i < count; i++) c.toArray(colors, i * 3);
  geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3)); return geometry;
}

/** Shared sampled surface; visible walkable vertices use the simulation's height function. */
export function createForestGround(maze, terrain) {
  const step = CELL / 6, segments = maze.size * 6;
  const geometry = new THREE.PlaneGeometry(maze.size * CELL, maze.size * CELL, segments, segments);
  geometry.rotateX(-Math.PI / 2); geometry.translate((maze.size - 1) * CELL / 2, 0, (maze.size - 1) * CELL / 2);
  const position = geometry.attributes.position, uv = geometry.attributes.uv;
  const colors = new Float32Array(position.count * 3);
  for (let i = 0; i < position.count; i++) {
    const x = position.getX(i), z = position.getZ(i), zone = getTerrainZone(terrain, x, z);
    const cave = getTerrainCave(terrain, x, z);
    const bank = cave ? 0 : forestBankHeight(maze, x, z);
    position.setY(i, getTerrainHeight(terrain, x, z) + bank);
    uv.setXY(i, x / 3.2, -z / 3.2);
    const shade = .8 + .14 * Math.sin(x * .39) * Math.cos(z * .41);
    const c = new THREE.Color(zone.startsWith('cave') ? 0x9f988a : zone === 'ravine' ? 0xaaa68d : 0xc5c6a8).multiplyScalar(shade);
    c.toArray(colors, i * 3);
  }
  geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  geometry.computeVertexNormals(); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
  geometry.userData.sampleStep = step; return geometry;
}

function branchBetween(from, to, bottomRadius, topRadius, segments = 7) {
  const delta = new THREE.Vector3().subVectors(to, from);
  const geometry = new THREE.CylinderGeometry(topRadius, bottomRadius, delta.length(), segments, 3);
  geometry.applyQuaternion(new THREE.Quaternion().setFromUnitVectors(UP, delta.normalize()));
  geometry.translate((from.x + to.x) / 2, (from.y + to.y) / 2, (from.z + to.z) / 2);
  return colorize(geometry);
}

function taperedRoot(points, radius) {
  const curve = new THREE.CatmullRomCurve3(points);
  const geometry = new THREE.TubeGeometry(curve, 14, radius, 7, false);
  const p = geometry.attributes.position, uv = geometry.attributes.uv;
  for (let i = 0; i < p.count; i++) {
    const t = uv.getX(i), centre = curve.getPointAt(t), taper = .07 + .93 * Math.pow(1 - t, .85);
    p.setXYZ(i, centre.x + (p.getX(i) - centre.x) * taper, centre.y + (p.getY(i) - centre.y) * taper, centre.z + (p.getZ(i) - centre.z) * taper);
  }
  geometry.computeVertexNormals(); return colorize(geometry, 0x8a7968);
}

function trunkGeometry(rng) {
  const pieces = [];
  const trunk = new THREE.CylinderGeometry(.12, .58, 12, 12, 12, false);
  trunk.translate(0, 6, 0);
  const p = trunk.attributes.position, uv = trunk.attributes.uv;
  for (let i = 0; i < p.count; i++) {
    const y = p.getY(i), angle = Math.atan2(p.getZ(i), p.getX(i));
    const swell = 1 + .14 * Math.sin(angle * 5 + y * .8) + .12 * Math.sin(angle * 9 - y * .3);
    const flare = y < 1.5 ? Math.pow(1 - y / 1.5, 2) * .25 : 0;
    p.setX(i, p.getX(i) * swell + Math.sin(y * .18) * .45 + Math.cos(angle) * flare);
    p.setZ(i, p.getZ(i) * swell + Math.sin(y * .3) * .13 + Math.sin(angle) * flare);
    uv.setXY(i, uv.getX(i) * 2, y / 3);
  }
  trunk.computeVertexNormals(); pieces.push(colorize(trunk));
  for (let i = 0; i < 10; i++) {
    const angle = i * 2.399 + rng() * .35, y = 5.4 + i * .56;
    const from = new THREE.Vector3(Math.sin(y * .18) * .45, y, 0);
    const reach = 2.1 + rng() * 1.4;
    const elbow = new THREE.Vector3(Math.cos(angle) * reach * .65, y + .7 + rng() * .7, Math.sin(angle) * reach * .65);
    const end = new THREE.Vector3(Math.cos(angle) * reach, y + 1.6 + rng(), Math.sin(angle) * reach);
    pieces.push(branchBetween(from, elbow, .14, .07), branchBetween(elbow, end, .07, .014));
    for (const side of [-1, 1]) {
      const twig = end.clone().add(new THREE.Vector3(Math.cos(angle + side) * .7, .25, Math.sin(angle + side) * .7));
      pieces.push(branchBetween(elbow.clone().lerp(end, .65), twig, .035, .003, 5));
    }
  }
  for (let i = 0; i < 6; i++) {
    const a = i * Math.PI / 3 + .2;
    pieces.push(branchBetween(new THREE.Vector3(0, .5, 0), new THREE.Vector3(Math.cos(a) * 1.35, .03, Math.sin(a) * 1.35), .19, .025));
  }
  const geometry = mergeGeometries(pieces); pieces.forEach(g => g.dispose()); return geometry;
}

function leafGeometry(rng, photographic = false) {
  const positions = [], uvs = [], colors = [];
  const append = (v, u, w, shade) => { positions.push(...v); uvs.push(u, w); colors.push(shade * .78, shade, shade * .66); };
  const count = photographic ? 64 : 350;
  for (let i = 0; i < count; i++) {
    const angle = rng() * Math.PI * 2, r = Math.sqrt(rng()) * 3.6;
    const centre = new THREE.Vector3(Math.cos(angle) * r, 8.2 + rng() * 4.9 - r * .22, Math.sin(angle) * r);
    const yaw = rng() * Math.PI * 2, tilt = rng() * .9 - .45, length = photographic ? 1.55 + rng() * .9 : .24 + rng() * .24;
    const width = length * (photographic ? .7 : .47), shade = .55 + rng() * .45;
    const rotation = new THREE.Euler(tilt, yaw, -.2 + rng() * .4);
    const point = (x, y, z) => new THREE.Vector3(x, y, z).applyEuler(rotation).add(centre).toArray();
    if (photographic) {
      const a = point(-width, 0, -length / 2), b = point(width, 0, -length / 2), c = point(width, .2, length / 2), d = point(-width, .2, length / 2);
      append(a, 0, 0, shade); append(b, 1, 0, shade); append(c, 1, 1, shade);
      append(a, 0, 0, shade); append(c, 1, 1, shade); append(d, 0, 1, shade);
    } else {
      const a = point(0, .025, 0), b = point(-width / 2, 0, length * .43), c = point(0, .045, length), d = point(width / 2, 0, length * .43);
      append(a, .5, 0, shade); append(b, 0, .43, shade); append(c, .5, 1, shade);
      append(a, .5, 0, shade); append(c, .5, 1, shade); append(d, 1, .43, shade);
    }
  }
  const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2)); geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
  geometry.computeVertexNormals(); return geometry;
}

function fernGeometry(rng) {
  const pieces = [];
  for (let f = 0; f < 7; f++) {
    const a = f * Math.PI * 2 / 7 + rng() * .25, reach = .55 + rng() * .3, height = .3 + rng() * .35;
    const points = [];
    for (let j = 0; j <= 8; j++) {
      const t = j / 8; points.push(new THREE.Vector3(Math.cos(a) * reach * t, Math.sin(t * Math.PI * .8) * height, Math.sin(a) * reach * t));
    }
    const spine = new THREE.TubeGeometry(new THREE.CatmullRomCurve3(points), 8, .009, 3, false); pieces.push(colorize(spine, 0x8b9b70));
    const positions = [], colors = [], uvs = [];
    for (let j = 1; j < 8; j++) for (const side of [-1, 1]) {
      const p = points[j], width = Math.sin(j / 8 * Math.PI) * .21;
      const tip = p.clone().add(new THREE.Vector3(Math.cos(a + side * 1.05) * width, -.015, Math.sin(a + side * 1.05) * width));
      const tail = p.clone().lerp(points[j + 1], .8);
      positions.push(...p.toArray(), ...tip.toArray(), ...tail.toArray());
      for (let v = 0; v < 3; v++) { colors.push(.36, .49 + j * .017, .23); uvs.push(v / 2, j / 8); }
    }
    const leaves = new THREE.BufferGeometry(); leaves.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    leaves.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2)); leaves.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3)); leaves.computeVertexNormals();
    pieces.push(leaves);
  }
  const normalised = pieces.map(g => g.index ? g.toNonIndexed() : g);
  const geometry = mergeGeometries(normalised); new Set([...pieces, ...normalised]).forEach(g => g.dispose()); return geometry;
}

export function createForestCrag() {
  const source = new THREE.IcosahedronGeometry(1, 3);
  source.deleteAttribute('normal'); source.deleteAttribute('uv');
  const geometry = mergeVertices(source), p = geometry.attributes.position; source.dispose();
  for (let i = 0; i < p.count; i++) {
    const x = p.getX(i), y = p.getY(i), z = p.getZ(i);
    const irregularity = 1 + .16 * Math.sin(x * 7 + y * 3) * Math.cos(z * 6) + .1 * Math.cos(y * 8 + z * 4);
    p.setXYZ(i, x * irregularity, y * irregularity, z * irregularity);
  }
  let radius = 0;
  for (let i = 0; i < p.count; i++) radius = Math.max(radius, Math.hypot(p.getX(i), p.getZ(i)));
  for (let i = 0; i < p.count; i++) { p.setX(i, p.getX(i) / radius); p.setZ(i, p.getZ(i) / radius); }
  geometry.computeVertexNormals();
  applyMetricUvs(geometry, 1.25);
  return colorize(geometry);
}

/** A continuous closed rock shell: a vaulted underside, thick hilltop and
 * scalloped walls. Its underside and roof thickness share the ballistics API. */
export function createForestCaveShell(terrain, cave) {
  const width = cave.maxX - cave.minX, depth = cave.maxZ - cave.minZ;
  const nx = Math.round(width / CELL) * 6, nz = Math.round(depth / CELL) * 6;
  const centreZ = (cave.minZ + cave.maxZ) / 2;
  const edgeZ = (x, cross) => centreZ + cross * depth / 2
    + Math.sign(cross) * Math.abs(cross) ** 8 * getCaveWallOffset(cave, x, Math.sign(cross), 1);
  const horizontal = (upper) => {
    const geometry = new THREE.PlaneGeometry(width, depth, nx, nz);
    geometry.rotateX(upper ? -Math.PI / 2 : Math.PI / 2);
    const p = geometry.attributes.position, uv = geometry.attributes.uv;
    for (let i = 0; i < p.count; i++) {
      const x = p.getX(i) + (cave.minX + cave.maxX) / 2;
      const z = edgeZ(x, p.getZ(i) / (depth / 2));
      const y = upper ? getCaveRoofTop(terrain, cave, x, z) : getCaveRoofHeight(terrain, cave, x, z);
      p.setXYZ(i, x, y, z); uv.setXY(i, x / 2.38, z / 2.38);
    }
    geometry.computeVertexNormals(); return geometry;
  };
  const result = { vault: horizontal(false), hilltop: horizontal(true) };
  for (const side of [-1, 1]) {
    const geometry = new THREE.PlaneGeometry(width, 1, nx, 20);
    const p = geometry.attributes.position, uv = geometry.attributes.uv;
    for (let i = 0; i < p.count; i++) {
      const x = p.getX(i) + (cave.minX + cave.maxX) / 2, t = p.getY(i) + .5;
      const boundary = side < 0 ? cave.minZ : cave.maxZ;
      const topZ = edgeZ(x, side), base = getTerrainHeight(terrain, x, topZ) - .3;
      const top = getCaveRoofTop(terrain, cave, x, topZ);
      const heightFraction = Math.min(1, Math.max(0, (t * (top - base) - .3) / cave.ceilingHeight));
      const z = boundary + side * getCaveWallOffset(cave, x, side, heightFraction);
      const y = base + t * (top - base);
      p.setXYZ(i, x, y, z); uv.setXY(i, x / 2.38, y / 2.38);
    }
    geometry.computeVertexNormals(); result[side < 0 ? 'north-bank' : 'south-bank'] = geometry;
  }
  for (const side of [-1, 1]) {
    const x = side < 0 ? cave.minX : cave.maxX;
    const geometry = new THREE.PlaneGeometry(depth, 1, nz, 8);
    const p = geometry.attributes.position, uv = geometry.attributes.uv;
    for (let i = 0; i < p.count; i++) {
      const z = edgeZ(x, p.getX(i) / (depth / 2)), t = p.getY(i) + .5;
      const below = getCaveRoofHeight(terrain, cave, x, z), top = getCaveRoofTop(terrain, cave, x, z);
      const y = below + (top - below) * t;
      p.setXYZ(i, x, y, z); uv.setXY(i, z / 2.38, y / 2.38);
    }
    geometry.computeVertexNormals(); result[side < 0 ? 'west-arch' : 'east-arch'] = geometry;
  }
  return result;
}

/** Batched woodland, cliffs and organically shaped cave volumes. */
export class ForestRenderer {
  constructor(world, simulation) {
    this.world = world; this.simulation = simulation; this.terrain = simulation.terrain;
    this.maze = simulation.maze; this.rng = createRng(`${this.maze.seed}:forest-geometry`);
    this.root = new THREE.Group(); this.root.name = 'Dornwald · Gelände'; world.world.add(this.root);
    this.materials = []; this.foliage = [];
    this.bark = world.assets.forest?.bark || world.assets.trim;
    this.ground = world.assets.forest?.ground || world.assets.floor;
    this.rock = world.assets.forest?.rock || world.assets.trim;
    this.earth = world.assets.forest?.earth || this.ground;
    this.leafMaterial = new THREE.MeshStandardMaterial({ color: 0x718469, vertexColors: true, roughness: .95, side: THREE.DoubleSide, ...(world.assets.forest?.foliage ? { map: world.assets.forest.foliage.map, alphaMap: world.assets.forest.foliage.alphaMap, alphaTest: .42 } : {}) });
    this.materials.push(this.leafMaterial);
    this.addGround(); this.addForest(); this.addCaves(); this.addAtmosphere();
  }

  mesh(geometry, material, x = 0, y = 0, z = 0) {
    const mesh = new THREE.Mesh(geometry, material); mesh.position.set(x, y, z); mesh.castShadow = mesh.receiveShadow = true;
    this.root.add(mesh); return mesh;
  }

  batch(geometry, material, transforms, name, { castShadow = true } = {}) {
    if (!transforms.length) { geometry.dispose(); return []; }
    // A single world-sized InstancedMesh cannot cull individual instances.
    // Spatial batches share one geometry/material while letting every camera
    // and shadow pass skip distant groves, rock faces and fern patches.
    const chunks = new Map();
    const chunkSize = CELL * 8;
    for (const transform of transforms) {
      const key = transforms.length > 32
        ? `${Math.floor((transform.x + CELL / 2) / chunkSize)},${Math.floor((transform.z + CELL / 2) / chunkSize)}` : 'all';
      if (!chunks.has(key)) chunks.set(key, []);
      chunks.get(key).push(transform);
    }
    return [...chunks].map(([key, placements]) => {
      const mesh = new THREE.InstancedMesh(geometry, material, placements.length);
      mesh.name = chunks.size === 1 ? name : `${name} · ${key}`;
      placements.forEach((p, i) => {
        temp.position.set(p.x, p.y, p.z); temp.rotation.set(p.rx || 0, p.angle || 0, p.rz || 0);
        temp.scale.set(p.sx ?? p.scale ?? 1, p.sy ?? p.scale ?? 1, p.sz ?? p.scale ?? 1); temp.updateMatrix(); mesh.setMatrixAt(i, temp.matrix);
        mesh.setColorAt(i, new THREE.Color().setScalar(p.tint ?? 1));
      });
      mesh.castShadow = castShadow; mesh.receiveShadow = true;
      mesh.computeBoundingBox(); mesh.computeBoundingSphere(); this.root.add(mesh); return mesh;
    });
  }

  addGround() {
    this.groundMesh = this.mesh(createForestGround(this.maze, this.terrain), this.ground); this.groundMesh.name = 'Forest terrain';
    this.groundMesh.castShadow = false;
    // The caves have their own damp mineral or root-laced earth surface, just above the shared ground.
    for (const cave of this.terrain.caves) {
      const width = cave.maxX - cave.minX, depth = cave.maxZ - cave.minZ;
      const geometry = new THREE.PlaneGeometry(width, depth, Math.ceil(width / .6), Math.ceil(depth / .6));
      geometry.rotateX(-Math.PI / 2); geometry.translate((cave.minX + cave.maxX) / 2, 0, (cave.minZ + cave.maxZ) / 2);
      const p = geometry.attributes.position, uv = geometry.attributes.uv;
      for (let i = 0; i < p.count; i++) { const x = p.getX(i), z = p.getZ(i); p.setY(i, getTerrainHeight(this.terrain, x, z) + .012); uv.setXY(i, x / 3.2, -z / 3.2); }
      geometry.computeVertexNormals(); this.mesh(colorize(geometry, 0xb0aaa0), cave.type === 'cave-rock' ? this.rock : this.earth).castShadow = false;
    }
  }

  addForest() {
    const { treeSets, rocks, ferns, caveWalls } = this.terrain.obstacles;
    const rng = this.rng;
    for (const tree of treeSets.flat()) if (tree.torch) this.attachTorch(tree, tree.cellX, tree.cellZ);
    treeSets.forEach((trees, index) => {
      this.batch(trunkGeometry(rng), this.bark, trees, `Alte Stämme ${index}`);
      const leaves = this.batch(leafGeometry(rng, Boolean(this.world.assets.forest?.foliage)), this.leafMaterial, trees, `Blätterdach ${index}`, { castShadow: false });
      this.foliage.push(...leaves);
    });
    this.batch(createForestCrag(), this.rock, rocks, 'Schluchtfelsen');
    this.batch(createForestCrag(), this.rock, caveWalls, 'Gewachsene Höhlenwände');
    const scannedFern = this.world.assets.forest?.fern;
    const fernVariants = ['fern_02_a', 'fern_02_d'].map(name => scannedFern?.getObjectByName(name)).filter(Boolean);
    if (fernVariants.length) {
      fernVariants.forEach((source, variant) => {
        const placements = ferns.filter((_, i) => i % fernVariants.length === variant).map(p => ({ ...p, scale: p.scale * 2.3 }));
        this.batch(source.geometry.clone(), source.material, placements, `Fotografierte Farne ${variant}`, { castShadow: false });
      });
    } else {
      this.batch(fernGeometry(rng), this.leafMaterial, ferns, 'Farne am Weg', { castShadow: false });
    }
  }

  attachTorch(tree, cellX, cellZ) {
    const side = [{ x: 1, z: 0 }, { x: -1, z: 0 }, { x: 0, z: 1 }, { x: 0, z: -1 }].find(d => walkable(this.maze, cellX + d.x, cellZ + d.z));
    if (!side) return;
    // A visible forged bracket bridges the trunk and the torch, instead of a floating light.
    const y = tree.y + 1.05, x = tree.x + side.x * .73, z = tree.z + side.z * .73;
    this.mesh(branchBetween(new THREE.Vector3(tree.x + side.x * .27, y - .25, tree.z + side.z * .27), new THREE.Vector3(x, y - .3, z), .028, .028, 6), this.world.iron);
    this.world.addTorch(x, z, { x: -side.x, z: -side.z }, y);
    const strap = this.mesh(new THREE.TorusGeometry(.42, .025, 5, 20), this.world.iron, tree.x, y - .25, tree.z); strap.rotation.x = Math.PI / 2;
  }

  addCaves() {
    const rng = this.rng, stalactites = [], roots = [], outerRocks = [];
    for (const cave of this.terrain.caves) {
      const width = cave.maxX - cave.minX, depth = cave.maxZ - cave.minZ;
      const roofMaterial = (cave.type === 'cave-rock' ? this.rock : this.earth).clone();
      roofMaterial.side = THREE.DoubleSide; this.materials.push(roofMaterial);
      const shell = createForestCaveShell(this.terrain, cave);
      for (const [name, geometry] of Object.entries(shell)) {
        this.mesh(colorize(geometry, name === 'vault' ? 0x9e9b90 : 0xb3b0a2), roofMaterial).name = `${cave.name} · ${name}`;
      }

      // Boulders give the roof an irregular profile and bury the cave in the hillside.
      for (let x = cave.minX; x <= cave.maxX + .1; x += 2.5) for (let z = cave.minZ; z <= cave.maxZ + .1; z += 2.7) {
        const middle = Math.sin((x - cave.minX) / width * Math.PI) * Math.sin((z - cave.minZ) / depth * Math.PI);
        outerRocks.push({ x: x + (rng() - .5) * .3, y: getCaveRoofTop(this.terrain, cave, x, z) + .05, z, sx: 1.65, sy: .55 + middle * .35, sz: 1.65, angle: rng() * 6.28, tint: .72 + rng() * .2 });
      }
      for (const cell of cave.cells) {
        const x = cell.x * CELL, z = cell.z * CELL;
        if (cave.type === 'cave-rock') {
          const count = rng() < .2 ? 0 : 1 + Math.floor(rng() * 5);
          const clusterX = x + (rng() - .5) * 1.4, clusterZ = z + (rng() - .5) * 1.4;
          for (let i = 0; i < count; i++) {
            const px = clusterX + (rng() - .5) * 1.6, pz = clusterZ + (rng() - .5) * 1.6, length = .3 + Math.pow(rng(), .7) * 1.35;
            stalactites.push({ x: px, y: getCaveRoofHeight(this.terrain, cave, px, pz) - length / 2 + .06, z: pz, sx: .15 + rng() * .24, sy: length, sz: .14 + rng() * .22, angle: rng() * 6.28, tint: .72 + rng() * .25 });
          }
        } else {
          for (let i = 0; i < 2; i++) {
            const px = x + (rng() - .5) * 2.5, pz = z + (rng() - .5) * 2.5, cy = getCaveRoofHeight(this.terrain, cave, px, pz);
            const points = [new THREE.Vector3(px - .4, cy + .04, pz), new THREE.Vector3(px, cy - .1, pz + .05), new THREE.Vector3(px + .12, cy - .55 - rng() * .45, pz + .13), new THREE.Vector3(px + .02, cy - 1.2, pz + .26)];
            roots.push(taperedRoot(points, .075 + rng() * .06));
            const fork = points[2].clone();
            roots.push(taperedRoot([fork, fork.clone().add(new THREE.Vector3(.23, -.15, .13)), fork.clone().add(new THREE.Vector3(.31, -.48, .2))], .033));
            // A gnarled horizontal parent root makes the fine hanging ends read
            // as exposed roots belonging to the forest above the earth roof.
            roots.push(taperedRoot([points[0].clone().add(new THREE.Vector3(-.8, .06, .08)), points[0], points[1].clone().add(new THREE.Vector3(.45, .07, -.11))], .12));
          }
        }
      }
      for (const mouth of cave.type === 'cave-rock' ? cave.mouths : []) {
        const x = mouth.x, z = mouth.z, y = getTerrainHeight(this.terrain, x, z);
        // Natural ceiling teeth are short enough to preserve at least 2.8 m of clearance.
        for (let i = 0; i < 6; i++) {
          const pz = z + (rng() - .5) * depth * .82, length = .3 + rng() * .85;
          stalactites.push({ x, y: getCaveRoofHeight(this.terrain, cave, x, pz) - length / 2 + .05, z: pz, sx: .28, sy: length, sz: .28, tint: .78 });
        }
      }
    }
    const stalactite = new THREE.CylinderGeometry(1, 0, 1, 18, 16);
    const sp = stalactite.attributes.position, suv = stalactite.attributes.uv;
    for (let i = 0; i < sp.count; i++) {
      const y = sp.getY(i), t = y + .5, a = Math.atan2(sp.getZ(i), sp.getX(i));
      // Calcite flows from a swollen shoulder into a long, uneven needle.
      // Curved centres and several shallow mineral ribs avoid geometric cones.
      const radius = (Math.hypot(sp.getX(i), sp.getZ(i)) < .00001 ? 0 : Math.pow(t, 1.75)) * (1 + .15 * Math.cos(a * 5 + t * 4) + .06 * Math.sin(a * 9 - t * 6));
      const bendX = .16 * Math.sin((1 - t) * 2.8), bendZ = .1 * Math.sin((1 - t) * 3.9);
      sp.setXYZ(i, Math.cos(a) * radius + bendX, y, Math.sin(a) * radius + bendZ);
      suv.setXY(i, suv.getX(i), t * 1.4);
    }
    stalactite.computeVertexNormals(); colorize(stalactite);
    this.batch(stalactite, this.rock, stalactites, 'Tropfsteine');
    this.batch(createForestCrag(), this.rock, outerRocks, 'Felsdächer');
    if (roots.length) { const merged = mergeGeometries(roots); roots.forEach(g => g.dispose()); this.mesh(merged, this.bark).name = 'Freigelegte Wurzeln'; }
  }

  addAtmosphere() {
    const rng = this.rng, extent = this.maze.size * CELL, count = Math.min(650, this.maze.size * 16);
    const positions = new Float32Array(count * 3), colors = new Float32Array(count * 3);
    for (let i = 0; i < count; i++) {
      const x = rng() * extent, z = rng() * extent;
      positions.set([x, getTerrainHeight(this.terrain, x, z) + .5 + rng() * 3.6, z], i * 3);
      const c = new THREE.Color(i % 9 === 0 ? 0xc8d890 : 0x7faaa0); c.toArray(colors, i * 3);
    }
    const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3)); geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    const material = new THREE.PointsMaterial({ map: this.world.glowMap, color: 0xafcbc2, vertexColors: true, size: .07, transparent: true, opacity: .44, depthWrite: false, blending: THREE.AdditiveBlending });
    this.materials.push(material); this.motes = new THREE.Points(geometry, material); this.root.add(this.motes);
    const moonMaterial = new THREE.MeshBasicMaterial({ color: 0xbdcfcd, fog: false }); this.materials.push(moonMaterial);
    this.moonDisc = this.mesh(new THREE.SphereGeometry(1.6, 24, 12), moonMaterial); this.moonDisc.castShadow = false;
  }

  update(dt, player, time) {
    this.motes.position.y = Math.sin(time * .17) * .06;
    this.moonDisc.position.set(player.x - 50, player.y + 52, player.z - 68);

  }

  dispose() { this.materials.forEach(material => material.dispose()); }
}
