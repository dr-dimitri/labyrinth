import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { createRng, walkable } from './maze.js';
import { meshIntersectsOpening } from './vertical-architecture.js';
import { poseWeaponToward, readMuzzleShot } from './weapon-aim.js';
import { ForestElf } from './forest-creatures.js';
import { getTerrainHeight } from './forest-world.js';

const CELL = 3.6;
const Y = new THREE.Vector3(0, 1, 0);
const SIDE = [{ x: 1, z: 0 }, { x: -1, z: 0 }, { x: 0, z: 1 }, { x: 0, z: -1 }];
const vector = new THREE.Vector3();
export const BIOME_LOOKS = {
  catacombs: { wall: 0xffffff, floor: 0xffffff, wallHeight: 4.1, fog: 0x131b1c, sky: 0xb9c9d5, ambient: .6, moon: .35, environment: .45, fogDensity: .038 },
  ruins: { wall: 0xa2b992, floor: 0xa0ad86, wallHeight: 3.4, fog: 0x23362e, sky: 0xc3e0c5, ambient: 1.1, moon: 1.6, environment: .85, fogDensity: .025 },
  forest: { wall: 0x919782, floor: 0x97947e, wallHeight: 4.1, fog: 0x111c1c, sky: 0xa1bbce, ambient: .64, moon: .72, environment: .35, fogDensity: .018 },
  mine: { wall: 0x857563, floor: 0xa99a83, wallHeight: 4.1, fog: 0x201d19, sky: 0xd5b68c, ambient: .55, moon: .2, environment: .35, fogDensity: .045 },
};

/** Scene decoration owns its geometry and materials, while sharing source scans. */
export class ExpeditionVisuals {
  constructor(world, simulation) {
    this.world = world; this.biome = simulation.config.biome; this.terrain = simulation.terrain;
    this.level = simulation.player.level || 0; this.baseY = world.floorY || 0;
    this.root = new THREE.Group(); this.root.name = 'Expedition'; world.world.add(this.root);
    this.geometries = new Set(); this.materials = new Set(); this.textures = new Set();
    this.rooms = new Map(); this.objectives = new Map(); this.chests = new Map(); this.hazards = new Map();
    this.dynamic = new Map(); this.weapons = []; this.allies = new Map();
    this.metal = this.material({ color: 0x3a4042, metalness: .85, roughness: .32 });
    this.brass = this.material({ color: 0xb1a16c, metalness: .75, roughness: .4 });
    this.wood = this.material({ color: 0x3d2b20, roughness: .92 });
    this.paper = this.material({ color: 0xb5a783, roughness: .94 });
    this.leaf = this.material({ color: 0x384c25, roughness: .93, side: THREE.DoubleSide });
    this.bark = this.material({ color: 0x41472a, roughness: 1 });
    this.cyan = this.material({ color: 0x84efed, emissive: 0x44cacc, emissiveIntensity: 2, roughness: .3 });
    this.green = this.material({ color: 0xb8e59e, emissive: 0x72bf7d, emissiveIntensity: 1.1 });
    this.red = this.material({ color: 0xd45932, emissive: 0xe5461c, emissiveIntensity: 1.6 });
    this.amber = this.material({ color: 0xffba57, emissive: 0xec8d25, emissiveIntensity: 1.4 });
    this.chalk = this.material({ color: 0xf5ecd2, roughness: 1 });
    this.water = this.material({ color: 0x305d58, metalness: .55, roughness: .18, transparent: true, opacity: .5, depthWrite: false, side: THREE.DoubleSide });
    if (this.biome === 'forest') {
      this.wood = world.assets.forest?.bark || this.wood;
      this.bark = world.assets.forest?.bark || this.bark;
    }
    this.rng = createRng(`${simulation.maze.seed}:expedition-props`);
    const expeditionRoot = this.root;
    this.root = this.group();
    this.decorateBiome(simulation);
    this.batchStatic(this.root);
    this.root = expeditionRoot;
    this.shafts = (simulation.ladders || []).filter(ladder => ladder.fromLevel === this.level || ladder.toLevel === this.level);
    for (const room of this.onLevel(simulation.rooms)) this.addRoom(room);
    for (const objective of this.onLevel(simulation.objectives)) if (objective.type === 'mechanism') this.addMechanism(objective);
    for (const chest of this.onLevel(simulation.treasures)) this.addChest(chest);
    for (const hazard of this.onLevel(simulation.hazards)) this.addHazard(hazard);
    if (simulation.rescue) this.explorer = this.addExplorer();
    this.syncAllies(0, simulation);
    this.makeFlood(simulation.maze);
    this.addWeapons(simulation.inventory || []);
    this.flareLights = Array.from({ length: 2 }, () => {
      const light = new THREE.PointLight(0xff7950, 0, 9, 2); this.root.add(light); return light;
    });
    this.blastLight = new THREE.PointLight(0xffad56, 0, 11, 2); this.root.add(this.blastLight);
  }

  onLevel(items) { return (items || []).filter(item => (item.level || 0) === this.level); }

  material(parameters) { const material = new THREE.MeshStandardMaterial(parameters); this.materials.add(material); return material; }
  group(x = 0, y = 0, z = 0, parent = this.root) {
    const group = new THREE.Group(); group.position.set(x, y, z); parent.add(group); return group;
  }
  mesh(geometry, material, x = 0, y = 0, z = 0, parent = this.root) {
    this.geometries.add(geometry);
    const mesh = this.world.mesh(geometry, material, x, y, z, parent); return mesh;
  }
  box(width, height, depth, material, x = 0, y = 0, z = 0, parent = this.root) {
    return this.mesh(new RoundedBoxGeometry(width, height, depth, 1, Math.min(.025, width / 5, height / 5, depth / 5)), material, x, y, z, parent);
  }
  tube(points, radius, material, parent = this.root) {
    const curve = new THREE.CatmullRomCurve3(points.map(p => new THREE.Vector3(...p)));
    return this.mesh(new THREE.TubeGeometry(curve, points.length * 3, radius, 5, false), material, 0, 0, 0, parent);
  }
  ring(radius, material, x, y, z, parent = this.root, thickness = .025) {
    const mesh = this.mesh(new THREE.TorusGeometry(radius, thickness, 5, 48), material, x, y, z, parent);
    mesh.rotation.x = Math.PI / 2; return mesh;
  }
  sprite(color, scale, parent, opacity = .5) {
    const material = new THREE.SpriteMaterial({ map: this.world.glowMap, color, transparent: true, opacity, depthWrite: false, blending: THREE.AdditiveBlending });
    this.materials.add(material);
    const sprite = new THREE.Sprite(material); sprite.scale.setScalar(scale); parent.add(sprite); return sprite;
  }
  label(text, x, y, z, parent = this.root, color = '#c8dabd') {
    const canvas = document.createElement('canvas'); canvas.width = 768; canvas.height = 128;
    const ctx = canvas.getContext('2d'); ctx.clearRect(0, 0, 768, 128);
    ctx.font = '500 36px Georgia'; ctx.textAlign = 'center'; ctx.fillStyle = color; ctx.fillText(text.toUpperCase(), 384, 70);
    ctx.strokeStyle = color; ctx.globalAlpha = .5; ctx.beginPath(); ctx.moveTo(200, 92); ctx.lineTo(568, 92); ctx.stroke();
    const texture = new THREE.CanvasTexture(canvas); texture.colorSpace = THREE.SRGBColorSpace; this.textures.add(texture);
    const material = new THREE.SpriteMaterial({ map: texture, transparent: true, depthWrite: false, opacity: .85 }); this.materials.add(material);
    const sprite = new THREE.Sprite(material); sprite.position.set(x, y, z); sprite.scale.set(4.8, .8, 1); parent.add(sprite); return sprite;
  }

