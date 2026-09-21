import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root));
const json = (path) => JSON.parse(read(path));
const textures = json('docs/texture-sources.json');
const models = json('docs/model-environment-sources.json');
const creature = json('docs/model-creature-sources.json');
const forestAssets = json('docs/forest-asset-sources.json');

function verifiedFile(metadata, path = metadata.path) {
  assert.match(path, /^public\/assets\//);
  assert.ok(!path.includes('..'));
  const data = read(path);
  assert.equal(data.length, metadata.bytes, `${path}: recorded byte length`);
  assert.equal(createHash('sha256').update(data).digest('hex'), metadata.sha256,
    `${path}: SHA-256 must match the source manifest`);
  return data;
}

// Read JPEG dimensions directly; these integrity tests need no image or browser runtime.
function jpegDimensions(data) {
  assert.equal(data.readUInt16BE(0), 0xffd8, 'JPEG SOI signature');
  assert.equal(data.readUInt16BE(data.length - 2), 0xffd9, 'JPEG EOI signature');
  let offset = 2;
  while (offset + 4 <= data.length) {
    assert.equal(data[offset], 0xff, 'JPEG marker');
    while (data[offset] === 0xff) offset += 1;
    const marker = data[offset++];
    assert.notEqual(marker, 0xda, 'JPEG must have a frame before scan data');
    const length = data.readUInt16BE(offset);
    assert.ok(length >= 2 && offset + length <= data.length, 'JPEG segment bounds');
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      return [data.readUInt16BE(offset + 5), data.readUInt16BE(offset + 3)];
    }
    offset += length;
  }
  assert.fail('Missing JPEG dimensions');
}

function parseGlb(data) {
  assert.equal(data.toString('ascii', 0, 4), 'glTF');
  assert.equal(data.readUInt32LE(4), 2, 'GLB version');
  assert.equal(data.readUInt32LE(8), data.length, 'Complete GLB file');
  const chunks = [];
  let offset = 12;
  while (offset < data.length) {
    assert.ok(offset + 8 <= data.length, 'Complete GLB chunk header');
    const length = data.readUInt32LE(offset);
    const type = data.readUInt32LE(offset + 4);
    assert.equal(length % 4, 0, 'GLB chunk alignment');
    assert.ok(offset + 8 + length <= data.length, 'Complete GLB chunk');
    chunks.push({ type, data: data.subarray(offset + 8, offset + 8 + length) });
    offset += 8 + length;
  }
  assert.equal(chunks.length, 2, 'Self-contained JSON and binary chunks');
  assert.equal(chunks[0].type, 0x4e4f534a, 'JSON chunk');
  assert.equal(chunks[1].type, 0x004e4942, 'BIN chunk');
  const document = JSON.parse(chunks[0].data.toString('utf8'));
  assert.equal(document.asset.version, '2.0');
  assert.equal(document.buffers.length, 1);
  assert.ok(document.buffers[0].byteLength <= chunks[1].data.length);
  assert.ok(chunks[1].data.length - document.buffers[0].byteLength <= 3);
  for (const resource of [...document.buffers, ...(document.images ?? [])]) {
    assert.equal(resource.uri, undefined, 'No external URI: assets must load offline');
  }
  for (const view of document.bufferViews) {
    assert.equal(view.buffer, 0);
    assert.ok(view.byteLength > 0);
    assert.ok((view.byteOffset ?? 0) >= 0);
    assert.ok((view.byteOffset ?? 0) + view.byteLength <= document.buffers[0].byteLength,
      'Buffer view must stay inside the embedded buffer');
  }
  for (const accessor of document.accessors) {
    const bytes = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4 }[accessor.componentType];
    const components = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16 }[accessor.type];
    const view = document.bufferViews[accessor.bufferView];
    assert.ok(view && bytes && components && accessor.count > 0, 'Valid mesh accessor');
    const stride = view.byteStride ?? bytes * components;
    assert.ok((accessor.byteOffset ?? 0) + (accessor.count - 1) * stride
      + bytes * components <= view.byteLength, 'Accessor fits its buffer view');
  }
  return { document, binary: chunks[1].data };
}

function accessorValues(document, binary, index) {
  const accessor = document.accessors[index];
  const view = document.bufferViews[accessor.bufferView];
  const components = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16 }[accessor.type];
  const [bytes, method] = {
    5123: [2, 'readUInt16LE'], 5125: [4, 'readUInt32LE'], 5126: [4, 'readFloatLE'],
  }[accessor.componentType];
  const stride = view.byteStride ?? bytes * components;
  const start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
  const values = [];
  for (let element = 0; element < accessor.count; element += 1) {
    for (let component = 0; component < components; component += 1) {
      values.push(binary[method](start + element * stride + component * bytes));
    }
  }
  return values;
}

