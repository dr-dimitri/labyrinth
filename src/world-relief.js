import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { applyMetricUvs, createReliefBlockGeometry } from './architecture.js';
import { createRng, walkable } from './maze.js';

const CELL = 3.6;
const CHUNK = 8;
const DIRECTIONS = [[0, 1], [1, 0], [0, -1], [-1, 0]];
const key = (x, z) => `${x},${z}`;

function join(pieces, metersPerTile = 3.5) {
  const geometry = mergeGeometries(pieces, false);
  pieces.forEach(piece => piece.dispose());
  applyMetricUvs(geometry, metersPerTile);
  geometry.computeBoundingBox(); geometry.computeBoundingSphere();
  return geometry;
}

function stone(pieces, width, height, depth, x, y, z, random, bevel = .012) {
  const geometry = createReliefBlockGeometry(width, height, depth, bevel);
  geometry.translate(x, y, z);
  const shade = .86 + random() * .14;
  geometry.setAttribute('color', new THREE.Float32BufferAttribute(
    new Float32Array(geometry.attributes.position.count * 3).fill(shade), 3));
  pieces.push(geometry);
  return geometry;
}

/** The positive-Z face meets, but never crosses, the original wall boundary. */
export function createWallReliefGeometry({ height = 4.1, variant = 0, mine = false, ruins = false } = {}) {
  const random = createRng(`wall-relief:${variant}:${height}:${mine}:${ruins}`), pieces = [];
  // Floor/ceiling planes end at the blocked cell boundary. Their join must
  // overlap a square edge: beveled stones alone leave a slit to the sky behind
  // the inset structural core. These continuous caps close that slit while
  // staying wholly inside the blocked cell, including at neighboring faces.
  for (const y of [.02, height - .11]) {
    const box = new THREE.BoxGeometry(CELL, .22, .3);
    const cap = box.toNonIndexed(); box.dispose();
    cap.deleteAttribute('uv'); // All pieces receive metric UVs after merging.
    cap.translate(0, y, -.15);
    const position = cap.attributes.position;
    for (let vertex = 0; vertex < position.count; vertex++) {
      position.setZ(vertex, Math.min(0, position.getZ(vertex)));
    }
    cap.setAttribute('color', new THREE.Float32BufferAttribute(
      new Float32Array(cap.attributes.position.count * 3).fill(.92), 3));
    pieces.push(cap);
  }
  const rows = mine ? 3 : Math.max(3, Math.round((height - .38) / .62));
  const bottom = .24, rowHeight = (height - .42) / rows;
  for (let row = 0; row < rows; row++) {
    // Alternating half stones produce real recessed mortar joints. Variants
    // vary face depths rather than deforming the photograph's metric scale.
    const columns = 3;
    const step = CELL / columns;
    const cuts = [-CELL / 2];
    const offset = row % 2 ? step * .5 : 0;
    for (let cut = 1; cut <= columns; cut++) {
      const value = -CELL / 2 + cut * step - offset;
      if (value > -CELL / 2 + .001 && value < CELL / 2 - .001) cuts.push(value);
    }
    cuts.push(CELL / 2);
    for (let column = 0; column < cuts.length - 1; column++) {
      const gap = mine ? .014 : .025;
      const width = cuts[column + 1] - cuts[column] - gap;
      let blockHeight = rowHeight - gap;
      if (ruins && row === rows - 1) blockHeight *= .58 + random() * .42;
      const front = -.006 - random() * (mine ? .064 : .045);
      const block = stone(pieces, width, blockHeight, .17 + front,
        (cuts[column + 1] + cuts[column]) / 2,
        bottom + row * rowHeight + blockHeight / 2, front, random, mine ? .07 : .013);
      if (mine) {
        const position = block.attributes.position;
        // Broad irregular planes break up the rectangular core without
        // displacing the traversable boundary or opening cracks to daylight.
        for (let vertex = 0; vertex < position.count; vertex++) {
          const px = position.getX(vertex), py = position.getY(vertex);
          const recess = (Math.sin(px * 4.1 + py * 2.7 + variant) + 1) * .018;
          position.setZ(vertex, position.getZ(vertex) - recess);
        }
        block.computeVertexNormals();
      }
    }
  }
  if (!mine) {
    // Heavy footings, a narrow string course and projecting cornice create
    // separate planes even before a torch illuminates individual joints.
    for (let column = 0; column < 4; column++) {
      const x = -.5 * CELL + CELL / 4 * (column + .5);
      stone(pieces, CELL / 4 - .012, .19, .27, x, .105, -.002, random, .018);
      stone(pieces, CELL / 4 - .012, .09, .19, x, height - .1, -.002, random, .009);
    }
    stone(pieces, CELL - .015, .075, .21, 0, 1.3, -.003, random, .008);
    if (variant === 1) {
      for (let course = 0; course < rows; course++) {
        stone(pieces, .26, rowHeight - .015, .29, 0,
          bottom + rowHeight * (course + .5), -.001, random, .015);
      }
    }
  }
  const geometry = join(pieces, mine ? 2.38 : 3.5);
  geometry.name = mine ? 'Recessed natural rock face' : 'Jointed masonry facing';
  return geometry;
}