  batchStatic(group) {
    group.updateWorldMatrix(true, true);
    const inverse = group.matrixWorld.clone().invert(), batches = new Map(), removed = new Set();
    group.traverse(object => {
      if (!object.isMesh || object.userData.persistentAsset || !this.geometries.has(object.geometry)) return;
      const geometry = object.geometry.index ? object.geometry.toNonIndexed() : object.geometry.clone();
      geometry.applyMatrix4(inverse.clone().multiply(object.matrixWorld));
      if (!batches.has(object.material)) batches.set(object.material, []);
      batches.get(object.material).push(geometry); removed.add(object);
    });
    for (const object of removed) {
      if (this.geometries.delete(object.geometry)) object.geometry.dispose();
      object.removeFromParent();
    }
    for (const [material, geometries] of batches) {
      const merged = mergeGeometries(geometries, false);
      geometries.forEach(geometry => geometry.dispose());
      if (merged) this.mesh(merged, material, 0, 0, 0, group);
    }
  }

  decorateBiome(simulation) {
    const maze = simulation.maze, biome = simulation.config.biome;
    if (biome === 'forest') return;
    const ladderCells = new Set((simulation.ladders || []).filter(ladder => ladder.fromLevel === this.level || ladder.toLevel === this.level)
      .map(ladder => `${Math.round(ladder.x / CELL)},${Math.round(ladder.z / CELL)}`));
    let count = 0;
    for (let z = 1; z < maze.size - 1; z++) for (let x = 1; x < maze.size - 1; x++) {
      if (!walkable(maze, x, z)) continue;
      const side = SIDE.find(d => !walkable(maze, x + d.x, z + d.z));
      if (biome === 'ruins' && side && (x * 13 + z * 7) % 4 === 0 && count < 65) {
        const group = this.group(x * CELL + side.x * 1.61, 0, z * CELL + side.z * 1.61);
        group.rotation.y = Math.atan2(side.x, side.z);
        const points = [[-.45, 3.6, 0], [.2, 2.8, -.04], [-.12, 1.9, .03], [.2, 1, -.06], [-.2, .1, -.12]];
        this.tube(points, .035, this.bark, group);
        for (let i = 0; i < 9; i++) {
          const y = .35 + i * .36, leaf = this.mesh(new THREE.SphereGeometry(.16, 5, 3), this.leaf, Math.sin(i * 1.8) * .27, y, -.05, group);
          leaf.scale.set(1.4, .45, .12); leaf.rotation.z = i * 1.7;
        }
        count++;
      }
      if (biome === 'mine' && side && !ladderCells.has(`${x},${z}`) && (x + z) % 4 === 0 && count < 50) {
        const northSouth = walkable(maze, x, z - 1) && walkable(maze, x, z + 1);
        const group = this.group(x * CELL, 0, z * CELL); group.rotation.y = northSouth ? 0 : Math.PI / 2;
        for (const sign of [-1, 1]) {
          this.box(.15, 3.45, .18, this.metal, sign * 1.52, 1.73, 0, group);
          const brace = this.box(.12, .65, .13, this.brass, sign * 1.32, 3.2, 0, group); brace.rotation.z = sign * -.6;
        }
        this.box(3.2, .2, .24, this.metal, 0, 3.47, 0, group);
        this.box(.28, .18, .16, this.amber, 0, 3.28, 0, group);
        for (const sign of [-1, 1]) this.box(.055, .07, CELL, this.metal, sign * .48, .055, 0, group);
        for (const dz of [-1.3, -.65, 0, .65, 1.3]) this.box(1.32, .07, .16, this.wood, 0, .023, dz, group);
        if (count % 3 === 0) this.world.addProp(this.world.assets.rock, x * CELL + side.x * 2.9, -.1, z * CELL + side.z * 2.9, 2.9, this.rng() * 6.28, this.root);
        count++;
      }
    }
    if (biome === 'ruins' && this.level === (simulation.levels?.length || 1) - 1) {
      const moon = this.mesh(new THREE.SphereGeometry(2.8, 20, 12), this.paper, maze.size * CELL * .55, 35, -maze.size * CELL * .25);
      moon.material = this.material({ color: 0xcbd4ba, emissive: 0xbbc8ad, emissiveIntensity: 1.1 }); moon.castShadow = false;
    }
  }