for (const material of ['wall', 'floor']) {
  test(`${material} has five complete 2K photographic maps with matching provenance`, () => {
    const entry = textures.materials[material];
    assert.equal(entry.license, 'CC0-1.0');
    assert.ok(entry.authors.length > 0);
    assert.match(entry.pageURL, /^https:\/\/polyhaven.com\/a\//);
    assert.deepEqual(Object.keys(entry.files).sort(), ['ao', 'color', 'height', 'normal', 'roughness']);
    for (const [role, file] of Object.entries(entry.files)) {
      assert.equal(file.path, `public/assets/textures/${material}/${role}.jpg`);
      assert.deepEqual(jpegDimensions(verifiedFile(file)), [2048, 2048]);
      assert.equal(file.colorSpace, role === 'color' ? 'sRGB' : 'linear');
      assert.match(file.downloadedURL, /^https:\/\/dl.polyhaven.org\//);
    }
    assert.equal(entry.files.normal.normalConvention, 'OpenGL (+Y)');
  });
}

for (const material of ['forest-ground','forest-bark','forest-rock','forest-earth']) {
  test(`${material} has intact 2K photographic maps with recorded sources`, () => {
    const entry = forestAssets.materials[material];
    assert.equal(entry.license,'CC0-1.0');
    assert.ok(Object.keys(entry.authors).length > 0);
    assert.deepEqual(Object.keys(entry.files).sort(),['ao','color','height','normal','roughness']);
    for (const [role,file] of Object.entries(entry.files)) {
      assert.equal(file.path,`public/assets/textures/${material}/${role}.jpg`);
      assert.deepEqual(jpegDimensions(verifiedFile(file)),[2048,2048]);
      assert.equal(file.colorSpace,role === 'color' ? 'sRGB' : 'linear');
    }
    assert.equal(entry.files.normal.normalConvention,'OpenGL (+Y)');
  });
}

test('scanned fern keeps four complete original variants and an offline alpha mask', () => {
  const entry = forestAssets.models[0];
  assert.equal(entry.license,'CC0-1.0');
  assert.deepEqual(jpegDimensions(verifiedFile(entry.alpha)),[1024,1024]);
  const {document,binary} = parseGlb(verifiedFile(entry));
  assert.equal(document.meshes.length,4);
  assert.equal(document.nodes.length,4);
  const triangles = document.meshes.map(mesh => mesh.primitives.reduce((sum,p) => sum+document.accessors[p.indices].count/3,0));
  assert.deepEqual(triangles,[2384,2248,784,816]);
  for (const image of document.images) {
    const view = document.bufferViews[image.bufferView];
    assert.deepEqual(jpegDimensions(binary.subarray(view.byteOffset,view.byteOffset+view.byteLength)),[1024,1024]);
  }
});

test('night illumination contains the complete licensed Radiance HDR', () => {
  const entry = textures.environment;
  assert.equal(entry.license, 'CC0-1.0');
  const header = verifiedFile(entry).subarray(0, 1024).toString('ascii');
  assert.match(header, /^#\?(RADIANCE|RGBE)\r?\n/);
  assert.match(header, /FORMAT=32-bit_rle_rgbe/);
  assert.match(header, /-Y 512 \+X 1024/);
});

for (const name of ['statue', 'rock']) {
  test(`${name} is an intact offline GLB with geometry and embedded 2K PBR maps`, () => {
    const path = `public/assets/models/environment/${name}.glb`;
    const metadata = models.assets.find((entry) => entry.localPath === path);
    assert.ok(metadata, 'Model source manifest entry');
    assert.equal(models.license, 'CC0-1.0');
    assert.ok(Object.keys(metadata.authorCredits).length > 0);
    const { document, binary } = parseGlb(verifiedFile(metadata, path));
    assert.ok(document.scenes[document.scene].nodes.length > 0);
    assert.ok(document.meshes.length > 0);
    let triangles = 0;
    for (const mesh of document.meshes) {
      assert.ok(mesh.primitives.length > 0);
      for (const primitive of mesh.primitives) {
        assert.equal(primitive.mode ?? 4, 4, 'Triangle geometry');
        for (const attribute of ['POSITION', 'NORMAL', 'TEXCOORD_0']) {
          assert.ok(document.accessors[primitive.attributes[attribute]], `${attribute} geometry`);
        }
        assert.ok(document.materials[primitive.material], 'Mesh material');
        const indices = document.accessors[primitive.indices];
        assert.ok(indices.count > 0 && indices.count % 3 === 0);
        triangles += indices.count / 3;
      }
    }
    assert.equal(triangles, metadata.triangles);
    assert.ok(triangles <= 30000, 'Environment geometry budget');
    for (const material of document.materials) {
      const pbr = material.pbrMetallicRoughness;
      for (const reference of [pbr.baseColorTexture, pbr.metallicRoughnessTexture,
        material.normalTexture, material.occlusionTexture]) {
        const texture = document.textures[reference?.index];
        assert.ok(texture, 'PBR map is connected');
        const image = document.images[texture.source];
        assert.equal(image.mimeType, 'image/jpeg');
        const view = document.bufferViews[image.bufferView];
        const start = view.byteOffset ?? 0;
        assert.deepEqual(jpegDimensions(binary.subarray(start, start + view.byteLength)), [2048, 2048]);
      }
    }
  });
}

test('guardian source files and ten stone texture maps match their CC0 manifest', () => {
  assert.equal(creature.license, 'CC0-1.0');
  assert.ok(creature.author && creature.textureAuthor);
  assert.equal(creature.files.length, 11);
  const expectedImages = ['carved-ao.png', 'carved-normal.png', ...['rough', 'smooth']
    .flatMap((material) => ['color', 'normal', 'roughness', 'ao'].map((role) => `${material}-${role}.jpg`))];
  for (const filename of ['stone-guardian.glb', ...expectedImages]) {
    const path = `public/assets/models/creature/${filename}`;
    const metadata = creature.files.find((entry) => entry.path === path);
    assert.ok(metadata, `${filename}: source record`);
    const data = verifiedFile(metadata);
    if (filename.endsWith('.jpg')) assert.deepEqual(jpegDimensions(data), [1024, 1024]);
    if (filename.endsWith('.png')) {
      assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
      assert.equal(data.toString('ascii', 12, 16), 'IHDR');
      assert.deepEqual([data.readUInt32BE(16), data.readUInt32BE(20)], [1024, 1024]);
      assert.equal(data.toString('ascii', data.length - 8, data.length - 4), 'IEND');
    }
  }
});

test('guardian retains a valid 29-joint skin and all 31,998 indexed triangles offline', () => {
  const metadata = creature.files.find((entry) => entry.path.endsWith('.glb'));
  const { document, binary } = parseGlb(verifiedFile(metadata));
  assert.equal(document.skins.length, 1);
  const skin = document.skins[0];
  assert.equal(skin.joints.length, 29);
  assert.equal(skin.joints.length, creature.bones);
  assert.equal(new Set(skin.joints).size, skin.joints.length);
  for (const joint of skin.joints) assert.ok(document.nodes[joint], 'Joint node exists');
  const bindMatrices = document.accessors[skin.inverseBindMatrices];
  assert.equal(bindMatrices.type, 'MAT4');
  assert.equal(bindMatrices.count, skin.joints.length);
  assert.ok(accessorValues(document, binary, skin.inverseBindMatrices).every(Number.isFinite));
  assert.ok(document.nodes.some((node) => node.skin === 0 && node.mesh !== undefined));
  assert.deepEqual(document.materials.map((material) => material.name).sort(),
    ['carved stone', 'poky stone', 'smooth stone']);

  let triangles = 0;
  const checkedSkins = new Set();
  for (const mesh of document.meshes) {
    for (const primitive of mesh.primitives) {
      assert.equal(primitive.mode ?? 4, 4);
      const position = document.accessors[primitive.attributes.POSITION];
      const indices = accessorValues(document, binary, primitive.indices);
      assert.ok(indices.every((index) => index >= 0 && index < position.count), 'Vertex index bounds');
      assert.equal(indices.length % 3, 0);
      triangles += indices.length / 3;
      assert.ok(document.materials[primitive.material]);
      for (const attribute of ['NORMAL', 'TEXCOORD_0', 'JOINTS_0', 'WEIGHTS_0']) {
        assert.equal(document.accessors[primitive.attributes[attribute]].count, position.count,
          `${attribute}: one attribute per vertex`);
      }
      const jointsIndex = primitive.attributes.JOINTS_0;
      if (checkedSkins.has(jointsIndex)) continue;
      checkedSkins.add(jointsIndex);
      const joints = accessorValues(document, binary, jointsIndex);
      assert.ok(joints.every((joint) => joint >= 0 && joint < skin.joints.length), 'Skin joint index bounds');
      const weights = accessorValues(document, binary, primitive.attributes.WEIGHTS_0);
      assert.ok(weights.every((weight) => Number.isFinite(weight) && weight >= 0 && weight <= 1));
      for (let index = 0; index < weights.length; index += 4) {
        const sum = weights[index] + weights[index + 1] + weights[index + 2] + weights[index + 3];
        assert.ok(Math.abs(sum - 1) < .0001, 'Skin weights normalized');
      }
    }
  }
  assert.equal(triangles, 31998);
  assert.equal(triangles, creature.triangles);
});