/** Small, bevelled paving joints catch light; all raised edges are below 3 cm. */
export function createPavingReliefGeometry(variant = 0) {
  const random = createRng(`paving-relief:${variant}`), pieces = [];
  for (let row = 0; row < 3; row++) for (let column = 0; column < 3; column++) {
    const block = stone(pieces, 1.185, 1.185, .045, 0, 0, 0, random, .009);
    block.rotateX(-Math.PI / 2);
    block.translate((column - 1) * 1.2, .017 + random() * .008, (row - 1) * 1.2);
  }
  const geometry = join(pieces, 1.8);
  geometry.name = 'Low relief paving joints';
  return geometry;
}

/** Real overhead ribs stay above head height and leave the entire floor clear. */
export function createOverheadRibGeometry({ mine = false } = {}) {
  const random = createRng(`overhead:${mine}`), pieces = [];
  function beam(width, height, depth, x, y, angle = 0) {
    const geometry = stone(pieces, width, height, depth, 0, 0, depth / 2, random, .017);
    geometry.rotateZ(angle); geometry.translate(x, y, 0);
  }
  if (mine) {
    for (const side of [-1, 1]) {
      beam(.35, 3.7, .42, side * 2.015, 1.85);
      beam(.23, 1.02, .3, side * 1.55, 3.32, side * -.75);
    }
    beam(4.4, .35, .46, 0, 3.86);
  } else {
    // A shallow pointed vault differs from the round arches at doorways.
    // Its repeated ribs supply near/middle/far occlusion along long corridors.
    const points = [[-2.02, 3.12], [-1.3, 3.83], [0, 4.36], [1.3, 3.83], [2.02, 3.12]];
    for (let index = 0; index < points.length - 1; index++) {
      const [ax, ay] = points[index], [bx, by] = points[index + 1];
      const length = Math.hypot(bx - ax, by - ay);
      beam(length + .045, .22, .38, (ax + bx) / 2, (ay + by) / 2, Math.atan2(by - ay, bx - ax));
    }
    for (const side of [-1, 1]) beam(.29, .66, .44, side * 2.005, 2.96);
  }
  const geometry = join(pieces, mine ? 1.5 : 3.5);
  geometry.name = mine ? 'Timber portal with diagonal braces' : 'Pointed stone vault rib';
  return geometry;
}

/**
 * Shared relief modules are instanced in spatial chunks, not as thousands of
 * individual props. Walls stay wholly inside blocked cells; shaft tiles are
 * excluded from every floor and overhead addition.
 */
