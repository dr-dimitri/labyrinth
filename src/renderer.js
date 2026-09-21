import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { GTAOPass } from 'three/addons/postprocessing/GTAOPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { createRng, walkable } from './maze.js';
import { loadPhotorealAssets } from './assets.js';
import { createArchGeometry, applyMetricUvs } from './architecture.js';
import { GuardianModel } from './guardian.js';
import { ExpeditionVisuals, ExpeditionCreature, BIOME_LOOKS } from './expedition-visuals.js';
import { VerticalArchitecture, createLandingTile } from './vertical-architecture.js';
import { cameraAimRay } from './weapon-aim.js';
import { ForestRenderer } from './forest-renderer.js';
import { getTerrainHeight, getTerrainCave } from './forest-world.js';
import { WorldRelief } from './world-relief.js';
import { DepthAtmospherePass } from './depth-atmosphere.js';
import { ForestCreature } from './forest-creatures.js';

const CELL = 3.6;
const dummy = new THREE.Object3D();
const up = new THREE.Vector3(0, 1, 0);
const directions = [{ x: 1, z: 0 }, { x: -1, z: 0 }, { x: 0, z: 1 }, { x: 0, z: -1 }];
const positionKey = ({ x, z }) => `${x},${z}`;

// Compute contact shadows at a lower resolution than the final image.
class ContactShadowPass extends GTAOPass {
  setSize(width, height) { super.setSize(Math.ceil(width * (this.resolutionScale || .6)), Math.ceil(height * (this.resolutionScale || .6))); }
  _overrideVisibility() {
    super._overrideVisibility();
    // Billboards and water have no opaque surface for the normal/depth buffer.
    // Including them creates rectangular contact shadows around transparent labels.
    this.scene.traverse(object => {
      if (object.visible && (object.isSprite || object.material?.alphaTest > 0 || (object.material?.transparent && object.material.depthWrite === false))) {
        object.visible = false; this._visibilityCache.push(object);
      }
    });
  }
}

function glowTexture() {
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 128;
  const ctx = canvas.getContext('2d');
  const g = ctx.createRadialGradient(64, 64, 1, 64, 64, 64);
  g.addColorStop(0, 'rgba(255,255,235,1)'); g.addColorStop(.12, 'rgba(255,240,185,.8)');
  g.addColorStop(.32, 'rgba(255,205,125,.18)'); g.addColorStop(1, 'rgba(255,190,100,0)');
  ctx.fillStyle = g; ctx.fillRect(0, 0, 128, 128);
  return new THREE.CanvasTexture(canvas);
}

function tintedGeometry(geometry, value = 1) {
  const colors = new Float32Array(geometry.attributes.position.count * 3).fill(value);
  geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  return geometry;
}