  addRoom(room) {
    const group = this.group(room.x, (room.y ?? this.baseY) - this.baseY, room.z), state = { group };
    if (this.biome === 'forest') { this.addForestRoom(room, state); return; }
    this.rooms.set(room.id, state);
    const radius = Math.min(room.radius || 3.4, 3.5);
    this.label(room.name || { sanctuary: 'Zuflucht', library: 'Bibliothek', flooded: 'Zisterne', treasury: 'Schatzkammer' }[room.type], 0, 3, 0, group);
    if (room.type === 'sanctuary') {
      this.ring(radius * .85, this.green, 0, .045, 0, group);
      this.ring(radius * .85 - .12, this.brass, 0, .035, 0, group, .014);
      for (const angle of [0, Math.PI / 2, Math.PI, -Math.PI / 2]) {
        const x = Math.sin(angle) * radius * .75, z = Math.cos(angle) * radius * .75;
        this.box(.22, .38, .22, this.paper, x, .19, z, group);
        this.mesh(new THREE.SphereGeometry(.045, 8, 5), this.green, x, .43, z, group);
      }
      const light = new THREE.PointLight(0xb0e6af, 20, 11, 2); light.position.y = 2.5; group.add(light);
      this.box(1.7, .15, .45, this.wood, 0, .57, radius * .8, group);
      for (const x of [-.65, .65]) this.box(.18, .5, .38, this.metal, x, .25, radius * .8, group);
    } else if (room.type === 'landing') {
      this.ring(radius * .84, this.brass, 0, .035, 0, group, .012);
      for (const side of [-1, 1]) {
        this.box(.5, .32, .55, this.world.assets.plinth, side * radius * .8, .16, -radius * .8, group);
        this.box(.12, 1.5, .12, this.metal, side * radius * .8, 1.02, -radius * .8, group);
        this.box(.18, .12, .18, this.amber, side * radius * .8, 1.8, -radius * .8, group);
      }
    } else if (room.type === 'library') {
      for (const side of [-1, 1]) {
        const shelf = this.group(side * radius * .82, 0, 0, group);
        this.box(.32, 2.5, 2.65, this.wood, 0, 1.25, 0, shelf);
        for (const y of [.45, 1.15, 1.85, 2.5]) this.box(.62, .08, 2.65, this.brass, -side * .13, y, 0, shelf);
        for (let i = 0; i < 27; i++) {
          const color = [0x603c30, 0x2c4742, 0x655534][i % 3];
          if (!this.bookMaterials) this.bookMaterials = new Map();
          if (!this.bookMaterials.has(color)) this.bookMaterials.set(color, this.material({ color, roughness: .9 }));
          this.box(.34, .35 + this.rng() * .2, .14, this.bookMaterials.get(color), -side * .24, .72 + Math.floor(i / 9) * .7, -1.12 + (i % 9) * .27, shelf);
        }
        this.batchStatic(shelf);
      }
      this.box(1.8, .16, 1.1, this.wood, 0, .92, 0, group);
      for (const x of [-.73, .73]) this.box(.13, .85, .65, this.brass, x, .43, 0, group);
      for (let i = 0; i < 3; i++) {
        const rune = this.mesh(new THREE.OctahedronGeometry(.14), this.cyan, (i - 1) * .48, 1.17, 0, group);
        rune.rotation.z = i * .8;
      }
      state.indicator = this.ring(.4, this.cyan, 0, 1.04, 0, group, .013);
    } else if (room.type === 'flooded') {
      state.water = this.group(0, .25, 0, group);
      for (const cell of room.cells || []) {
        const plane = this.mesh(new THREE.PlaneGeometry(CELL, CELL), this.water, cell.x * CELL - room.x, 0, cell.z * CELL - room.z, state.water);
        plane.rotation.x = -Math.PI / 2; plane.castShadow = false;
      }
      const valve = this.group(0, .7, 0, group);
      this.mesh(new THREE.CylinderGeometry(.16, .2, .8, 12), this.metal, 0, -.3, 0, valve);
      const wheel = this.mesh(new THREE.TorusGeometry(.4, .06, 8, 24), this.red, 0, .24, 0, valve); wheel.rotation.x = -.45;
      for (const angle of [0, Math.PI / 3, Math.PI * 2 / 3]) {
        const spoke = this.box(.72, .04, .05, this.metal, 0, .24, 0, valve); spoke.rotation.z = angle;
      }
      state.valve = valve;
      this.tube([[-radius, .2, -radius * .8], [-radius, 1.1, -radius * .8], [radius, 1.1, -radius * .8]], .09, this.metal, group);
    } else if (room.type === 'treasury') {
      for (const sign of [-1, 1]) {
        this.box(.6, .32, .65, this.world.assets.plinth, sign * radius * .75, .16, -.8, group);
        this.mesh(new THREE.CylinderGeometry(.24, .16, .48, 16), this.brass, sign * radius * .75, .55, -.8, group);
        for (let i = 0; i < 4; i++) this.ring(.23 - i * .015, this.brass, sign * radius * .75, .34 + i * .1, -.8, group, .016);
      }
      this.ring(radius * .85, this.amber, 0, .035, 0, group, .012);
    }
    this.clearShaftDecoration(group);
  }

  addForestRoom(room, state) {
    const group = state.group, radius = Math.min(room.radius || 3.4, 3.5);
    this.rooms.set(room.id, state);
    const stone = this.world.assets.forest?.rock || this.world.assets.plinth;
    const ground = (x, z) => getTerrainHeight(this.terrain, room.x + x, room.z + z) - (room.y ?? 0);
    const rock = (x, z, size = .35) => {
      const mesh = this.mesh(new THREE.DodecahedronGeometry(size, 1), stone, x, ground(x, z) + size * .3, z, group);
      mesh.scale.set(1.35, .7, .85); mesh.rotation.y = this.rng() * Math.PI; return mesh;
    };
    // The cave itself is the landmark. Large floating room labels obscure its mouths.
    if (room.type.startsWith('cave-')) return;
    state.label = this.label(room.name || 'Waldlichtung', 0, 2.7, 0, group, '#b5c6ac'); state.label.scale.set(2.2, .365, 1);
    if (room.type === 'sanctuary' || room.type === 'landing') {
      for (let i = 0; i < 14; i++) {
        const angle = i * Math.PI / 7, x = Math.cos(angle) * radius * .86, z = Math.sin(angle) * radius * .86;
        rock(x, z, .11 + this.rng() * .05);
      }
      // Fallen timber, a folded bedroll and suspended leafy canvas identify a lived-in camp.
      const benchZ = -radius * .65;
      this.tube([[-1.05, ground(-1.05, benchZ) + .23, benchZ], [0, ground(0, benchZ) + .24, benchZ], [1.1, ground(1.1, benchZ) + .2, benchZ]], .19, this.bark, group);
      const roll = this.mesh(new THREE.CylinderGeometry(.14, .14, .78, 16), this.leaf, -1.65, ground(-1.65, -.3) + .15, -.3, group); roll.rotation.z = Math.PI / 2;
      if (!this.campCloth) {
        const canvas = document.createElement('canvas'); canvas.width = canvas.height = 256;
        const context = canvas.getContext('2d'); context.fillStyle = '#3b4436'; context.fillRect(0, 0, 256, 256);
        for (let i = 0; i < 256; i += 2) {
          context.strokeStyle = i % 4 ? '#424a3d' : '#343d30'; context.lineWidth = 1;
          context.beginPath(); context.moveTo(i, 0); context.lineTo(i, 256); context.stroke();
          context.beginPath(); context.moveTo(0, i); context.lineTo(256, i); context.stroke();
        }
        const map = new THREE.CanvasTexture(canvas); map.colorSpace = THREE.SRGBColorSpace;
        map.wrapS = map.wrapT = THREE.RepeatWrapping; map.repeat.set(3, 2); this.textures.add(map);
        this.campCloth = this.material({ map, bumpMap: map, bumpScale: .008, color: 0xb5bca8, roughness: 1, side: THREE.DoubleSide });
      }
      // A sagging, creased tarpaulin tied to timber: an open lean-to, with no solid pyramid.
      const canopy = new THREE.PlaneGeometry(3.15, 1.45, 24, 12);
      const vertices = canopy.attributes.position;
      for (let i = 0; i < vertices.count; i++) {
        const u = (vertices.getX(i) + 1.575) / 3.15, v = (vertices.getY(i) + .725) / 1.45;
        const x = -1.85 + u * 3.15, z = -1.95 - v * 1.45;
        const sag = -.26 * Math.sin(u * Math.PI) * Math.sin(v * Math.PI);
        const fold = Math.sin(u * 37 + v * 1.4) * .045 * Math.sin(v * Math.PI);
        vertices.setXYZ(i, x, ground(x, z) + 1.62 - v * 1.15 + sag + fold, z);
      }
      canopy.computeVertexNormals(); this.mesh(canopy, this.campCloth, 0, 0, 0, group);
      for (const x of [-1.85, 1.3]) {
        this.tube([[x, ground(x, -1.95), -1.95], [x + .04, ground(x, -1.95) + 1.7, -1.95]], .038, this.bark, group);
        this.tube([[x, ground(x, -1.95) + 1.63, -1.95], [x * 1.13, ground(x * 1.13, -.95) + .08, -.95]], .008, this.wood, group);
      }
      const campLight = new THREE.PointLight(0xccbc88, 1.8, 6.5, 2); campLight.position.set(-1, 1.65, -1.5); group.add(campLight);
    } else if (room.type === 'library') {
      rock(0, 0, .72);
      for (const side of [-1, 1]) {
        this.tube([[side * 1.35, ground(side * 1.35, 0), 0], [side * .82, .55, -.14], [side * .9, 1.55, -.1], [side * .33, 2.05, -.2]], .105, this.bark, group);
        this.tube([[side * 1.1, ground(side * 1.1, .7), .7], [side * .62, .1, .4], [side * .3, .55, .1]], .06, this.bark, group);
      }
      for (let i = 0; i < 3; i++) {
        const rune = this.mesh(new THREE.OctahedronGeometry(.115, 1), this.cyan, (i - 1) * .31, .83, 0, group); rune.rotation.z = i * .72;
      }
      state.indicator = this.ring(.4, this.cyan, 0, .58, 0, group, .014);
    } else if (room.type === 'flooded') {
      state.water = this.group(0, .25, 0, group);
      const spring = this.mesh(new THREE.CircleGeometry(radius * .77, 48), this.water, 0, 0, 0, state.water); spring.rotation.x = -Math.PI / 2;
      for (let i = 0; i < 12; i++) rock(Math.sin(i * Math.PI / 6) * radius * .8, Math.cos(i * Math.PI / 6) * radius * .8, .19 + this.rng() * .13);
      const valve = this.group(0, .7, 0, group); state.valve = valve;
      this.mesh(new THREE.TorusGeometry(.33, .049, 8, 32), this.bark, 0, .12, 0, valve).rotation.x = -.4;
      this.tube([[0, -.7, 0], [-.09, -.16, .05], [0, .12, 0]], .07, this.bark, valve);
      this.mesh(new THREE.OctahedronGeometry(.06), this.cyan, 0, .12, .04, valve);
    } else if (room.type === 'treasury') {
      for (const side of [-1, 1]) { rock(side * 1.5, -.8, .4); rock(side * 1.75, .7, .25); }
      this.tube([[-1.6, .03, -1.3], [-.7, .13, -1.15], [.4, .16, -1.2], [1.6, .08, -1.45]], .13, this.bark, group);
    }
    if (['sanctuary', 'landing', 'treasury'].includes(room.type)) this.batchStatic(group);
  }