export class WorldRelief {
  constructor(world, maze, simulation = null, { menu = false, wallHeight = 4.1, nicheCells = new Set() } = {}) {
    this.root = new THREE.Group(); this.root.name = 'Physical architectural relief';
    this.materials = new Set(); this.batches = [];
    world.world.add(this.root);
    const biome = world.biomeId || simulation?.config?.biome || 'catacombs';
    const mine = biome === 'mine', ruins = biome === 'ruins';
    const level = world.levelIndex || 0;
    const shafts = new Set((simulation?.ladders || [])
      .filter(ladder => ladder.fromLevel === level || ladder.toLevel === level)
      .map(ladder => key(Math.round(ladder.x / CELL), Math.round(ladder.z / CELL))));
    const materials = {
      wall: this.clone(mine ? (world.assets.forest?.rock || world.stone) : world.stone,
        mine ? 0x9b8d79 : ruins ? 0xaebca0 : 0xffffff),
      floor: this.clone(world.assets.floor, ruins ? 0xa6b091 : mine ? 0xa99a83 : 0xffffff),
      rib: this.clone(mine ? (world.assets.forest?.bark || world.trim) : world.trim,
        mine ? 0x928775 : 0xc7c3b5),
    };
    const definitions = new Map();
    const add = (type, x, z, angle, variant = 0) => {
      const chunkX = Math.floor(x / CELL / CHUNK), chunkZ = Math.floor(z / CELL / CHUNK);
      // One material/geometry draw per type in each chunk; neighboring chunks
      // use different stone patterns without tripling every draw call.
      variant = type === 'rib' ? 0 : Math.abs(chunkX * 13 + chunkZ * 7) % 3;
      const id = `${type}:${variant}:${chunkX}:${chunkZ}`;
      if (!definitions.has(id)) definitions.set(id, { type, variant, chunkX, chunkZ, poses: [] });
      definitions.get(id).poses.push({ x, z, angle });
    };
    for (let z = 0; z < maze.size; z++) for (let x = 0; x < maze.size; x++) {
      const variant = (x * 13 + z * 7) % 3;
      if (!walkable(maze, x, z)) {
        if (nicheCells.has(key(x, z))) continue;
        for (const [dx, dz] of DIRECTIONS) if (walkable(maze, x + dx, z + dz)) {
          add('wall', x * CELL + dx * CELL / 2, z * CELL + dz * CELL / 2, Math.atan2(dx, dz), variant);
        }
        continue;
      }
      if (shafts.has(key(x, z))) continue;
      if (!mine) add('floor', x * CELL, z * CELL, 0, variant);
      // Existing round arches use x=z=1 mod 4. Place the pointed ribs in
      // intervening bays; mine portals alternate with the existing rail props.
      if (menu || (x + z) % 4 !== (mine ? 2 : 0)) continue;
      const northSouth = walkable(maze, x, z - 1) && walkable(maze, x, z + 1)
        && !walkable(maze, x - 1, z) && !walkable(maze, x + 1, z);
      const eastWest = walkable(maze, x - 1, z) && walkable(maze, x + 1, z)
        && !walkable(maze, x, z - 1) && !walkable(maze, x, z + 1);
      if (northSouth || eastWest) add('rib', x * CELL, z * CELL, northSouth ? 0 : Math.PI / 2);
    }
    const geometries = new Map(), transform = new THREE.Object3D();
    for (const { type, variant, chunkX, chunkZ, poses } of definitions.values()) {
      const geometryKey = `${type}:${variant}`;
      if (!geometries.has(geometryKey)) geometries.set(geometryKey,
        type === 'wall' ? createWallReliefGeometry({ height: wallHeight, mine, ruins, variant })
          : type === 'floor' ? createPavingReliefGeometry(variant) : createOverheadRibGeometry({ mine }));
      const mesh = new THREE.InstancedMesh(geometries.get(geometryKey), materials[type], poses.length);
      mesh.name = `Relief ${type} ${chunkX},${chunkZ}`;
      poses.forEach(({ x, z, angle }, index) => {
        transform.position.set(x, 0, z); transform.rotation.set(0, angle, 0); transform.updateMatrix();
        mesh.setMatrixAt(index, transform.matrix);
      });
      mesh.castShadow = type !== 'floor'; mesh.receiveShadow = true;
      mesh.computeBoundingBox(); mesh.computeBoundingSphere();
      mesh.userData.reliefType = type;
      this.root.add(mesh); this.batches.push(mesh);
    }
  }

  clone(source, color) {
    const material = source.clone(); material.color.setHex(color);
    material.vertexColors = true; material.displacementScale = 0; material.displacementBias = 0;
    this.materials.add(material); return material;
  }

  // WorldRenderer.clear owns all mounted geometry and instance buffers.
  dispose() { this.materials.forEach(material => material.dispose()); this.materials.clear(); }
}
