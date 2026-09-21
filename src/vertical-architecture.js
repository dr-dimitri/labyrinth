import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { applyMetricUvs } from './architecture.js';

const CELL = 3.6;
const OPENING = 2.2;
const dummy = new THREE.Object3D();

/** An actual hole, not a dark decal: the camera and light see through the landing. */
export function createLandingTile({ cell = CELL, opening = OPENING, ceiling = false } = {}) {
  const edge = (cell - opening) / 2;
  const patches = [
    [edge, cell, -(opening + edge) / 2, 0], [edge, cell, (opening + edge) / 2, 0],
    [opening, edge, 0, -(opening + edge) / 2], [opening, edge, 0, (opening + edge) / 2],
  ].map(([width, depth, x, z]) => {
    const geometry = new THREE.PlaneGeometry(width, depth, 4, 4);
    geometry.rotateX(ceiling ? Math.PI / 2 : -Math.PI / 2);
    geometry.translate(x, 0, z);
    return geometry;
  });
  const merged = mergeGeometries(patches, false);
  patches.forEach(geometry => geometry.dispose());
  return applyMetricUvs(merged, ceiling ? 3.5 : 1.8);
}

/** Exact triangle check keeps nearby rings whose bounding boxes span empty space. */
export function meshIntersectsOpening(object, opening) {
  const geometry = object.geometry;
  geometry.computeBoundingBox();
  if (!opening.intersectsBox(geometry.boundingBox.clone().applyMatrix4(object.matrixWorld))) return false;
  const position = geometry.getAttribute('position'), index = geometry.index;
  const triangle = new THREE.Triangle();
  const count = index?.count || position.count;
  for (let first = 0; first < count; first += 3) {
    triangle.a.fromBufferAttribute(position, index ? index.getX(first) : first).applyMatrix4(object.matrixWorld);
    triangle.b.fromBufferAttribute(position, index ? index.getX(first + 1) : first + 1).applyMatrix4(object.matrixWorld);
    triangle.c.fromBufferAttribute(position, index ? index.getX(first + 2) : first + 2).applyMatrix4(object.matrixWorld);
    if (opening.intersectsTriangle(triangle)) return true;
  }
  return false;
}

/** The active floor stays light; only a small real landing is drawn across each shaft. */
export class VerticalArchitecture {
  constructor(world, simulation) {
    this.world = world; this.root = new THREE.Group(); this.root.name = 'Ladder shafts and landings';
    world.world.add(this.root);
    this.geometries = new Set(); this.materials = new Set(); this.textures = new Set();
    this.ladders = new Map(); this.level = simulation.player.level || 0;
    this.baseY = simulation.levels?.[this.level]?.y || 0;
    this.metal = this.material({ color: 0x293732, metalness: .55, roughness: .8 });
    this.edge = this.material({ color: 0x635e42, metalness: .45, roughness: .84 });
    this.lightMaterial = this.material({ color: 0xbadbd0, emissive: 0x78b2a2, emissiveIntensity: 1.4, roughness: .4 });
    this.previewFloor = world.assets.floor.clone(); this.previewFloor.vertexColors = false; this.materials.add(this.previewFloor);
    this.previewWall = world.stone.clone(); this.previewWall.vertexColors = false; this.materials.add(this.previewWall);
    for (const ladder of simulation.ladders || []) {
      if (ladder.fromLevel !== this.level && ladder.toLevel !== this.level) continue;
      this.addLadder(ladder, simulation);
    }
  }

  material(parameters) { const material = new THREE.MeshStandardMaterial(parameters); this.materials.add(material); return material; }
  mesh(geometry, material, x, y, z, parent = this.root) {
    this.geometries.add(geometry); return this.world.mesh(geometry, material, x, y, z, parent);
  }
  box(w, h, d, material, x, y, z, parent) {
    const geometry = applyMetricUvs(new THREE.BoxGeometry(w, h, d), 3.5);
    return this.mesh(geometry, material, x, y, z, parent);
  }
  sign(text, x, y, z, parent) {
    const canvas = document.createElement('canvas'); canvas.width = 512; canvas.height = 160;
    const context = canvas.getContext('2d');
    context.fillStyle = '#172522'; context.fillRect(0, 0, 512, 160);
    context.strokeStyle = '#adbaa0'; context.lineWidth = 5; context.strokeRect(9, 9, 494, 142);
    context.textAlign = 'center'; context.fillStyle = '#e0e7ce';
    context.font = '600 34px system-ui'; context.fillText(text, 256, 65);
    context.font = '24px system-ui'; context.fillText('E · KLETTERN', 256, 112);
    const texture = new THREE.CanvasTexture(canvas); texture.colorSpace = THREE.SRGBColorSpace; this.textures.add(texture);
    const material = new THREE.MeshBasicMaterial({ map: texture, color: 0xc5d2c5 });
    this.materials.add(material);
    this.mesh(new THREE.PlaneGeometry(1.4, .44), material, x, y, z, parent);
  }