  syncAllies(dt, simulation) {
    const allies = this.onLevel(simulation.allies).filter(ally => ally.type === 'elf');
    const ids = new Set(allies.map(ally => ally.id));
    for (const [id, elf] of this.allies) if (!ids.has(id)) { elf.dispose(); this.allies.delete(id); }
    for (const ally of allies) {
      let elf = this.allies.get(ally.id);
      if (!elf) {
        elf = new ForestElf(this.world); this.root.add(elf.root); this.allies.set(ally.id, elf);
        elf.label = this.label(ally.label || 'Elfenhüterin · Munition', 0, 2.04, 0, elf.root, '#b9d6a0'); elf.label.scale.set(1.7, .28, 1);
      }
      elf.update(dt, ally, simulation.player);
      if (elf.label) {
        const distance = Math.hypot(ally.x - simulation.player.x, ally.z - simulation.player.z);
        // Up close the interaction panel names the elf; keep the world label from filling the view.
        elf.label.visible = distance > 2.5 && distance < 5;
        elf.label.material.opacity = THREE.MathUtils.clamp(Math.min((5 - distance) / 1.5, (distance - 2.5) / .75), 0, .8);
      }
    }
  }

  clearShaftDecoration(group) {
    if (!this.shafts?.length) return;
    group.updateWorldMatrix(true, true);
    const openings = this.shafts.map(ladder => new THREE.Box3(
      new THREE.Vector3(ladder.x - 1.1, this.baseY - .05, ladder.z - 1.1),
      new THREE.Vector3(ladder.x + 1.1, this.baseY + 5, ladder.z + 1.1)));
    const removed = [];
    group.traverse(object => {
      if (!object.isMesh || !this.geometries.has(object.geometry)) return;
      // Shelves and landing ornaments must never float into the open shaft.
      if (openings.some(opening => meshIntersectsOpening(object, opening))) removed.push(object);
    });
    removed.forEach(object => this.destroyGroup(object));
  }

  addMechanism(objective) {
    const group = this.group(objective.x, (objective.y ?? this.baseY) - this.baseY, objective.z);
    if (this.biome === 'forest') {
      const stone = this.world.assets.forest?.rock || this.world.assets.plinth;
      const foundation = this.mesh(new THREE.DodecahedronGeometry(.62, 2), stone, 0, .28, 0, group); foundation.scale.set(1.1, .55, 1);
      this.tube([[-.46, .06, .3], [-.38, .56, .18], [-.14, .76, .09], [.12, 1.1, 0]], .075, this.bark, group);
      this.tube([[.44, .05, -.26], [.25, .62, -.22], [.12, .95, 0]], .065, this.bark, group);
      const cog = this.group(0, 1.08, 0, group);
      this.mesh(new THREE.TorusGeometry(.22, .034, 8, 28), this.brass, 0, 0, 0, cog);
      const lamp = this.mesh(new THREE.OctahedronGeometry(.1, 1), this.red, 0, 1.08, 0, group);
      this.objectives.set(objective.id, { group, cog, lamp }); return;
    }
    this.box(1.2, .24, 1.1, this.world.assets.plinth, 0, .12, 0, group);
    this.box(.65, .95, .45, this.metal, 0, .66, 0, group);
    const cog = this.group(0, 1.15, .3, group);
    this.mesh(new THREE.TorusGeometry(.38, .065, 8, 24), this.brass, 0, 0, 0, cog);
    for (let i = 0; i < 10; i++) {
      const angle = i * Math.PI / 5;
      const tooth = this.box(.12, .15, .12, this.brass, Math.sin(angle) * .4, Math.cos(angle) * .4, 0, cog); tooth.rotation.z = -angle;
    }
    this.mesh(new THREE.CylinderGeometry(.12, .12, .45, 12), this.metal, 0, 1.4, 0, group);
    const lamp = this.mesh(new THREE.SphereGeometry(.075, 10, 6), this.red, 0, 1.7, 0, group);
    this.objectives.set(objective.id, { group, cog, lamp });
  }

