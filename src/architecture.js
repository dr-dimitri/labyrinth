import { BufferGeometry, ExtrudeGeometry, Float32BufferAttribute, Shape } from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { createRng } from './maze.js';

/**
 * Project texture coordinates in metres onto each triangle's dominant plane.
 * Faces have independent vertices so a bevel cannot interpolate across two
 * different projections. The original geometry object is updated and returned.
 */
export function applyMetricUvs(geometry, metersPerTile = 3.5) {
  if (!Number.isFinite(metersPerTile) || metersPerTile <= 0) {
    throw new RangeError('metersPerTile must be a positive finite number.');
  }
  if (geometry.index) {
    const expanded = geometry.toNonIndexed();
    geometry.copy(expanded);
    expanded.dispose();
  }
  const positions = geometry.getAttribute('position');
  const uv = new Float32Array(positions.count * 2);
  for (let first = 0; first < positions.count; first += 3) {
    const ax = positions.getX(first + 1) - positions.getX(first);
    const ay = positions.getY(first + 1) - positions.getY(first);
    const az = positions.getZ(first + 1) - positions.getZ(first);
    const bx = positions.getX(first + 2) - positions.getX(first);
    const by = positions.getY(first + 2) - positions.getY(first);
    const bz = positions.getZ(first + 2) - positions.getZ(first);
    const nx = ay * bz - az * by;
    const ny = az * bx - ax * bz;
    const nz = ax * by - ay * bx;
    const xDominant = Math.abs(nx) > Math.abs(ny) && Math.abs(nx) > Math.abs(nz);
    const yDominant = !xDominant && Math.abs(ny) > Math.abs(nz);
    for (let vertex = first; vertex < first + 3; vertex += 1) {
      const x = positions.getX(vertex);
      const y = positions.getY(vertex);
      const z = positions.getZ(vertex);
      if (xDominant) {
        uv[vertex * 2] = z * (nx > 0 ? -1 : 1) / metersPerTile;
        uv[vertex * 2 + 1] = y / metersPerTile;
      } else if (yDominant) {
        uv[vertex * 2] = x / metersPerTile;
        uv[vertex * 2 + 1] = z * (ny > 0 ? -1 : 1) / metersPerTile;
      } else {
        uv[vertex * 2] = x * (nz < 0 ? -1 : 1) / metersPerTile;
        uv[vertex * 2 + 1] = y / metersPerTile;
      }
    }
  }
  geometry.setAttribute('uv', new Float32BufferAttribute(uv, 2));
  return geometry;
}

/**
 * A closed block with a bevel around its front face. Twenty triangles retain
 * a crisp silhouette and grazing-light edge without tessellating hidden backs.
 * The front lies at z=0; all geometry remains behind that collision boundary.
 */
export function createReliefBlockGeometry(width, height, depth, bevel = .015) {
  if (![width, height, depth].every(value => Number.isFinite(value) && value > 0)) {
    throw new RangeError('Relief block dimensions must be positive finite numbers.');
  }
  const b = Math.max(0, Math.min(Number.isFinite(bevel) ? bevel : .015,
    width / 4, height / 4, depth / 2));
  const w = width / 2, h = height / 2;
  const vertices = [];
  const ring = (x, y, z) => [[-x, -y, z], [x, -y, z], [x, y, z], [-x, y, z]];
  const back = ring(w, h, -depth), shoulder = ring(w, h, -b), front = ring(w - b, h - b, 0);
  const quad = (a, b, c, d) => vertices.push(...a, ...b, ...c, ...a, ...c, ...d);
  quad(back[3], back[2], back[1], back[0]);
  for (let index = 0; index < 4; index++) {
    const next = (index + 1) % 4;
    quad(back[index], back[next], shoulder[next], shoulder[index]);
    quad(shoulder[index], shoulder[next], front[next], front[index]);
  }
  quad(front[0], front[1], front[2], front[3]);
  const geometry = new BufferGeometry();
  geometry.setAttribute('position', new Float32BufferAttribute(vertices, 3));
  geometry.computeVertexNormals();
  return geometry;
}

function bounded(value, fallback, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, Number.isFinite(value) ? value : fallback));
}

/**
 * One draw-call masonry arch. The origin is on the floor beneath the opening;
 * the arch lies in XY, with its depth centred on Z. radius is measured to the
 * centre of the stone ring and both column centres, not its outside edge.
 */