export class WorldRenderer {
  constructor(container, { onProgress, quality = 'high' } = {}) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 1.35));
    this.renderer.setSize(innerWidth, innerHeight);
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFShadowMap;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.15;
    container.appendChild(this.renderer.domElement);
    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x131b1c);
    this.scene.fog = new THREE.FogExp2(0x131b1c, .025);
    this.camera = new THREE.PerspectiveCamera(70, innerWidth / innerHeight, .08, 150);
    this.camera.rotation.order = 'YXZ';
    this.composer = new EffectComposer(this.renderer);
    this.composer.addPass(new RenderPass(this.scene, this.camera));
    this.contactShadows = new ContactShadowPass(this.scene, this.camera, innerWidth, innerHeight);
    this.contactShadows.updateGtaoMaterial({ radius: .85, distanceExponent: 1.3, thickness: .7, scale: 1.2, samples: 8 });
    this.contactShadows.updatePdMaterial({ samples: 8, radius: 4 });
    this.contactShadows.blendIntensity = .85;
    this.composer.addPass(this.contactShadows);
    this.atmosphere = new DepthAtmospherePass(this.contactShadows.depthTexture);
    this.composer.addPass(this.atmosphere);
    this.bloom = new UnrealBloomPass(new THREE.Vector2(innerWidth, innerHeight), .24, .55, 1.1);
    this.composer.addPass(this.bloom);
    this.composer.addPass(new OutputPass());
    this.world = new THREE.Group(); this.scene.add(this.world);
    this.ambient = new THREE.HemisphereLight(0xb9c9d5, 0x645d49, .8); this.scene.add(this.ambient);
    this.moon = new THREE.DirectionalLight(0xbed5ec, 1.4);
    this.moon.position.set(-24, 42, -18); this.scene.add(this.moon, this.moon.target);
    this.moon.castShadow = true; this.moon.shadow.autoUpdate = false;
    Object.assign(this.moon.shadow.camera, { left: -28, right: 28, top: 28, bottom: -28, near: .5, far: 140 });
    this.moon.shadow.camera.updateProjectionMatrix();
    this.moon.shadow.bias = -.00018; this.moon.shadow.normalBias = .035;
    this.moon.shadow.mapSize.set(2048, 2048);
    this.torchKey = new THREE.SpotLight(0xffc38b, 38, 17, Math.PI * .43, .75, 2);
    this.torchKey.shadow.mapSize.set(512, 512); this.torchKey.shadow.bias = -.0002; this.torchKey.shadow.normalBias = .025;
    this.scene.add(this.torchKey, this.torchKey.target);
    this.flashlight = new THREE.SpotLight(0xffefd5, 65, 30, Math.PI / 6, .8, 1.85);
    this.flashlight.castShadow = true;
    this.flashlight.shadow.mapSize.set(1024, 1024);
    this.flashlight.shadow.bias = -.00015; this.flashlight.shadow.normalBias = .02;
    this.scene.add(this.flashlight, this.flashlight.target);
    this.nearLights = Array.from({ length: 5 }, () => {
      const light = new THREE.PointLight(0xffbf76, 30, 13, 2); this.scene.add(light); return light;
    });
    this.glowMap = glowTexture();
    this.iron = new THREE.MeshStandardMaterial({ color: 0x4a4035, metalness: .8, roughness: .64 });
    this.flameMaterial = new THREE.MeshBasicMaterial({ color: 0xffd390 });
    this.relicMaterial = new THREE.MeshStandardMaterial({ color: 0xc3ef9b, emissive: 0xa3df70, emissiveIntensity: 2.1, metalness: .65, roughness: .2 });
    this.torches = []; this.relicMeshes = []; this.monsterMeshes = new Map(); this.clock = 0;
    this.lookDirection = new THREE.Vector3();
    this.onResize = () => this.resize();
    window.addEventListener('resize', this.onResize);
    this.setQuality(quality);
    this.ready = this.initialize(onProgress);
  }

  async initialize(onProgress) {
    this.assets = await loadPhotorealAssets(this.renderer, onProgress);
    this.stone = this.assets.wall; this.trim = this.assets.trim;
    this.scene.environment = this.assets.environment;
    this.scene.environmentIntensity = .7;
    this.scene.environmentRotation.set(0, .6, 0);
    this.showMenu();
    onProgress?.('DIE VERGESSENEN HALLEN ERWACHEN …');
    await this.renderer.compileAsync(this.scene, this.camera);
  }

  mesh(geometry, material, x, y, z, parent = this.world) {
    const mesh = new THREE.Mesh(geometry, material);
    mesh.position.set(x, y, z); mesh.castShadow = mesh.receiveShadow = true;
    parent.add(mesh); return mesh;
  }

  clear() {
    for (const guardian of this.monsterMeshes.values()) guardian.dispose();
    this.expedition?.dispose(); this.expedition = null;
    this.vertical?.dispose(); this.vertical = null;
    this.forest?.dispose(); this.forest = null;
    this.relief?.dispose(); this.relief = null;
    this.biomeMaterials?.forEach(material => material.dispose()); this.biomeMaterials = [];
    const geometries = new Set(), materials = new Set();
    this.world.traverse(object => {
      if (object.geometry && !object.userData.persistentAsset) geometries.add(object.geometry);
      if (object.material && object.userData.transientMaterial) materials.add(object.material);
      if (object.isInstancedMesh) object.dispose();
    });
    geometries.forEach(geometry => geometry.dispose());
    materials.forEach(material => material.dispose());
    this.world.clear(); this.torches = []; this.relicMeshes = [];
    this.moon.shadow.needsUpdate = true;
    this.monsterMeshes.clear(); this.portal = null;
  }

  selectNiches(maze, rng) {
    const candidates = [];
    for (let z = 1; z < maze.size - 1; z++) for (let x = 1; x < maze.size - 1; x++) {
      if (!maze.grid[z][x]) continue;
      const front = directions.find(d => walkable(maze, x + d.x, z + d.z));
      if (front) candidates.push({ x, z, front });
    }
    for (let i = candidates.length - 1; i > 0; i--) {
      const j = Math.floor(rng() * (i + 1)); [candidates[i], candidates[j]] = [candidates[j], candidates[i]];
    }
    const selected = [];
    for (const candidate of candidates) {
      if (selected.every(other => Math.hypot(other.x - candidate.x, other.z - candidate.z) > 4)) selected.push(candidate);
      if (selected.length >= Math.min(8, Math.ceil(maze.size / 3))) break;
    }
    return selected;
  }

  build(maze, menu = false, simulation = null) {
    this.clear(); this.mode = menu ? 'menu' : 'game';
    this.levelIndex = menu ? 0 : (simulation?.player.level || 0);
    this.floorY = menu ? 0 : (simulation?.levels?.[this.levelIndex]?.y || 0);
    this.world.position.y = this.floorY;
    const ladderCells = (simulation?.ladders || []).filter(ladder => ladder.fromLevel === this.levelIndex || ladder.toLevel === this.levelIndex);
    const floorOpenings = new Set(ladderCells.filter(ladder => ladder.toLevel === this.levelIndex).map(ladder => `${Math.round(ladder.x / CELL)},${Math.round(ladder.z / CELL)}`));
    const ceilingOpenings = new Set(ladderCells.filter(ladder => ladder.fromLevel === this.levelIndex).map(ladder => `${Math.round(ladder.x / CELL)},${Math.round(ladder.z / CELL)}`));
    this.biomeId = menu ? 'catacombs' : (simulation?.config?.biome || 'catacombs');
    const look = BIOME_LOOKS[this.biomeId] || BIOME_LOOKS.catacombs;
    if (this.biomeId === 'forest' && simulation?.terrain) {
      this.forest = new ForestRenderer(this, simulation);
      for (const objective of simulation.objectives.filter(item => item.type === 'seal')) {
        this.addRelic(objective.x, objective.z, objective.y || 0, true);
        this.relicMeshes.at(-1).objectiveId = objective.id;
      }
      this.addForestPortal(simulation);
      this.expedition = new ExpeditionVisuals(this, simulation);
      return;
    }
    const enclosed = this.biomeId !== 'ruins' || this.levelIndex < (simulation?.levels?.length || 1) - 1;
    const rng = createRng(`${maze.seed}:architecture`), height = menu ? 6.2 : enclosed ? 4.5 : look.wallHeight;
    const niches = menu || this.biomeId === 'mine' ? [] : this.selectNiches(maze, rng);
    const nicheCells = new Set(niches.map(positionKey));
    const walls = [], floors = [];
    for (let z = 0; z < maze.size; z++) for (let x = 0; x < maze.size; x++) {
      if (!maze.grid[z][x]) floors.push({ x, z });
      else if (!nicheCells.has(`${x},${z}`)) walls.push({ x, z });
    }
    // Bevels catch grazing light; metric UVs preserve the photographed stone size.
    const wallGeometry = tintedGeometry(applyMetricUvs(new RoundedBoxGeometry(CELL - .30, height, CELL - .30, 1, .045), 3.5));
    const wallMaterial = this.stone.clone(); wallMaterial.color.setHex(look.wall);
    const floorMaterial = this.assets.floor.clone(); floorMaterial.color.setHex(look.floor);
    this.biomeMaterials.push(wallMaterial, floorMaterial);
    const wallMesh = new THREE.InstancedMesh(wallGeometry, wallMaterial, walls.length);
    const trimGeometry = applyMetricUvs(new RoundedBoxGeometry(CELL + .02, .18, CELL + .02, 1, .025), 3.5);
    const trimMesh = new THREE.InstancedMesh(trimGeometry, this.trim, walls.length * 2);
    walls.forEach(({ x, z }, i) => {
      const wallScale = this.biomeId === 'ruins' && !menu && !enclosed ? .84 + rng() * .16 : 1;
      dummy.position.set(x * CELL, height * wallScale / 2, z * CELL); dummy.rotation.set(0, 0, 0); dummy.scale.set(1, wallScale, 1); dummy.updateMatrix();
      wallMesh.setMatrixAt(i, dummy.matrix);
      wallMesh.setColorAt(i, new THREE.Color().setScalar(.88 + rng() * .12));
      for (let j = 0; j < 2; j++) {
        dummy.scale.set(1, 1, 1); dummy.position.y = j ? height * wallScale - .18 : .18; dummy.updateMatrix(); trimMesh.setMatrixAt(i * 2 + j, dummy.matrix);
      }
    });
    wallMesh.castShadow = wallMesh.receiveShadow = trimMesh.castShadow = trimMesh.receiveShadow = true;
    this.world.add(wallMesh, trimMesh);

    const floorGeometry = new THREE.PlaneGeometry(CELL, CELL, 12, 12);
    floorGeometry.rotateX(-Math.PI / 2);
    applyMetricUvs(floorGeometry, 1.8); tintedGeometry(floorGeometry);
    const solidFloors = floors.filter(cell => !floorOpenings.has(positionKey(cell)));
    const floorMesh = new THREE.InstancedMesh(floorGeometry, floorMaterial, solidFloors.length);
    solidFloors.forEach(({ x, z }, i) => {
      dummy.position.set(x * CELL, 0, z * CELL); dummy.rotation.set(0, 0, 0); dummy.scale.set(1, 1, 1); dummy.updateMatrix();
      floorMesh.setMatrixAt(i, dummy.matrix); floorMesh.setColorAt(i, new THREE.Color().setScalar(.94 + rng() * .06));
    });
    floorMesh.receiveShadow = true; this.world.add(floorMesh);
    for (const cell of floors.filter(cell => floorOpenings.has(positionKey(cell)))) {
      this.mesh(tintedGeometry(createLandingTile()), floorMaterial, cell.x * CELL, 0, cell.z * CELL);
    }
    if (!menu && (this.biomeId !== 'ruins' || this.levelIndex < (simulation?.levels?.length || 1) - 1)) {
      const ceiling = new THREE.PlaneGeometry(CELL + .1, CELL + .1);
      ceiling.rotateX(Math.PI / 2); applyMetricUvs(ceiling, 3.5);
      const solidCeilings = floors.filter(cell => !ceilingOpenings.has(positionKey(cell)));
      const ceilingMesh = new THREE.InstancedMesh(ceiling, this.assets.ceiling, solidCeilings.length);
      solidCeilings.forEach(({ x, z }, index) => {
        dummy.position.set(x * CELL, 4.5, z * CELL); dummy.rotation.set(0, 0, 0); dummy.scale.set(1, 1, 1); dummy.updateMatrix();
        ceilingMesh.setMatrixAt(index, dummy.matrix);
      });
      ceilingMesh.receiveShadow = true; this.world.add(ceilingMesh);
      for (const cell of floors.filter(cell => ceilingOpenings.has(positionKey(cell)))) {
        this.mesh(createLandingTile({ ceiling: true }), this.assets.ceiling, cell.x * CELL, 4.5, cell.z * CELL).castShadow = false;
      }
    }
    this.relief = new WorldRelief(this, maze, simulation, { menu, wallHeight: height, nicheCells });
    if (ladderCells.length) this.vertical = new VerticalArchitecture(this, simulation);
    niches.forEach(niche => this.addNiche(niche, height));
    let rockCount = 0;
    for (const { x, z } of floors) {
      const side = directions.find(d => !walkable(maze, x + d.x, z + d.z));
      if (side && ((x * 7 + z * 11) % 9 === 0 || (menu && x === 7 && z % 3 === 0))) {
        this.addTorch(x * CELL + side.x * 1.59, z * CELL + side.z * 1.59, side, menu ? 2.8 : 2.25);
      }
      if (!menu && this.biomeId !== 'mine' && !ceilingOpenings.has(`${x},${z}`) && !floorOpenings.has(`${x},${z}`) && x % 4 === 1 && z % 4 === 1) {
        if (walkable(maze, x, z - 1) && walkable(maze, x, z + 1) && !walkable(maze, x - 1, z) && !walkable(maze, x + 1, z)) this.addArch(x * CELL, z * CELL, 0, 2.06, 2.15);
        else if (walkable(maze, x - 1, z) && walkable(maze, x + 1, z) && !walkable(maze, x, z - 1) && !walkable(maze, x, z + 1)) this.addArch(x * CELL, z * CELL, Math.PI / 2, 2.06, 2.15);
      }
      if (side && rng() < .2 && rockCount < 32) {
        // Low debris stays at the wall edge, below the player's stepping height.
        this.addProp(this.assets.rock, x * CELL + side.x * 1.28 + (rng() - .5) * .2, -.02,
          z * CELL + side.z * 1.28 + (rng() - .5) * .2, .12 + rng() * .09, rng() * Math.PI * 2);
        rockCount++;
      }
    }
    if (menu || this.levelIndex === 0) this.addPortal(maze.exit.x * CELL, maze.exit.z * CELL, maze);
    if (simulation?.objectives) {
      simulation.objectives.filter(objective => objective.type === 'seal' && (objective.level || 0) === this.levelIndex).forEach(objective => {
        this.addRelic(objective.x, objective.z); this.relicMeshes.at(-1).objectiveId = objective.id;
      });
    } else maze.relics.forEach(({ x, z }) => this.addRelic(x * CELL, z * CELL));
    this.addDust(maze.size, rng);
    if (simulation) this.expedition = new ExpeditionVisuals(this, simulation);
  }

  addProp(template, x, y, z, height, angle = 0, parent = this.world) {
    const group = new THREE.Group(), model = template.clone(true);
    group.add(model); model.updateMatrixWorld(true);
    const bounds = new THREE.Box3().setFromObject(model), size = bounds.getSize(new THREE.Vector3());
    const scale = height / Math.max(size.y, .001);
    model.scale.multiplyScalar(scale);
    model.position.set(-(bounds.min.x + bounds.max.x) * .5 * scale, -bounds.min.y * scale, -(bounds.min.z + bounds.max.z) * .5 * scale);
    group.position.set(x, y, z); group.rotation.y = angle;
    parent.add(group); return group;
  }

  stoneBlock(width, height, depth, x, y, z, parent, material = this.trim) {
    const geometry = applyMetricUvs(new RoundedBoxGeometry(width, height, depth, 1, .035), 3.5);
    return this.mesh(geometry, material, x, y, z, parent);
  }

  addNiche({ x, z, front }, height) {
    const group = new THREE.Group(); group.position.set(x * CELL, 0, z * CELL);
    group.rotation.y = Math.atan2(front.x, front.z); this.world.add(group);
    this.stoneBlock(CELL, height, 1.4, 0, height / 2, -1.1, group);
    for (const side of [-1, 1]) this.stoneBlock(.55, height, 2.2, side * 1.525, height / 2, .7, group);
    this.stoneBlock(CELL, height - 2.8, 2.2, 0, (height + 2.8) / 2, .7, group);
    // The raised plinth is a visible barrier matching this non-walkable cell.
    this.stoneBlock(2.5, .4, 2.2, 0, .2, .7, group, this.assets.plinth);
    this.addProp(this.assets.statue, 0, .4, .65, 2, 0, group);
  }

  addArch(x, z, rotation = 0, radius = 2.06, pillar = 2.15) {
    const geometry = createArchGeometry({ radius, pillar, depth: radius > 3 ? 1.05 : .65, thickness: radius > 3 ? .48 : .28, seed: `${x}:${z}` });
    const arch = this.mesh(geometry, this.assets.masonry, x, 0, z);
    arch.rotation.y = rotation; return arch;
  }

  addTorch(x, z, side, height = 2.25) {
    this.mesh(new THREE.CylinderGeometry(.045, .07, .48, 12), this.iron, x, height - .3, z);
    this.mesh(new THREE.CylinderGeometry(.16, .065, .2, 12), this.iron, x, height - .05, z);
    const flame = this.mesh(new THREE.SphereGeometry(.075, 12, 8), this.flameMaterial, x, height + .15, z);
    flame.scale.y = 2.5; flame.castShadow = false;
    const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: this.glowMap, color: 0xffb15a, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, opacity: .65 }));
    glow.position.set(x, height + .15, z); glow.scale.set(1.4, 2.1, 1); glow.userData.transientMaterial = true; this.world.add(glow);
    this.torches.push({ position: new THREE.Vector3(x - side.x * .25, height + .15, z - side.z * .25), flame, glow, phase: x * 2 + z });
  }

  addRelic(x, z, groundY = 0, natural = false) {
    const group = new THREE.Group(); group.position.set(x, groundY + 1.45, z); this.world.add(group);
    const core = this.mesh(new THREE.OctahedronGeometry(.25, 0), this.relicMaterial, 0, 0, 0, group);
    this.mesh(new THREE.TorusGeometry(.48, .017, 8, 48), this.relicMaterial, 0, 0, 0, group);
    const ring = this.mesh(new THREE.TorusGeometry(.35, .012, 8, 40), this.relicMaterial, 0, 0, 0, group); ring.rotation.x = Math.PI / 2;
    const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: this.glowMap, color: 0xc7ec93, blending: THREE.AdditiveBlending, transparent: true, depthWrite: false, opacity: .35 }));
    glow.scale.set(2, 2, 2); glow.userData.transientMaterial = true; group.add(glow);
    const pedestal = natural ? this.addProp(this.assets.rock, x, groundY, z, .48)
      : this.stoneBlock(.85, .45, .85, x, .225, z, this.world, this.assets.plinth);
    this.relicMeshes.push({ group, core, pedestal, groundY });
  }

  addPortal(x, z, maze) {
    const group = new THREE.Group(); group.position.set(x, 0, z);
    if (!walkable(maze, maze.exit.x, maze.exit.z - 1) && !walkable(maze, maze.exit.x, maze.exit.z + 1)) group.rotation.y = Math.PI / 2;
    this.world.add(group);
    const frame = createArchGeometry({ radius: 1.1, pillar: 1.65, depth: .32, thickness: .18, seed: 'exit' });
    this.mesh(frame, this.assets.masonry, 0, 0, 0, group);
    const material = new THREE.MeshBasicMaterial({ color: 0x8fdbac, transparent: true, opacity: .2, side: THREE.DoubleSide, depthWrite: false });
    const disc = this.mesh(new THREE.CircleGeometry(1.02, 48), material, 0, 1.65, 0, group);
    disc.scale.y = 1.35; disc.userData.transientMaterial = true; disc.castShadow = false;
    const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: this.glowMap, color: 0x88ecc1, blending: THREE.AdditiveBlending, transparent: true, depthWrite: false, opacity: .5 }));
    glow.position.y = 1.7; glow.scale.set(5, 6, 1); glow.userData.transientMaterial = true; group.add(glow);
    const light = new THREE.PointLight(0x74e7b9, 35, 12, 2); light.position.y = 1.8; group.add(light);
    this.portal = { group, disc, glow, light };
  }

  addForestPortal(simulation) {
    const { x, z } = simulation.maze.exit;
    const worldX = x * CELL, worldZ = z * CELL;
    const groundY = getTerrainHeight(simulation.terrain, worldX, worldZ);
    const group = new THREE.Group(); group.position.set(worldX, groundY, worldZ); this.world.add(group);
    // Two ancient standing stones mark a woodland gate. The photographed rocks
    // replace the masonry arch used in the underground levels.
    for (const side of [-1, 1]) this.addProp(this.assets.rock, side * 1.2, -.06, 0, 2.5, side * .15, group);
    const material = new THREE.MeshBasicMaterial({ color: 0x98ccb4, transparent: true, opacity: .15, side: THREE.DoubleSide, depthWrite: false });
    const disc = this.mesh(new THREE.CircleGeometry(1.04, 48), material, 0, 1.5, 0, group); disc.scale.y = 1.4; disc.castShadow = false; disc.userData.transientMaterial = true;
    const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: this.glowMap, color: 0x87c6ba, blending: THREE.AdditiveBlending, transparent: true, depthWrite: false, opacity: .45 }));
    glow.position.y = 1.6; glow.scale.set(4.2, 5.2, 1); glow.userData.transientMaterial = true; group.add(glow);
    const light = new THREE.PointLight(0x80c9b3, 25, 10, 2); light.position.y = 1.5; group.add(light);
    this.portal = { group, disc, glow, light };
  }

  addDust(size, rng) {
    const positions = new Float32Array(400 * 3);
    for (let i = 0; i < 400; i++) { positions[i * 3] = rng() * size * CELL; positions[i * 3 + 1] = rng() * 4.3; positions[i * 3 + 2] = rng() * size * CELL; }
    const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    const material = new THREE.PointsMaterial({ color: 0xb7c8a0, size: .022, transparent: true, opacity: .28, depthWrite: false, blending: THREE.AdditiveBlending });
    this.dust = new THREE.Points(geometry, material); this.dust.userData.transientMaterial = true; this.world.add(this.dust);
  }

  showMenu() {
    const size = 17, grid = Array.from({ length: size }, () => Array(size).fill(1));
    for (let z = 1; z < size - 1; z++) for (let x = 4; x <= 12; x++) grid[z][x] = 0;
    for (let z = 2; z < size - 2; z += 4) for (const x of [4, 5, 11, 12]) grid[z][x] = 1;
    this.build({ size, grid, exit: { x: 8, z: 2 }, relics: [{ x: 8, z: 5 }], seed: 'ancient-halls' }, true);
    for (const z of [4, 8, 12]) this.addArch(8 * CELL, z * CELL, 0, 5.1, 2.5);
    for (const z of [7, 11]) for (const x of [6.2, 9.8]) {
      this.stoneBlock(2.4, .55, 2.4, x * CELL, .275, z * CELL, this.world, this.assets.plinth);
      this.addProp(this.assets.statue, x * CELL, .55, z * CELL, 2.8, x < 8 ? .28 : -.28);
    }
    for (const z of [3, 7, 11, 14]) for (const x of [4.1, 11.9]) this.addTorch(x * CELL, z * CELL, { x: x < 8 ? -1 : 1, z: 0 }, 2.4);
    this.camera.fov = 74; this.camera.updateProjectionMatrix();
    this.camera.position.set(8 * CELL, 2.3, 14.6 * CELL);
    this.camera.lookAt(7.4 * CELL, 2.55, 3 * CELL);
    this.flashlight.intensity = 0; this.ambient.intensity = .9; this.moon.intensity = 2.2;
    this.scene.environmentIntensity = .9; this.scene.fog.density = .023;
    this.scene.background.setHex(0x131b1c); this.scene.fog.color.setHex(0x131b1c);
    this.ambient.color.setHex(0xb9c9d5); this.moon.color.setHex(0xbed5ec);
    this.updateDepthLighting(null, 1);
  }

  showGame(simulation) {
    this.build(simulation.maze, false, simulation);
    this.mapRevision = simulation.mapRevision || 0;
    const look = BIOME_LOOKS[this.biomeId] || BIOME_LOOKS.catacombs;
    this.ambient.intensity = look.ambient; this.moon.intensity = look.moon;
    this.ambient.color.setHex(look.sky); this.moon.color.setHex(look.sky);
    this.scene.environmentIntensity = look.environment; this.scene.fog.density = look.fogDensity;
    this.scene.background.setHex(look.fog); this.scene.fog.color.setHex(look.fog);
    this.updateDepthLighting(simulation, 1);
  }

  // The game prepares this pose after movement and before firing. Rendering
  // consumes it unchanged, so bob, FOV and muzzle position share one frame.
  prepareView(simulation, view = {}, dt = 0) {
    if (!this.assets || this.mode !== 'game' || !simulation) return;
    if ((simulation.mapRevision || 0) !== this.mapRevision) this.showGame(simulation);
    this.clock += dt;
    const bob = view.moving ? Math.sin(this.clock * (view.sprinting ? 14 : 9)) * .043 : 0;
    this.camera.position.set(simulation.player.x, (simulation.player.y || 0) + 1.72 + (simulation.climbing ? 0 : bob), simulation.player.z);
    this.camera.rotation.set(view.pitch || 0, view.yaw || 0, 0, 'YXZ');
    this.camera.fov += ((view.sprinting ? 81 : 74) - this.camera.fov) * Math.min(1, dt * 6);
    this.camera.updateProjectionMatrix();
    const ray = cameraAimRay(this.camera, view.aimX, view.aimY);
    const hit = simulation.getAimTarget?.(ray.origin, ray.direction, 55);
    const target = hit ? new THREE.Vector3(hit.x, hit.y, hit.z) : ray.origin.clone().addScaledVector(ray.direction, 55);
    this.aimRay = ray; this.aimTarget = target;
    this.expedition?.prepareWeapons(dt, simulation, view, target);
    this.viewPrepared = true;
  }

  getWeaponShot(slot, simulation, view = {}) {
    if (!this.viewPrepared) this.prepareView(simulation, view);
    return this.expedition?.getWeaponShot(slot) || null;
  }

  update(dt, simulation, view = {}) {
    if (!this.assets) return;
    if (this.mode === 'menu') {
      this.clock += dt; this.viewPrepared = false;
      this.camera.position.x = 8 * CELL + Math.sin(this.clock * .08) * 1.1;
      this.camera.position.y = 2.5 + Math.sin(this.clock * .13) * .06;
      this.camera.lookAt(7.5 * CELL, 2.9, 3 * CELL);
    } else if (simulation) {
      if (!this.viewPrepared) this.prepareView(simulation, view, dt);
      this.viewPrepared = false;
      const nearLadder = simulation.climbing || (simulation.ladders || []).some(ladder =>
        (ladder.fromLevel === this.levelIndex || ladder.toLevel === this.levelIndex) && Math.hypot(ladder.x - simulation.player.x, ladder.z - simulation.player.z) < 2.2);
      this.flashlight.intensity = view.light === false ? 0 : nearLadder ? 24 : 65;
      this.flashlight.position.copy(this.camera.position).add(new THREE.Vector3(.34, -.24, .03).applyAxisAngle(up, view.yaw || 0));
      this.camera.getWorldDirection(this.lookDirection);
      this.flashlight.target.position.copy(this.camera.position).addScaledVector(this.lookDirection, 5);
      this.relicMeshes.forEach((mesh, i) => {
        const objective = mesh.objectiveId && simulation.objectives?.find(item => item.id === mesh.objectiveId);
        mesh.group.visible = objective ? !objective.completed : !simulation.relics?.[i]?.collected;
      });
      const activeMonsters = simulation.monsters.filter(monster => (monster.level || 0) === this.levelIndex);
      const ids = new Set(activeMonsters.map(monster => monster.id));
      for (const [id, guardian] of this.monsterMeshes) if (!ids.has(id)) {
        this.world.remove(guardian.root); guardian.dispose(); this.monsterMeshes.delete(id);
      }
      for (const entity of activeMonsters) {
        if (!this.monsterMeshes.has(entity.id)) {
          const guardian = ['wolf', 'orc'].includes(entity.type) ? new ForestCreature(this, entity.type)
            : !entity.type || entity.type === 'listener' ? new GuardianModel(this.assets.guardian) : new ExpeditionCreature(this, entity.type);
          this.monsterMeshes.set(entity.id, guardian); this.world.add(guardian.root);
        }
        const guardian = this.monsterMeshes.get(entity.id);
        guardian.update(dt, entity, simulation.player);
        guardian.root.position.y += (entity.y ?? this.floorY) - this.floorY;
      }
      this.expedition?.update(dt, simulation, view);
      this.forest?.update(dt, simulation.player, this.clock);
      const unlocked = simulation.missionProgress?.ready ?? simulation.relics.every(relic => relic.collected);
      if (this.portal) {
        this.portal.disc.material.opacity = unlocked ? .4 : .1;
        this.portal.light.intensity = unlocked ? 65 : 20;
      }
    }
    const blackout = this.mode === 'game' && simulation?.worldEvent?.type === 'blackout' && simulation.worldEvent.phase === 'active';
    const localCamera = this.camera.position.clone(); localCamera.y -= this.floorY || 0;
    const nearest = [...this.torches].sort((a, b) => a.position.distanceToSquared(localCamera) - b.position.distanceToSquared(localCamera));
    this.nearLights.forEach((light, i) => {
      const torch = nearest[i]; light.visible = Boolean(torch) && !blackout;
      if (torch) {
        light.position.copy(torch.position); light.position.y += this.floorY || 0;
        light.intensity = (this.mode === 'menu' ? 36 : 25) * (i === 0 && this.torchKey.castShadow ? .35 : 1) * (1 + Math.sin(this.clock * 11 + torch.phase) * .07 + Math.sin(this.clock * 19 + torch.phase) * .04);
      }
    });
    const keyTorch = nearest[0];
    this.torchKey.visible = Boolean(keyTorch) && !blackout && this.torchKey.castShadow;
    if (keyTorch) {
      this.torchKey.position.copy(keyTorch.position); this.torchKey.position.y += this.floorY || 0;
      const toward = this.camera.position.clone().sub(this.torchKey.position); toward.y = -.7;
      if (toward.lengthSq() < .01) toward.set(0, -1, 0);
      this.torchKey.target.position.copy(this.torchKey.position).add(toward.normalize().multiplyScalar(4));
      this.torchKey.intensity = this.nearLights[0].intensity / .35 * 1.7;
    }
    this.updateDepthLighting(simulation, dt);
    for (const torch of this.torches) {
      const flicker = 1 + Math.sin(this.clock * 13 + torch.phase) * .15;
      torch.flame.visible = torch.glow.visible = !blackout;
      torch.flame.scale.y = 2.4 * flicker; torch.glow.material.opacity = .55 + flicker * .07;
    }
    this.relicMeshes.forEach((mesh, i) => { mesh.group.rotation.y = this.clock * .65; mesh.group.position.y = (mesh.groundY || 0) + 1.45 + Math.sin(this.clock * 1.5 + i) * .12; mesh.core.rotation.z = this.clock * .4; });
    if (this.dust) this.dust.position.y = Math.sin(this.clock * .16) * .12;
    if (this.portal) this.portal.glow.material.opacity = .4 + Math.sin(this.clock * 1.6) * .07;
    this.composer.render();
  }

  updateDepthLighting(simulation, dt) {
    const menu = this.mode === 'menu', forest = !menu && this.biomeId === 'forest';
    const cave = forest && getTerrainCave(simulation?.terrain, this.camera.position.x, this.camera.position.z);
    const floor = this.floorY || 0;
    const profiles = {
      menu: { ambient: .34, environment: .44, moon: 1.55, sky: 0xb6cbd8, haze: 0x637780, hazeDensity: .018, shafts: .5, heightFalloff: .12, heightBase: 1 },
      catacombs: { ambient: .25, environment: .22, moon: .09, sky: 0xa9bccb, haze: 0x536465, hazeDensity: .018, shafts: 0, heightFalloff: .11, heightBase: floor + .6 },
      ruins: { ambient: .38, environment: .34, moon: 1.9, sky: 0xb5cfe1, haze: 0x5d7779, hazeDensity: .012, shafts: .8, heightFalloff: .13, heightBase: floor + .5 },
      mine: { ambient: .22, environment: .2, moon: .04, sky: 0xb5afa4, haze: 0x726452, hazeDensity: .02, shafts: 0, heightFalloff: .13, heightBase: floor + .6 },
      forest: { ambient: .29, environment: .25, moon: 1.65, sky: 0xa8c8e0, haze: 0x617f8b, hazeDensity: .013, shafts: 1, heightFalloff: .1, heightBase: -1 },
      cave: { ambient: .21, environment: .18, moon: .02, sky: 0x9daea7, haze: 0x4b5652, hazeDensity: .018, shafts: 0, heightFalloff: .08, heightBase: this.camera.position.y - 1.2 },
    };
    const profile = profiles[menu ? 'menu' : cave ? 'cave' : this.biomeId] || profiles.catacombs;
    const blend = Math.min(1, dt * 3.5);
    this.ambient.intensity += (profile.ambient - this.ambient.intensity) * blend;
    this.ambient.color.lerp(new THREE.Color(profile.sky), blend);
    this.ambient.groundColor.setHex(0x292822);
    this.moon.color.setHex(0xb5d0e8);
    this.moon.intensity += (profile.moon - this.moon.intensity) * blend;
    this.scene.environmentIntensity += (profile.environment - this.scene.environmentIntensity) * blend;
    // Most atmospheric perspective comes from the actual depth buffer, leaving
    // a little ordinary fog for transparent particles and the distant sky.
    this.scene.fog.density = forest && !cave ? .006 : .009;
    this.scene.fog.color.setHex(cave ? 0x0d1517 : forest ? 0x15232c : this.biomeId === 'mine' ? 0x1b1917 : 0x172127);
    this.scene.background.copy(this.scene.fog.color);
    this.moon.castShadow = menu || (forest && !cave) || this.biomeId === 'ruins';
    // A camera-centred shadow region keeps texels on nearby objects even in 51×51 worlds.
    const x = Math.round(this.camera.position.x / 2) * 2, z = Math.round(this.camera.position.z / 2) * 2;
    const ground = forest ? getTerrainHeight(simulation.terrain, x, z) : floor;
    if (this.moon.target.position.x !== x || this.moon.target.position.z !== z || !this.moon.shadow.map
      || this.clock - (this.lastMoonShadowTime || 0) > (this.quality === 'high' ? .1 : .16)) {
      this.moon.shadow.needsUpdate = true; this.lastMoonShadowTime = this.clock;
    }
    this.moon.target.position.set(x, ground, z);
    this.moon.position.set(x - 24, ground + 42, z - 18);
    this.moon.target.updateMatrixWorld(true);
    this.atmosphere.update(this.camera, this.moon, profile);
  }

  setQuality(quality) {
    this.quality = quality === 'balanced' ? 'balanced' : 'high';
    const high = this.quality === 'high', ratio = Math.min(devicePixelRatio, high ? 1.35 : 1);
    this.renderer.setPixelRatio(ratio); this.composer.setPixelRatio(ratio);
    this.contactShadows.enabled = true;
    this.contactShadows.resolutionScale = high ? .6 : .4;
    this.contactShadows.updateGtaoMaterial({ samples: high ? 8 : 4 });
    this.contactShadows.updatePdMaterial({ samples: high ? 8 : 4 });
    this.contactShadows.blendIntensity = high ? .85 : .72;
    this.moon.shadow.mapSize.set(high ? 2048 : 1024, high ? 2048 : 1024);
    this.moon.shadow.map?.dispose(); this.moon.shadow.map = null;
    this.torchKey.castShadow = high;
    for (const target of [this.composer.renderTarget1, this.composer.renderTarget2]) {
      target.samples = high ? Math.min(4, this.renderer.capabilities.maxSamples) : 0;
      target.dispose();
    }
    this.flashlight.shadow.mapSize.set(high ? 1024 : 512, high ? 1024 : 512);
    this.flashlight.shadow.map?.dispose(); this.flashlight.shadow.map = null;
    this.resize();
  }

  resize() {
    this.camera.aspect = innerWidth / innerHeight; this.camera.updateProjectionMatrix();
    this.renderer.setSize(innerWidth, innerHeight); this.composer.setSize(innerWidth, innerHeight);
  }

  dispose() {
    window.removeEventListener('resize', this.onResize);
    this.clear(); this.assets?.dispose();
    for (const material of [this.iron, this.flameMaterial, this.relicMaterial]) material.dispose();
    this.glowMap.dispose(); this.flashlight.shadow.dispose(); this.moon.shadow.dispose(); this.torchKey.shadow.dispose();
    for (const pass of this.composer.passes) pass.dispose?.();
    this.composer.dispose(); this.renderer.dispose();
  }
}