  addChest(chest) {
    const group = this.group(chest.x, (chest.y ?? this.baseY) - this.baseY, chest.z);
    this.box(.94, .5, .62, this.wood, 0, .3, 0, group);
    const lid = this.group(0, .53, -.31, group);
    this.box(.99, .17, .65, this.wood, 0, .06, .3, lid);
    for (const sign of [-1, 1]) {
      this.box(.06, .54, .65, this.brass, sign * .3, .3, 0, group);
      this.box(.065, .2, .67, this.brass, sign * .3, .06, .3, lid);
    }
    this.box(.12, .16, .04, this.brass, 0, .5, .34, group);
    const glow = this.sprite(0xffc965, 1.5, group, .25); glow.position.y = .55;
    const warning = this.ring(.8, this.amber, 0, .025, 0, group, .018); warning.visible = !!chest.trapped;
    this.chests.set(chest.id, { group, lid, glow, warning });
  }

  addHazard(hazard) {
    const group = this.group(hazard.x, (hazard.y ?? this.baseY) - this.baseY, hazard.z);
    const radius = hazard.radius || .9;
    const warning = this.ring(radius, this.amber, 0, .03, 0, group, .015);
    const danger = this.group(0, 0, 0, group);
    if (hazard.type === 'spikes') {
      for (let i = 0; i < 9; i++) {
        const spike = this.mesh(new THREE.ConeGeometry(.075, .55, 6), this.metal, ((i % 3) - 1) * radius * .55, .15, (Math.floor(i / 3) - 1) * radius * .55, danger);
        spike.rotation.z = (i % 2 ? 1 : -1) * .1;
      }
    } else if (hazard.type === 'thorns') {
      for (let i = 0; i < 4; i++) {
        const thorn = this.tube([[-radius, .08, (i - 1.5) * .35], [0, .35, (i - 1.5) * .35], [radius, .1, (i - 1.5) * .35]], .038, this.bark, danger);
        thorn.rotation.y = i * .42;
      }
    } else {
      for (let i = 0; i < 4; i++) {
        const cloud = this.sprite(0x90b547, radius * 2.7, danger, .11);
        cloud.position.set(Math.sin(i * 2) * .6, .4 + i * .28, Math.cos(i * 2) * .6);
      }
    }
    this.hazards.set(hazard.id, { group, danger, warning });
  }

  addExplorer() {
    const group = this.group();
    const cloth = this.material({ color: 0x263b31, roughness: 1 });
    const skin = this.material({ color: 0x796455, roughness: 1 });
    const coat = this.mesh(new THREE.CapsuleGeometry(.22, .36, 6, 12), cloth, 0, 1.1, 0, group);
    coat.scale.z = .75;
    const head = this.mesh(new THREE.SphereGeometry(.155, 16, 12), skin, 0, 1.64, .015, group); head.scale.set(1, 1.18, .85);
    this.mesh(new THREE.CylinderGeometry(.065, .065, .16, 10), skin, 0, 1.47, 0, group);
    this.mesh(new THREE.SphereGeometry(.16, 16, 8, 0, Math.PI * 2, 0, Math.PI / 2), this.wood, 0, 1.68, .01, group);
    this.box(.36, .43, .22, this.wood, 0, 1.12, -.23, group);
    this.box(.42, .055, .28, this.wood, 0, .89, 0, group);
    for (const side of [-1, 1]) {
      this.box(.044, .5, .028, this.wood, side * .13, 1.12, .157, group);
      const eye = this.mesh(new THREE.SphereGeometry(.038, 10, 8), this.metal, side * .065, 1.67, .14, group); eye.scale.z = .25;
    }
    this.mesh(new THREE.SphereGeometry(.025, 10, 8), skin, 0, 1.625, .15, group);
    const legs = [], arms = [];
    for (const side of [-1, 1]) {
      legs.push(this.mesh(new THREE.CapsuleGeometry(.085, .5, 5, 10), cloth, side * .12, .42, 0, group));
      this.box(.16, .15, .26, this.wood, side * .12, .08, .04, group);
      const arm = this.mesh(new THREE.CapsuleGeometry(.068, .39, 5, 10), cloth, side * .28, 1.1, 0, group); arm.rotation.z = side * .12; arms.push(arm);
      this.mesh(new THREE.SphereGeometry(.065, 10, 8), skin, side * .32, .83, .02, group);
    }
    this.mesh(new THREE.SphereGeometry(.035, 10, 6), this.cyan, 0, 1.78, .14, group);
    const beacon = this.sprite(0x8ae2d5, .35, group, .28); beacon.position.set(0, 1.78, .16);
    this.label('Vermisste Forscherin', 0, 2.1, 0, group).scale.set(2.8, .47, 1);
    return { group, coat, legs, arms };
  }

  makeFlood(maze) {
    const cells = [];
    const openings = new Set((this.shafts || []).filter(ladder => ladder.toLevel === this.level).map(ladder => `${Math.round(ladder.x / CELL)},${Math.round(ladder.z / CELL)}`));
    for (let z = 0; z < maze.size; z++) for (let x = 0; x < maze.size; x++) if (walkable(maze, x, z) && !openings.has(`${x},${z}`)) cells.push({ x, z });
    const geometry = new THREE.PlaneGeometry(CELL, CELL); geometry.rotateX(-Math.PI / 2); this.geometries.add(geometry);
    this.flood = new THREE.InstancedMesh(geometry, this.water, cells.length);
    const dummy = new THREE.Object3D();
    cells.forEach((cell, i) => { dummy.position.set(cell.x * CELL, .18, cell.z * CELL); dummy.updateMatrix(); this.flood.setMatrixAt(i, dummy.matrix); });
    this.flood.visible = false; this.root.add(this.flood);
  }

