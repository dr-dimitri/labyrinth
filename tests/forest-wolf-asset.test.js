import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import * as THREE from 'three';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { ForestWolfModel } from '../src/forest-wolf.js';

const manifest = JSON.parse(fs.readFileSync(new URL('../docs/model-forest-creature-sources.json', import.meta.url)));
function template() {
  const manager = new THREE.LoadingManager();
  manager.addHandler(/\.png/, { path: '', setPath(path) { this.path = path; }, load() { return new THREE.Texture(); } });
  const bytes = fs.readFileSync(new URL('../public/assets/models/forest-wolf/dog2.FBX', import.meta.url));
  return new FBXLoader(manager).parse(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), '');
}
function vertex(mesh, index) { return mesh.localToWorld(mesh.getVertexPosition(index, new THREE.Vector3())); }

test('CC0 imported wolf source files retain exact recorded bytes and original author provenance', () => {
  assert.equal(manifest.author, 'NewDLC'); assert.equal(manifest.license, 'CC0-1.0');
  assert.equal(manifest.files.length, 5);
  for (const file of manifest.files) {
    const bytes = fs.readFileSync(new URL(`../${file.path}`, import.meta.url));
    assert.equal(bytes.length, file.bytes);
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), file.sha256);
  }
});

test('actual FBX wolf retains skin weights and deforms independently with distance-driven gait', () => {
  const source = template(), a = new ForestWolfModel(source), b = new ForestWolfModel(source);
  try {
    const mesh = a.model.getObjectByName('dog2');
    assert.ok(mesh.isSkinnedMesh); assert.equal(mesh.geometry.attributes.position.count, 16074);
    assert.equal(mesh.geometry.attributes.skinWeight.count, 16074);
    assert.ok(mesh.skeleton.bones.length >= 30);
    assert.notEqual(mesh.skeleton, b.model.getObjectByName('dog2').skeleton);
    a.root.updateMatrixWorld(true); b.root.updateMatrixWorld(true);
    const original = []; for (let i = 0; i < 16074; i += 101) original.push(vertex(mesh, i));
    const otherBone = b.bones.get('b_LeftUpperArm').bone.quaternion.clone();
    a.motion = 1; a.phase = 1.1; a.pose(); a.root.updateMatrixWorld(true);
    let changed = 0;
    for (let i = 0, n = 0; i < 16074; i += 101, n++) if (vertex(mesh, i).distanceTo(original[n]) > .012) changed++;
    assert.ok(changed > 10, `${changed} weighted vertices changed with gait`);
    assert.ok(otherBone.equals(b.bones.get('b_LeftUpperArm').bone.quaternion));
    const eye = a.root.getObjectByName('Wolf Left red eye'), fang = a.root.getObjectByName('Wolf upper long canine -1');
    assert.ok(eye && fang); assert.equal(eye.parent, a.bones.get('b_LeftEye').bone);
    const before = eye.getWorldPosition(new THREE.Vector3()), fangBefore = fang.getWorldPosition(new THREE.Vector3());
    a.rotate('b_Head', 'x', .3); a.root.updateMatrixWorld(true);
    assert.ok(eye.getWorldPosition(new THREE.Vector3()).distanceTo(before) > .02);
    assert.ok(fang.getWorldPosition(new THREE.Vector3()).distanceTo(fangBefore) > .02);
  } finally { a.dispose(); b.dispose(); }
});