  addLadder(ladder, simulation) {
    const group = new THREE.Group(); group.position.set(ladder.x, 0, ladder.z); this.root.add(group);
    const bottom = ladder.bottomY - this.baseY, top = ladder.topY - this.baseY;
    // Rails extend above the landing, giving the climb a recognizable handhold.
    for (const x of [-.48, .48]) this.box(.075, top - bottom + .95, .075, this.metal, x, (bottom + top + .95) / 2, -.7, group);
    const rungs = Math.ceil((top - bottom) / .3) + 1;
    const rungGeometry = new THREE.CylinderGeometry(.027, .027, 1.03, 10);
    rungGeometry.rotateZ(Math.PI / 2); this.geometries.add(rungGeometry);
    const rungMesh = new THREE.InstancedMesh(rungGeometry, this.edge, rungs);
    for (let i = 0; i < rungs; i++) {
      dummy.position.set(0, bottom + .22 + i * .3, -.7); dummy.rotation.set(0, 0, 0); dummy.scale.set(1, 1, 1); dummy.updateMatrix();
      rungMesh.setMatrixAt(i, dummy.matrix);
    }
    rungMesh.castShadow = rungMesh.receiveShadow = true; group.add(rungMesh);
    // Stone lining bridges the structural space between the ceiling and next floor.
    const shaftBase = bottom + 4.1, shaftHeight = top - shaftBase;
    for (const sign of [-1, 1]) {
      this.box(.24, shaftHeight, 2.68, this.previewWall, sign * 1.22, shaftBase + shaftHeight / 2, 0, group);
      this.box(2.2, shaftHeight, .24, this.previewWall, 0, shaftBase + shaftHeight / 2, sign * 1.22, group);
      this.box(.07, .08, 2.24, this.edge, sign * 1.12, top + .035, 0, group);
      this.box(2.3, .08, .07, this.edge, 0, top + .035, sign * 1.12, group);
      // Striped landing corners mark the opening without enclosing the approach.
      this.box(.09, .11, .32, this.lightMaterial, sign * 1.22, top + .065, 1.26, group);
      this.box(.075, .1, .075, this.lightMaterial, sign * .48, top + .94, -.7, group);
    }
    const upward = ladder.fromLevel === this.level;
    this.sign(`${upward ? '↑' : '↓'} EBENE ${(upward ? ladder.toLevel : ladder.fromLevel) + 1}`, 0, upward ? 2.55 : 1.05, -.66, group);
    const light = new THREE.PointLight(0x9ac8bd, 9, 8, 2); light.position.set(0, top + 1.8, .1); group.add(light);
    const otherLevel = upward ? ladder.toLevel : ladder.fromLevel;
    const patch = this.addLandingPatch(ladder, simulation.levels?.[otherLevel], simulation);
    this.ladders.set(ladder.id, { group, patch, light });
  }

  addLandingPatch(ladder, definition, simulation) {
    if (!definition) return null;
    const patch = new THREE.Group(); patch.position.y = definition.y - this.baseY; patch.name = `Landing preview level ${definition.index + 1}`;
    this.root.add(patch);
    const maze = definition.maze, cx = Math.round(ladder.x / CELL), cz = Math.round(ladder.z / CELL);
    const floorCells = [], wallCells = [];
    for (let z = Math.max(0, cz - 2); z <= Math.min(maze.size - 1, cz + 2); z++) {
      for (let x = Math.max(0, cx - 2); x <= Math.min(maze.size - 1, cx + 2); x++) {
        if (x === cx && z === cz) continue;
        (maze.grid[z][x] ? wallCells : floorCells).push({ x, z });
      }
    }
    const floorGeometry = new THREE.PlaneGeometry(CELL, CELL, 3, 3); floorGeometry.rotateX(-Math.PI / 2); applyMetricUvs(floorGeometry, 1.8);
    this.instances(floorGeometry, this.previewFloor, floorCells, 0, patch);
    const height = this.world.biomeId === 'ruins' ? 3.4 : 4.1;
    const wallGeometry = applyMetricUvs(new THREE.BoxGeometry(CELL, height, CELL), 3.5);
    this.instances(wallGeometry, this.previewWall, wallCells, height / 2, patch);
    const isUpper = definition.index === ladder.toLevel;
    this.mesh(isUpper ? createLandingTile() : floorGeometry.clone(), this.previewFloor, ladder.x, 0, ladder.z, patch);
    // The lower landing ceiling also has its opening; all surrounding tiles mask
    // unreconstructed rooms until the active floor changes at the end of climbing.
    const enclosed = this.world.biomeId !== 'ruins' || definition.index < simulation.levels.length - 1;
    if (enclosed) {
      const ceilingGeometry = new THREE.PlaneGeometry(CELL, CELL); ceilingGeometry.rotateX(Math.PI / 2); applyMetricUvs(ceilingGeometry, 3.5);
      this.instances(ceilingGeometry, this.world.assets.ceiling, floorCells, 4.5, patch);
      this.mesh(isUpper ? ceilingGeometry.clone() : createLandingTile({ ceiling: true }), this.world.assets.ceiling, ladder.x, 4.5, ladder.z, patch);
    }
    return patch;
  }

  instances(geometry, material, cells, y, parent) {
    this.geometries.add(geometry);
    const mesh = new THREE.InstancedMesh(geometry, material, cells.length);
    cells.forEach((cell, index) => {
      dummy.position.set(cell.x * CELL, y, cell.z * CELL); dummy.rotation.set(0, 0, 0); dummy.scale.set(1, 1, 1); dummy.updateMatrix();
      mesh.setMatrixAt(index, dummy.matrix);
    });
    mesh.castShadow = mesh.receiveShadow = true; parent.add(mesh);
  }

  dispose() {
    this.root.traverse(object => { if (object.isInstancedMesh) object.dispose(); });
    this.root.removeFromParent(); this.root.clear();
    this.geometries.forEach(geometry => geometry.dispose()); this.materials.forEach(material => material.dispose()); this.textures.forEach(texture => texture.dispose());
  }
}