  addWeapons(inventory) {
    this.weaponRoot = this.group(); this.weaponRoot.name = 'Equipment in hands';
    // Rough, dark coatings keep nearby flashlights from washing out the weapon.
    const gunMetal = this.material({ color: 0x182021, roughness: .85, metalness: .25 });
    const gunBrass = this.material({ color: 0x6b5938, roughness: .8, metalness: .35 });
    inventory.forEach((item, slot) => {
      if (!['machinegun', 'laser', 'rocket'].includes(item.id)) return;
      const group = this.group(slot ? .26 : -.26, -.31, -.74, this.weaponRoot);
      group.scale.setScalar(.8);
      const laser = item.id === 'laser', machinegun = item.id === 'machinegun';
      this.box(laser ? .15 : .21, .17, .42, this.metal, 0, 0, 0, group);
      this.box(.1, .19, .13, this.wood, 0, -.13, .08, group).rotation.x = -.25;
      for (let i = 0; i < 6; i++) this.box(.12, .018, .019, this.brass, 0, .094, -.13 + i * .044, group);
      for (const side of [-1, 1]) {
        this.box(.015, .065, .2, this.wood, side * .11, -.015, -.015, group);
        for (const z of [-.11, .11]) {
          const screw = this.mesh(new THREE.CylinderGeometry(.014, .014, .017, 8), this.brass, side * .12, .025, z, group);
          screw.rotation.z = Math.PI / 2;
        }
      }
      if (machinegun) {
        const barrel = this.mesh(new THREE.CylinderGeometry(.032, .036, .53, 12), this.metal, 0, .02, -.39, group); barrel.rotation.x = Math.PI / 2;
        for (const z of [-.4, -.49, -.58]) {
          const cooling = this.mesh(new THREE.TorusGeometry(.036, .013, 6, 12), this.brass, 0, .02, z, group); cooling.rotation.z = .5;
        }
        this.box(.075, .24, .18, this.metal, 0, -.17, -.04, group).rotation.x = -.18;
        this.box(.07, .055, .17, this.metal, 0, .115, -.03, group);
        this.box(.085, .12, .12, this.wood, 0, -.02, .25, group);
      } else if (laser) {
        const barrel = this.mesh(new THREE.CylinderGeometry(.045, .062, .38, 16), this.metal, 0, 0, -.31, group); barrel.rotation.x = Math.PI / 2;
        const lens = this.mesh(new THREE.CylinderGeometry(.036, .036, .02, 16), this.cyan, 0, 0, -.5, group); lens.rotation.x = Math.PI / 2;
        for (const side of [-1, 1]) this.box(.015, .07, .24, this.cyan, side * .083, 0, -.02, group);
        this.box(.06, .035, .1, this.brass, 0, .11, .05, group);
      } else {
        const tube = this.mesh(new THREE.CylinderGeometry(.115, .115, .67, 16), this.metal, 0, .035, -.19, group); tube.rotation.x = Math.PI / 2;
        const opening = this.mesh(new THREE.CylinderGeometry(.094, .094, .015, 16), this.wood, 0, .035, -.531, group); opening.rotation.x = Math.PI / 2;
        for (const z of [-.42, -.1, .08]) {
          const band = this.mesh(new THREE.TorusGeometry(.116, .016, 6, 16), this.brass, 0, .035, z, group);
          band.rotation.z = .2;
        }
        this.box(.05, .065, .09, this.amber, 0, .18, -.15, group);
      }
      group.traverse(object => {
        if (!object.isMesh) return;
        object.castShadow = false;
        if (object.material === this.metal) object.material = gunMetal;
        if (object.material === this.brass) object.material = gunBrass;
      });
      this.batchStatic(group);
      const muzzle = new THREE.Object3D(); muzzle.name = `${item.id} muzzle · slot ${slot + 1}`;
      muzzle.position.set(0, machinegun ? .02 : laser ? 0 : .035, machinegun ? -.655 : laser ? -.51 : -.5385);
      group.add(muzzle);
      const flash = this.sprite(laser ? 0x74faff : 0xffd697, laser ? .23 : machinegun ? .36 : .48, muzzle, .9);
      flash.visible = false;
      group.userData.muzzle = muzzle;
      this.weapons.push({ group, muzzle, flash, id: item.id, slot, reload: 0 });
    });
    if (this.weapons.length) {
      // A dedicated view-model pass uses soft lighting instead of receiving the
      // world flashlight at a distance of only a few centimetres.
      this.weaponScene = new THREE.Scene();
      this.weaponScene.environment = this.world.assets.environment;
      this.weaponScene.environmentIntensity = .35;
      this.weaponScene.add(this.weaponRoot);
      this.weaponScene.add(new THREE.HemisphereLight(0xcbd6d1, 0x3b3128, .65));
      const key = new THREE.DirectionalLight(0xffe8bd, 3.1); key.position.set(-3, 4, 1); this.weaponScene.add(key);
      const rim = new THREE.DirectionalLight(0x9fc9e8, 1.1); rim.position.set(3, 2, -3); this.weaponScene.add(rim);
      this.weaponPass = new RenderPass(this.weaponScene, this.world.camera);
      this.weaponPass.clear = false; this.weaponPass.clearDepth = true;
      // Atmosphere belongs to the world; hands stay crisp in front of its haze.
      const beforeBloom = this.world.atmosphere ? this.world.composer.passes.indexOf(this.world.atmosphere) + 1 : 2;
      this.world.composer.insertPass(this.weaponPass, beforeBloom);
    }
  }

  prepareWeapons(dt, simulation, view, target) {
    this.weaponRoot.visible = !simulation.climbing;
    this.weaponRoot.position.copy(this.world.camera.position); this.weaponRoot.quaternion.copy(this.world.camera.quaternion);
    this.weaponRoot.updateWorldMatrix(true, true);
    const time = simulation.elapsed;
    const bob = view.moving ? Math.sin(time * (view.sprinting ? 15 : 10)) * (view.sprinting ? .017 : .011) : 0;
    this.weapons.forEach(weapon => {
      const reloading = (simulation.inventory?.[weapon.slot]?.reloadRemaining || 0) > 0;
      weapon.reload = THREE.MathUtils.damp(weapon.reload, reloading ? 1 : 0, 10, dt);
      // Once a reload has completed, a shot may fire immediately. Its barrel
      // must already match the aiming solution, without a residual animation.
      if (!reloading) weapon.reload = 0;
      const effect = this.recentWeaponEffect(weapon, simulation);
      const recoil = effect ? (weapon.id === 'machinegun' ? .04 : .025) * Math.max(0, 1 - (effect.age || 0) / .12) : 0;
      poseWeaponToward(weapon, target, { aimX: view.aimX || 0, aimY: view.aimY || 0, bob, recoil, reload: weapon.reload });
    });
  }

  getWeaponShot(slot) {
    const weapon = this.weapons.find(item => item.slot === slot);
    return weapon ? readMuzzleShot(weapon) : null;
  }

  recentWeaponEffect(weapon, simulation) {
    const type = weapon.id === 'machinegun' ? 'bullet' : weapon.id;
    const items = weapon.id === 'rocket' ? simulation.projectiles : simulation.weaponEffects;
    return this.onLevel(items).find(effect => effect.slot === weapon.slot &&
      (effect.type === type || (type === 'bullet' && effect.type === 'machinegun')) && (effect.age || 0) < .12);
  }