export function createArchGeometry({
  radius = 2.06, pillar = 2.15, depth = 0.6, thickness = 0.28, seed = 'arch',
} = {}) {
  radius = bounded(radius, 2.06, 0.6, 20);
  pillar = bounded(pillar, 2.15, 0.4, 20);
  depth = bounded(depth, 0.6, 0.12, 4);
  thickness = bounded(thickness, 0.28, 0.08, radius * 0.65);
  const random = createRng(seed);
  const pieces = [];
  const bevel = Math.min(0.015, thickness * 0.055, depth * 0.1);
  const mortarGap = 0.015;

  function addStone(geometry) {
    // Restrained, reproducible warm/cool changes remain visible under a shared
    // PBR material while retaining a single material and mesh for the arch.
    const shade = 0.91 + random() * 0.085;
    const warmth = (random() - 0.5) * 0.025;
    const colors = new Float32Array(geometry.getAttribute('position').count * 3);
    for (let vertex = 0; vertex < colors.length; vertex += 3) {
      colors[vertex] = Math.min(1, shade + warmth);
      colors[vertex + 1] = shade;
      colors[vertex + 2] = Math.min(1, shade - warmth);
    }
    geometry.setAttribute('color', new Float32BufferAttribute(colors, 3));
    pieces.push(geometry);
  }

  function addBlock(width, height, blockDepth, x, y) {
    const stone = new RoundedBoxGeometry(width, height, blockDepth, 1, bevel);
    stone.translate(x, y, 0);
    addStone(stone);
  }

  // Individual courses, wider plinths and projecting capitals catch grazing
  // light and give the supporting columns a readable stone silhouette.
  const baseHeight = Math.min(0.18, pillar * 0.12);
  const capitalHeight = Math.min(0.14, pillar * 0.1);
  const shaftBottom = baseHeight + mortarGap;
  const shaftTop = pillar - capitalHeight - mortarGap;
  const courses = Math.min(12, Math.max(2, Math.round((shaftTop - shaftBottom) / 0.34)));
  const courseHeight = (shaftTop - shaftBottom) / courses;
  for (const side of [-1, 1]) {
    const x = side * radius;
    addBlock(thickness * 1.48, baseHeight, depth * 1.1, x, baseHeight / 2);
    for (let course = 0; course < courses; course += 1) {
      const width = thickness * (0.98 + random() * 0.035);
      addBlock(width, courseHeight - mortarGap, depth, x,
        shaftBottom + courseHeight * (course + 0.5));
    }
    addBlock(thickness * 1.35, capitalHeight, depth * 1.07,
      x, pillar - capitalHeight / 2);
  }

  const innerRadius = radius - thickness / 2;
  const outerRadius = radius + thickness / 2;
  // An odd count puts a complete keystone at the crown. Larger entrance
  // arches use 27 voussoirs; corridor arches use 21.
  const wedgeCount = Math.min(27, Math.max(21, Math.round(17 + radius * 2) | 1));
  const step = Math.PI / wedgeCount;
  // Extrude bevels expand beyond the shape contour, so reserve that space in
  // addition to the visible joint to keep adjacent stones separate.
  const halfJointAngle = (mortarGap + bevel * 2) / innerRadius / 2;
  for (let index = 0; index < wedgeCount; index += 1) {
    const start = index * step + halfJointAngle;
    const end = (index + 1) * step - halfJointAngle;
    const shape = new Shape();
    shape.moveTo(Math.cos(start) * outerRadius, Math.sin(start) * outerRadius);
    shape.absarc(0, 0, outerRadius, start, end, false);
    shape.lineTo(Math.cos(end) * innerRadius, Math.sin(end) * innerRadius);
    shape.absarc(0, 0, innerRadius, end, start, true);
    shape.closePath();
    const stone = new ExtrudeGeometry(shape, {
      depth: depth - bevel * 2,
      steps: 1,
      curveSegments: 2,
      bevelEnabled: true,
      bevelThickness: bevel,
      bevelSize: bevel,
      bevelSegments: 1,
    });
    stone.translate(0, pillar, -depth / 2 + bevel);
    addStone(stone);
  }

  const geometry = mergeGeometries(pieces, false);
  for (const piece of pieces) piece.dispose();
  applyMetricUvs(geometry);
  geometry.clearGroups();
  geometry.computeBoundingBox();
  geometry.computeBoundingSphere();
  geometry.name = 'Jointed stone arch';
  geometry.userData.arch = { radius, innerRadius, outerRadius, pillar, depth,
    thickness, wedgeCount, stoneCount: pieces.length };
  return geometry;
}