  createDynamic(kind, item) {
    const group = this.group();
    if (kind === 'markers') {
      const shaft = this.box(.06, .012, .7, this.chalk, 0, .035, 0, group);
      for (const side of [-1, 1]) { const point = this.box(.055, .012, .35, this.chalk, side * .1, .035, -.25, group); point.rotation.y = side * -.65; }
      group.rotation.y = item.yaw || 0; shaft.castShadow = false;
    } else if (kind === 'flares') {
      this.box(.045, .23, .045, this.red, 0, .12, 0, group).rotation.z = .3;
      const glow = this.sprite(0xff7740, 2.4, group, .65); glow.position.y = .23;
      this.ring(.15, this.amber, 0, .03, 0, group, .012);
    } else if (kind === 'decoys') {
      this.mesh(new THREE.IcosahedronGeometry(.095, 1), this.world.assets.trim, 0, .11, 0, group);
      const ring = this.ring(.4, this.paper, 0, .025, 0, group, .008); group.userData.ring = ring;
    } else if (kind === 'projectiles') {
      this.mesh(new THREE.CylinderGeometry(.055, .055, .4, 10), this.brass, 0, 0, 0, group);
      this.mesh(new THREE.ConeGeometry(.056, .15, 10), this.metal, 0, .27, 0, group);
      const fire = this.sprite(0xffac43, .8, group, .85); fire.position.y = -.28;
      for (const angle of [0, Math.PI / 2, Math.PI, -Math.PI / 2]) {
        const fin = this.box(.02, .13, .16, this.metal, Math.sin(angle) * .045, -.17, Math.cos(angle) * .045, group); fin.rotation.y = angle;
      }
    } else if (kind === 'weaponEffects' && ['laser', 'bullet', 'machinegun'].includes(item.type)) {
      const direction = new THREE.Vector3(item.toX - item.x, (item.toY ?? 1.5) - (item.y ?? 1.5), item.toZ - item.z);
      const length = direction.length();
      const laser = item.type === 'laser';
      const beam = this.mesh(new THREE.CylinderGeometry(laser ? .018 : .009, laser ? .018 : .009, 1, 6), laser ? this.cyan : this.amber, 0, 0, 0, group);
      beam.scale.y = length; beam.position.copy(direction).multiplyScalar(.5); beam.quaternion.setFromUnitVectors(Y, direction.normalize()); beam.castShadow = false;
      const impact = this.sprite(laser ? 0x74faff : 0xffb46d, laser ? .6 : .3, group, .85); impact.position.set(item.toX - item.x, (item.toY ?? 1.5) - (item.y ?? 1.5), item.toZ - item.z);
    } else if (kind === 'weaponEffects') {
      const fire = this.sprite(0xffb449, 1, group, .9); group.userData.fire = fire;
      const ring = this.ring(1, this.amber, 0, .1, 0, group, .035); group.userData.ring = ring;
      for (let i = 0; i < 7; i++) {
        const spark = this.mesh(new THREE.OctahedronGeometry(.06), this.amber, 0, 0, 0, group);
        spark.userData.velocity = new THREE.Vector3(Math.sin(i * 2.4), .2 + (i % 3) * .4, Math.cos(i * 2.4));
      }
    }
    return group;
  }

  sync(kind, items, simulation) {
    const keep = new Set();
    for (const item of this.onLevel(items)) {
      const key = `${kind}:${item.id}`; keep.add(key);
      let group = this.dynamic.get(key);
      if (!group) { group = this.createDynamic(kind, item); this.dynamic.set(key, group); }
      group.position.set(item.x, (item.y ?? this.baseY) - this.baseY, item.z);
      if (kind === 'markers') group.rotation.y = item.yaw || 0;
      if (kind === 'projectiles') group.quaternion.setFromUnitVectors(Y, vector.set(item.dx || 0, item.dy || 0, item.dz || 0).normalize());
      if (kind === 'decoys' && group.userData.ring) {
        const flight = Math.min(1, (item.age || 0) / (item.flightDuration || .45));
        if (Number.isFinite(item.fromX) && Number.isFinite(item.fromZ)) {
          group.position.set(THREE.MathUtils.lerp(item.fromX, item.x, flight),
            (item.y ?? this.baseY) - this.baseY + (1 - flight) * 1.2 + Math.sin(flight * Math.PI) * .8, THREE.MathUtils.lerp(item.fromZ, item.z, flight));
        }
        const pulse = (simulation.elapsed * 1.3) % 1; group.userData.ring.scale.setScalar(.5 + pulse * 2);
        group.userData.ring.visible = flight >= 1;
      }
      if (kind === 'weaponEffects' && item.type === 'explosion') {
        const age = item.age || 0, progress = Math.min(1, age / (item.duration || .8)), radius = item.radius || 3;
        group.userData.fire.scale.setScalar((.4 + progress * radius * 2));
        group.userData.fire.material.opacity = .85 * (1 - progress);
        group.userData.ring.scale.setScalar(.2 + progress * radius);
        group.children.forEach(object => { if (object.userData.velocity) object.position.copy(object.userData.velocity).multiplyScalar(age * 7); });
      }
      if (kind === 'weaponEffects' && ['laser', 'bullet', 'machinegun'].includes(item.type)) group.visible = (item.age || 0) < (item.duration || .15);
    }
    for (const [key, group] of this.dynamic) if (key.startsWith(`${kind}:`) && !keep.has(key)) {
      this.destroyGroup(group); this.dynamic.delete(key);
    }
  }

  update(dt, simulation, view) {
    const time = simulation.elapsed;
    this.syncAllies(dt, simulation);
    for (const room of simulation.rooms || []) {
      const state = this.rooms.get(room.id); if (!state) continue;
      if (state.label) {
        const distance = Math.hypot(room.x - simulation.player.x, room.z - simulation.player.z);
        state.label.visible = distance > 4 && distance < 10; state.label.material.opacity = THREE.MathUtils.clamp((10 - distance) / 3, 0, .65);
      }
      if (state.water) { state.water.visible = !room.drained; state.water.position.y = .24 + Math.sin(time * .65) * .025; }
      if (state.valve && room.drained) state.valve.rotation.y = .65;
      if (state.indicator) state.indicator.material = room.solved ? this.green : this.cyan;
    }
    for (const objective of simulation.objectives || []) {
      const state = this.objectives.get(objective.id); if (!state) continue;
      state.lamp.material = objective.completed ? this.green : this.red;
      if (objective.completed || simulation.activeInteraction?.id === objective.id) state.cog.rotation.z += dt * (objective.completed ? .4 : 1.8);
    }
    for (const chest of simulation.treasures || []) {
      const state = this.chests.get(chest.id); if (!state) continue;
      state.lid.rotation.x = chest.collected ? -1.05 : 0; state.glow.visible = !chest.collected;
      state.warning.visible = !!chest.trapped && !chest.collected;
      if (state.warning.visible) state.warning.scale.setScalar(1 + Math.sin(time * 3) * .025);
    }
    for (const hazard of simulation.hazards || []) {
      const state = this.hazards.get(hazard.id); if (!state) continue;
      const active = hazard.active !== false;
      state.danger.visible = active || hazard.type !== 'gas';
      state.warning.visible = active || !!hazard.warning;
      state.warning.material = active ? this.red : this.amber;
      if (hazard.type === 'spikes') state.danger.position.y = active ? 0 : -.27;
    }
    if (this.explorer && simulation.rescue) {
      const rescue = simulation.rescue, explorer = this.explorer;
      const oldX = explorer.group.position.x, oldZ = explorer.group.position.z;
      explorer.group.visible = (rescue.level || 0) === this.level;
      explorer.group.position.set(rescue.x, (rescue.y ?? this.baseY) - this.baseY, rescue.z);
      if (Math.hypot(rescue.x - oldX, rescue.z - oldZ) > .001) explorer.group.rotation.y = Math.atan2(rescue.x - oldX, rescue.z - oldZ);
      const gait = rescue.following ? Math.sin(time * 7) * .18 : 0;
      explorer.legs.forEach((leg, i) => { leg.rotation.x = gait * (i ? 1 : -1); });
      explorer.arms.forEach((arm, i) => { arm.rotation.x = gait * (i ? -1 : 1); });
    }
    this.flood.visible = this.biome !== 'forest' && simulation.worldEvent?.type === 'flood' && simulation.worldEvent.phase === 'active';
    if (this.flood.visible) this.flood.position.y = .06 + Math.sin(time) * .03;
    const look = BIOME_LOOKS[simulation.config.biome] || BIOME_LOOKS.catacombs;
    const gas = simulation.worldEvent?.type === 'gas' && simulation.worldEvent.phase === 'active';
    if (this.biome !== 'forest') {
      this.world.scene.fog.color.setHex(gas ? 0x41422b : look.fog);
      this.world.scene.fog.density = gas ? .085 : look.fogDensity;
    }
    for (const kind of ['markers', 'flares', 'decoys', 'projectiles', 'weaponEffects']) this.sync(kind, simulation[kind], simulation);
    const nearest = this.onLevel(simulation.flares).sort((a, b) => Math.hypot(a.x - simulation.player.x, a.z - simulation.player.z) - Math.hypot(b.x - simulation.player.x, b.z - simulation.player.z));
    this.flareLights.forEach((light, i) => {
      const flare = nearest[i]; light.intensity = flare ? 42 + Math.sin(time * 17) * 6 : 0;
      if (flare) light.position.set(flare.x, (flare.y ?? this.baseY) - this.baseY + .35, flare.z);
    });
    const blast = this.onLevel(simulation.weaponEffects).find(effect => effect.type === 'explosion');
    this.blastLight.intensity = blast ? Math.max(0, 90 * (1 - (blast.age || 0) / (blast.duration || .8))) : 0;
    if (blast) this.blastLight.position.set(blast.x, (blast.y ?? this.baseY + 1) - this.baseY, blast.z);
    this.weapons.forEach(weapon => {
      const effect = this.recentWeaponEffect(weapon, simulation);
      weapon.flash.visible = Boolean(effect) && (effect.age || 0) < (weapon.id === 'machinegun' ? .07 : .12);
    });
  }

  destroyGroup(group) {
    group.traverse(object => {
      if (object.geometry && this.geometries.has(object.geometry)) { object.geometry.dispose(); this.geometries.delete(object.geometry); }
      if (object.isSprite && this.materials.has(object.material)) { object.material.dispose(); this.materials.delete(object.material); }
    });
    group.removeFromParent();
  }

  dispose() {
    for (const elf of this.allies.values()) elf.dispose(); this.allies.clear();
    if (this.weaponPass) { this.world.composer.removePass(this.weaponPass); this.weaponPass.dispose(); this.weaponScene.clear(); }
    this.root.traverse(object => { if (object.isInstancedMesh) object.dispose(); });
    this.root.removeFromParent(); this.root.clear();
    this.geometries.forEach(geometry => geometry.dispose());
    this.materials.forEach(material => material.dispose()); this.textures.forEach(texture => texture.dispose());
  }
}

/** Distinct silhouettes: scanned watcher statue and a floating, veiled shade. */
export class ExpeditionCreature {
  constructor(world, type) {
    this.type = type; this.root = new THREE.Group(); this.ownedGeometry = new Set(); this.ownedMaterial = new Set();
    if (type === 'watcher') {
      this.model = world.addProp(world.assets.statue, 0, 0, 0, 2.05, Math.PI, this.root);
      this.eyes = new THREE.Group(); this.root.add(this.eyes);
      const material = new THREE.MeshBasicMaterial({ color: 0xffbc76 }); this.ownedMaterial.add(material);
      for (const x of [-.08, .08]) {
        const geometry = new THREE.SphereGeometry(.025, 8, 5); this.ownedGeometry.add(geometry);
        const eye = new THREE.Mesh(geometry, material); eye.position.set(x, 1.63, .23); this.eyes.add(eye);
      }
    } else {
      const material = new THREE.MeshStandardMaterial({ color: 0x05090c, roughness: .95, metalness: 0, transparent: true, opacity: .94, side: THREE.DoubleSide });
      const faceMaterial = new THREE.MeshBasicMaterial({ color: 0x06090d });
      const eyeMaterial = new THREE.MeshBasicMaterial({ color: 0x89cbdc });
      [material, faceMaterial, eyeMaterial].forEach(m => this.ownedMaterial.add(m));
      const mesh = (geometry, mat, x, y, z) => {
        this.ownedGeometry.add(geometry); const object = new THREE.Mesh(geometry, mat); object.position.set(x, y, z); this.root.add(object); return object;
      };
      const cloakGeometry = new THREE.CylinderGeometry(.2, .48, 1.65, 24, 12, true);
      const vertices = cloakGeometry.attributes.position;
      for (let i = 0; i < vertices.count; i++) {
        const angle = Math.atan2(vertices.getX(i), vertices.getZ(i));
        const ripple = Math.sin(angle * 8) * .025;
        vertices.setX(i, vertices.getX(i) + Math.sin(angle) * ripple);
        vertices.setZ(i, vertices.getZ(i) + Math.cos(angle) * ripple);
        if (vertices.getY(i) < -.7) vertices.setY(i, vertices.getY(i) + Math.sin(angle * 5) * .09);
      }
      cloakGeometry.computeVertexNormals();
      this.cloak = mesh(cloakGeometry, material, 0, 1.05, 0);
      const hood = mesh(new THREE.SphereGeometry(.28, 16, 10), material, 0, 1.91, 0); hood.scale.z = .9;
      const face = mesh(new THREE.SphereGeometry(.18, 12, 8), faceMaterial, 0, 1.91, .14); face.scale.z = .35;
      for (const x of [-.075, .075]) mesh(new THREE.SphereGeometry(.022, 8, 5), eyeMaterial, x, 1.95, .205);
      for (const sign of [-1, 1]) {
        const arm = mesh(new THREE.ConeGeometry(.11, .95, 8), material, sign * .35, 1.2, 0); arm.rotation.z = sign * -.24;
      }
    }
  }
  update(dt, entity, player) {
    this.time = (this.time || 0) + dt;
    this.root.position.set(entity.x, this.type === 'shade' ? .14 + Math.sin(this.time * 2) * .08 : 0, entity.z);
    if (this.type !== 'watcher' || entity.state !== 'frozen') this.root.rotation.y = Math.atan2(player.x - entity.x, player.z - entity.z);
    if (this.cloak) this.cloak.rotation.z = Math.sin(this.time * 1.8) * .055;
  }
  dispose() {
    this.root.removeFromParent(); this.root.clear();
    this.ownedGeometry.forEach(geometry => geometry.dispose()); this.ownedMaterial.forEach(material => material.dispose());
  }
}
