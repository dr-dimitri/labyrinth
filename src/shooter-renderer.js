import * as THREE from 'three';
import { Sky } from 'three/addons/objects/Sky.js';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { GTAOPass } from 'three/addons/postprocessing/GTAOPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { OBSTACLES, EXTRACTION } from './shooter-simulation.js';

const V = (x = 0, y = 0, z = 0) => new THREE.Vector3(x, y, z);
const mat = (color, roughness = .75, metalness = .05) => new THREE.MeshStandardMaterial({ color, roughness, metalness });
function seeded(seed = 183) { return () => { seed = (Math.imul(1664525, seed) + 1013904223) >>> 0; return seed / 4294967296; }; }

export class ShooterRenderer {
  constructor(container, { quality = 'balanced', onProgress = () => {} } = {}) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping; this.renderer.toneMappingExposure = .95;
    this.renderer.shadowMap.enabled = true; this.renderer.shadowMap.type = THREE.PCFShadowMap;
    this.renderer.domElement.setAttribute('aria-label', 'Blacksite – 3D-Spielfeld');
    container.append(this.renderer.domElement);
    this.scene = new THREE.Scene(); this.scene.fog = new THREE.FogExp2(0xa2a99d, .009);
    this.camera = new THREE.PerspectiveCamera(76, innerWidth / innerHeight, .055, 500); this.camera.rotation.order = 'YXZ';
    this.scene.add(this.camera);
    this.world = new THREE.Group(); this.scene.add(this.world);
    this.boxGeo = new RoundedBoxGeometry(1, 1, 1, 1, .045);
    this.cylinderGeo = new THREE.CylinderGeometry(1, 1, 1, 12);
    this.sphereGeo = new THREE.SphereGeometry(1, 12, 8);
    this.materials = { metal: mat(0x333b3b, .38, .8), dark: mat(0x151c1d, .5, .7), olive: mat(0x515a46), cloth: mat(0x686956), glove: mat(0x282d28), skin: mat(0x8b735b), rust: mat(0x6e4030, .8, .45), wood: mat(0x6c6650), glass: mat(0x78958c, .16, .8), sand: mat(0x8c866b), orange: mat(0xda692e), white: mat(0xacae9c), optic: new THREE.MeshStandardMaterial({ color: 0xa5cbc2, transparent: true, opacity: .18, metalness: .2, roughness: .15, depthWrite: false }), red: new THREE.MeshBasicMaterial({ color: 0xff6941 }) };
    this.surfaceMap = this.surfaceTexture();
    for (const id of ['metal', 'dark', 'olive', 'cloth', 'wood', 'rust']) this.materials[id].map = this.surfaceMap;
    this.composer = new EffectComposer(this.renderer); this.composer.addPass(new RenderPass(this.scene, this.camera));
    this.ao = new GTAOPass(this.scene, this.camera, innerWidth, innerHeight);
    this.ao.updateGtaoMaterial({ radius: .65, distanceExponent: 1.4, thickness: .6, scale: 1.1, samples: 8 }); this.ao.blendIntensity = .5;
    this.composer.addPass(this.ao);
    this.bloom = new UnrealBloomPass(new THREE.Vector2(innerWidth, innerHeight), .12, .35, 2); this.composer.addPass(this.bloom); this.composer.addPass(new OutputPass());
    this.clock = 0; this.enemyModels = new Map(); this.grenadeModels = new Map(); this.pickupModels = new Map(); this.coverModels = new Map(); this.effects = []; this.recoil = 0; this.shake = 0;
    this.onResize = () => this.resize(); window.addEventListener('resize', this.onResize);
    this.setQuality(quality); this.ready = this.initialize(onProgress);
  }
  mesh(geometry, material, position, scale, parent = this.world) {
    const object = new THREE.Mesh(geometry, material); object.position.copy(position); object.scale.copy(scale); object.castShadow = object.receiveShadow = true; parent.add(object); return object;
  }
  box(x, y, z, w, h, d, material, parent) { return this.mesh(this.boxGeo, material, V(x, y, z), V(w, h, d), parent); }
  cylinder(x, y, z, radius, height, material, parent) { return this.mesh(this.cylinderGeo, material, V(x, y, z), V(radius, height, radius), parent); }
  sphere(x, y, z, sx, sy, sz, material, parent) { return this.mesh(this.sphereGeo, material, V(x, y, z), V(sx, sy, sz), parent); }
  batch(group) {
    // Static parts sharing a material are submitted together. A whole container
    // remains its own group, so destruction can still remove it independently.
    const batches = new Map();
    for (const object of [...group.children]) {
      if (!object.isMesh || object.isInstancedMesh || object.userData.dynamic) continue;
      const key = `${object.material.uuid}:${!!object.geometry.index}:${Object.keys(object.geometry.attributes).join(',')}`;
      if (!batches.has(key)) batches.set(key, []); batches.get(key).push(object);
    }
    for (const objects of batches.values()) {
      if (objects.length < 2) continue;
      const copies = objects.map(object => { object.updateMatrix(); return object.geometry.clone().applyMatrix4(object.matrix); });
      const geometry = mergeGeometries(copies, false); copies.forEach(copy => copy.dispose());
      if (!geometry) continue;
      const merged = new THREE.Mesh(geometry, objects[0].material); merged.castShadow = objects.some(o => o.castShadow); merged.receiveShadow = true;
      group.add(merged); objects.forEach(object => group.remove(object));
    }
  }
  async initialize(onProgress) {
    const loader = new THREE.TextureLoader(); let loaded = 0;
    const textureSet = async (name, repeat, color) => {
      const entries = await Promise.all([['color', 'map'], ['normal', 'normalMap'], ['roughness', 'roughnessMap']].map(async ([file, slot]) => {
        const texture = await loader.loadAsync(`${import.meta.env.BASE_URL}assets/textures/${name}/${file}.jpg`);
        texture.colorSpace = file === 'color' ? THREE.SRGBColorSpace : THREE.NoColorSpace;
        texture.wrapS = texture.wrapT = THREE.RepeatWrapping; texture.repeat.set(repeat, repeat); texture.anisotropy = Math.min(4, this.renderer.capabilities.getMaxAnisotropy());
        onProgress(`Oberflächen laden · ${++loaded} / 9`); return [slot, texture];
      }));
      return new THREE.MeshStandardMaterial({ ...Object.fromEntries(entries), color, roughness: 1, normalScale: new THREE.Vector2(.8, .8) });
    };
    [this.groundMaterial, this.concrete, this.stone] = await Promise.all([textureSet('forest-earth', 90, 0x9a9580), textureSet('floor', 2, 0xaeb0a2), textureSet('forest-rock', 3, 0xa1a594)]);
    onProgress('Licht und Einsatzgebiet aufbauen');
    this.buildLighting(); this.buildWorld(); this.buildWeapon();
    this.camera.position.set(13, 6.4, 34); this.camera.lookAt(-4, 2, -13);
    await this.renderer.compileAsync(this.scene, this.camera);
    onProgress('Einsatzbereit');
  }
  buildLighting() {
    const sky = new Sky(); sky.scale.setScalar(450);
    Object.assign(sky.material.uniforms.turbidity, { value: 6 }); sky.material.uniforms.rayleigh.value = 1.4;
    sky.material.uniforms.mieCoefficient.value = .006; sky.material.uniforms.mieDirectionalG.value = .86;
    const sunPosition = V(-.65, .52, -.65).normalize(); sky.material.uniforms.sunPosition.value.copy(sunPosition);
    // Keep the solar disk within the postprocessing range; its physical HDR
    // radiance otherwise blooms across the entire playfield before tone mapping.
    sky.material.fragmentShader = sky.material.fragmentShader.replace('vec4( texColor, 1.0 )', 'vec4( min( texColor, vec3( 3.0 ) ), 1.0 )'); this.scene.add(sky);
    const environmentScene = new THREE.Scene(); environmentScene.add(sky.clone());
    const pmrem = new THREE.PMREMGenerator(this.renderer); this.environment = pmrem.fromScene(environmentScene, .035, .1, 500); pmrem.dispose();
    this.scene.environment = this.environment.texture; this.scene.environmentIntensity = .35;
    this.scene.add(new THREE.HemisphereLight(0xc4d6df, 0x5a5140, 1.25));
    this.sun = new THREE.DirectionalLight(0xffdfae, 3.2); this.sun.position.copy(sunPosition).multiplyScalar(100); this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(2048, 2048); Object.assign(this.sun.shadow.camera, { left: -52, right: 52, top: 52, bottom: -52, near: 1, far: 190 });
    this.sun.shadow.normalBias = .045; this.sun.shadow.bias = -.00015; this.sun.shadow.camera.updateProjectionMatrix(); this.scene.add(this.sun);
    this.flash = new THREE.PointLight(0xffb95c, 0, 7, 2); this.scene.add(this.flash);
  }
  label(text, width, height, color = '#d5d6bd', background = '#28342e') {
    const canvas = document.createElement('canvas'); canvas.width = 512; canvas.height = 128;
    const ctx = canvas.getContext('2d'); ctx.fillStyle = background; ctx.fillRect(0, 0, 512, 128); ctx.strokeStyle = color; ctx.lineWidth = 3; ctx.strokeRect(9, 9, 494, 110);
    ctx.fillStyle = color; ctx.font = 'bold 48px sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(text, 256, 66, 470);
    const texture = new THREE.CanvasTexture(canvas); texture.colorSpace = THREE.SRGBColorSpace;
    const material = new THREE.MeshStandardMaterial({ map: texture, roughness: .85 });
    return this.mesh(new THREE.PlaneGeometry(width, height), material, V(), V(1, 1, 1));
  }
  surfaceTexture() {
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 256;
    const ctx = canvas.getContext('2d'), rng = seeded(684), data = ctx.createImageData(256, 256);
    for (let i = 0; i < data.data.length; i += 4) { const value = 155 + Math.floor(rng() * 82); data.data[i] = data.data[i + 1] = data.data[i + 2] = value; data.data[i + 3] = 255; }
    ctx.putImageData(data, 0, 0);
    for (let i = 0; i < 140; i++) { const x = rng() * 256, y = rng() * 256; ctx.strokeStyle = `rgba(30,35,28,${.04 + rng() * .18})`; ctx.lineWidth = .3 + rng() * 2; ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + (rng() - .5) * 3, y + rng() * 95); ctx.stroke(); }
    const texture = new THREE.CanvasTexture(canvas); texture.colorSpace = THREE.SRGBColorSpace; texture.wrapS = texture.wrapT = THREE.RepeatWrapping; texture.repeat.set(2, 2); texture.anisotropy = 4; return texture;
  }
  buildWorld() {
    const rng = seeded(); const m = this.materials;
    const ground = this.mesh(new THREE.PlaneGeometry(360, 360), this.groundMaterial, V(0, -.018, 0), V(1, 1, 1)); ground.rotation.x = -Math.PI / 2;
    const roadMat = this.concrete.clone(); roadMat.color.setHex(0x595d58);
    for (const slot of ['map', 'normalMap', 'roughnessMap']) { roadMat[slot] = roadMat[slot].clone(); roadMat[slot].repeat.set(6, 45); }
    const road = this.mesh(new THREE.PlaneGeometry(12, 91), roadMat, V(0, .012, 0), V(1, 1, 1)); road.rotation.x = -Math.PI / 2;
    for (let z = -39; z < 42; z += 7) this.box(0, .02, z, .13, .014, 3, m.sand);
    for (const x of [-6.25, 6.25]) this.box(x, .04, 0, .25, .08, 84, this.concrete);
    OBSTACLES.forEach((b, i) => this.buildCover(b, `cover-${i}`, i));
    // Perimeter: two open vehicle gates, watchtowers, light masts, and wire fence.
    for (const x of [-38, 38]) for (let z = -42; z <= 42; z += 6) {
      this.cylinder(x, 1.6, z, .065, 3.2, m.metal);
      if (z < 42) this.fence(x, z + 3, 6, Math.PI / 2);
    }
    for (const z of [-42, 42]) for (let x = -38; x < 38; x += 6) {
      this.cylinder(x, 1.6, z, .065, 3.2, m.metal);
      if (Math.abs(x + 3) > 7) this.fence(x + 3, z, 6, 0);
    }
    for (const x of [-10, 10]) { this.box(x, 3.8, -39, .8, 7.6, .8, this.concrete); this.box(x, .5, -39, 1.5, 1, 1.5, this.concrete); }
    this.box(0, 6.9, -39, 20, 1.1, .6, m.olive);
    const sign = this.label('BLACKSITE // 07', 9, .8); sign.position.set(0, 6.94, -38.66);
    for (const [x, z] of [[-32, -36], [32, 33]]) {
      for (const dx of [-1.7, 1.7]) for (const dz of [-1.7, 1.7]) this.box(x + dx, 3, z + dz, .22, 6, .22, m.metal);
      this.box(x, 5.5, z, 4.2, .25, 4.2, m.metal); this.box(x, 8, z, 4.8, .15, 4.8, m.olive);
      for (const dx of [-2, 2]) this.box(x + dx, 6.3, z, .1, 1.5, 4, m.olive);
      this.box(x, 6.15, z - 2, 4, 1.1, .1, m.olive);
      for (let y = .4; y < 5.5; y += .38) this.box(x, y, z + 2.15, 1, .08, .12, m.metal);
      for (const dx of [-.55, .55]) this.box(x + dx, 2.8, z + 2.15, .08, 5.6, .1, m.metal);
    }
    for (const [x, z] of [[-8, 25], [9, -17], [-11, -31], [28, 11]]) {
      this.cylinder(x, 4.8, z, .07, 9.6, m.metal); this.box(x + .55, 9.2, z, 1.2, .1, .12, m.metal);
      const lamp = new THREE.MeshStandardMaterial({ color: 0xffeed0, emissive: 0xffc77a, emissiveIntensity: 3 }); this.box(x + 1, 9.1, z, .8, .08, .45, lamp);
    }
    // Scattered small stones share one draw call; trees use three instanced layers.
    const pebbleGeo = new THREE.DodecahedronGeometry(1, 0), pebbles = new THREE.InstancedMesh(pebbleGeo, this.stone, 300), dummy = new THREE.Object3D();
    for (let i = 0; i < 300; i++) {
      const x = (rng() - .5) * 120, z = (rng() - .5) * 120, s = .12 + rng() * .6;
      dummy.position.set(x, s * .22, z); dummy.scale.set(s, s * .55, s); dummy.rotation.set(rng(), rng() * 6, rng()); dummy.updateMatrix(); pebbles.setMatrixAt(i, dummy.matrix);
    }
    pebbles.receiveShadow = true; this.world.add(pebbles);
    const treePositions = [];
    for (let i = 0; i < 230; i++) { const a = rng() * Math.PI * 2, r = 54 + rng() * 95; treePositions.push({ x: Math.cos(a) * r, z: Math.sin(a) * r, s: .7 + rng() * 1.2 }); }
    const trunks = new THREE.InstancedMesh(new THREE.CylinderGeometry(.14, .3, 11, 5), mat(0x51483b), treePositions.length);
    const needleTexture = this.pineTexture();
    const needleMaterial = new THREE.MeshStandardMaterial({ map: needleTexture, alphaTest: .48, side: THREE.DoubleSide, roughness: 1, color: 0x9aab8d });
    const needles = new THREE.InstancedMesh(new THREE.PlaneGeometry(9, 18), needleMaterial, treePositions.length * 3);
    treePositions.forEach((p, i) => {
      dummy.rotation.set(0, rng() * 6, 0); dummy.position.set(p.x, p.s * 5.5, p.z); dummy.scale.setScalar(p.s); dummy.updateMatrix(); trunks.setMatrixAt(i, dummy.matrix);
      for (let j = 0; j < 3; j++) { dummy.position.y = 9.5 * p.s; dummy.rotation.y = j * Math.PI / 3 + i; dummy.scale.setScalar(p.s); dummy.updateMatrix(); needles.setMatrixAt(i * 3 + j, dummy.matrix); needles.setColorAt(i * 3 + j, new THREE.Color().setScalar(.75 + rng() * .4)); }
    }); trunks.castShadow = needles.castShadow = true; this.world.add(trunks, needles);
    const mountainGeo = new THREE.IcosahedronGeometry(1, 1), mountains = new THREE.InstancedMesh(mountainGeo, this.stone, 35);
    for (let i = 0; i < 35; i++) { const a = i / 35 * Math.PI * 2; dummy.position.set(Math.cos(a) * 200, -10, Math.sin(a) * 200); dummy.rotation.set(0, rng() * 6, .2); dummy.scale.set(38 + rng() * 40, 32 + rng() * 65, 30 + rng() * 25); dummy.updateMatrix(); mountains.setMatrixAt(i, dummy.matrix); } this.world.add(mountains);
    const grassGeo = new THREE.BufferGeometry(); grassGeo.setAttribute('position', new THREE.Float32BufferAttribute([-.035, 0, 0, .035, 0, 0, .07, .7, .06], 3)); grassGeo.computeVertexNormals();
    const grass = new THREE.InstancedMesh(grassGeo, new THREE.MeshStandardMaterial({ color: 0x767458, side: THREE.DoubleSide, roughness: 1 }), 1900);
    for (let i = 0; i < 1900; i++) { let x = (rng() - .5) * 110; if (Math.abs(x) < 7) x += x < 0 ? -9 : 9; const z = (rng() - .5) * 115; dummy.position.set(x, 0, z); dummy.rotation.set(rng() * .4, rng() * 6, rng() * .3); dummy.scale.set(1 + rng(), .3 + rng() * .8, 1); dummy.updateMatrix(); grass.setMatrixAt(i, dummy.matrix); } this.world.add(grass);
    // Dust motes catch the low sun without hiding the action.
    const dustGeo = new THREE.BufferGeometry(), dustPositions = new Float32Array(240 * 3);
    for (let i = 0; i < dustPositions.length; i += 3) { dustPositions[i] = (rng() - .5) * 80; dustPositions[i + 1] = rng() * 12; dustPositions[i + 2] = (rng() - .5) * 80; }
    dustGeo.setAttribute('position', new THREE.BufferAttribute(dustPositions, 3));
    this.dust = new THREE.Points(dustGeo, new THREE.PointsMaterial({ color: 0xffdfab, size: .045, transparent: true, opacity: .4, depthWrite: false })); this.world.add(this.dust);
    const ringGeo = new THREE.RingGeometry(EXTRACTION.radius - .1, EXTRACTION.radius, 64);
    this.extraction = new THREE.Mesh(ringGeo, new THREE.MeshBasicMaterial({ color: 0x97f7c3, transparent: true, opacity: .85, side: THREE.DoubleSide })); this.extraction.rotation.x = -Math.PI / 2; this.extraction.position.set(EXTRACTION.x, .045, EXTRACTION.z); this.extraction.visible = false; this.extraction.userData.dynamic = true; this.world.add(this.extraction);
    this.batch(this.world);
  }
  pineTexture() {
    const canvas = document.createElement('canvas'); canvas.width = 512; canvas.height = 1024;
    const ctx = canvas.getContext('2d'), rng = seeded(257); ctx.lineCap = 'round';
    ctx.strokeStyle = '#484536'; ctx.lineWidth = 9; ctx.beginPath(); ctx.moveTo(256, 1015); ctx.lineTo(252, 14); ctx.stroke();
    for (let layer = 0; layer < 37; layer++) {
      const y = 25 + layer * 23, width = 9 + layer * 5.6;
      for (const side of [-1, 1]) for (let branch = 0; branch < 3; branch++) {
        const endX = 256 + side * width * (.65 + rng() * .5), endY = y + 12 + rng() * 34;
        ctx.strokeStyle = '#414936'; ctx.lineWidth = 3; ctx.beginPath(); ctx.moveTo(256, y - 8); ctx.lineTo(endX, endY); ctx.stroke();
        for (let n = 0; n < 45; n++) {
          const t = n / 45, x = 256 + (endX - 256) * t, by = y - 8 + (endY - y + 8) * t;
          const sprig = 12 + rng() * 20 * (1 - t * .4);
          for (let k = 0; k < 4; k++) {
            const tone = Math.floor(43 + rng() * 38); ctx.strokeStyle = `rgb(${tone * .86},${tone + 12},${tone * .76})`; ctx.lineWidth = 1.6 + rng();
            ctx.beginPath(); ctx.moveTo(x, by); ctx.lineTo(x + side * (7 + rng() * 11), by + (k % 2 ? -1 : 1) * sprig * rng()); ctx.stroke();
          }
        }
      }
    }
    const texture = new THREE.CanvasTexture(canvas); texture.colorSpace = THREE.SRGBColorSpace; texture.anisotropy = 4; return texture;
  }
  fence(x, z, width, rotation) {
    if (!this.fenceMaterial) {
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 64; const ctx = canvas.getContext('2d');
      ctx.strokeStyle = '#71776c'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(64, 64); ctx.moveTo(64, 0); ctx.lineTo(0, 64); ctx.stroke();
      const texture = new THREE.CanvasTexture(canvas); texture.wrapS = texture.wrapT = THREE.RepeatWrapping; texture.repeat.set(12, 6);
      this.fenceMaterial = new THREE.MeshStandardMaterial({ map: texture, transparent: true, alphaTest: .4, side: THREE.DoubleSide, roughness: .6, metalness: .7 });
    }
    const fence = this.mesh(new THREE.PlaneGeometry(width, 2.7), this.fenceMaterial, V(x, 1.4, z), V(1, 1, 1)); fence.rotation.y = rotation; fence.castShadow = false;
  }
  buildCover(b, id, index) {
    const group = new THREE.Group(); group.position.set(b.x, 0, b.z); this.world.add(group); this.coverModels.set(id, group); const m = this.materials;
    if (b.type === 'container') {
      const material = mat(index % 2 ? 0x526e6d : 0x865c42, .68, .65);
      material.map = this.surfaceMap;
      this.box(0, b.h / 2, 0, b.w, b.h, b.d, material, group);
      const longX = b.w > b.d;
      for (let t = -(longX ? b.w : b.d) / 2 + .16; t < (longX ? b.w : b.d) / 2; t += .32) {
        for (const side of [-1, 1]) this.box(longX ? t : side * (b.w / 2 + .025), b.h / 2, longX ? side * (b.d / 2 + .025) : t, longX ? .095 : .06, b.h - .2, longX ? .06 : .095, material, group);
      }
      for (const y of [.09, b.h - .09]) for (const side of [-1, 1]) this.box(0, y, side * b.d / 2, b.w + .07, .14, .1, m.metal, group);
      for (const x of [-b.w / 2, b.w / 2]) for (const z of [-b.d / 2, b.d / 2]) this.box(x, b.h / 2, z, .13, b.h, .13, m.metal, group);
      for (const x of [-.65, .65]) this.cylinder(x, b.h / 2, b.d / 2 + .08, .025, b.h - .35, m.metal, group);
      const label = this.label(`NG-${index + 201}  ▸`, 2.5, .6, '#dad9c3', index % 2 ? '#45595a' : '#6c4a36'); group.add(label); label.position.set(0, 2.15, b.d / 2 + .07);
      this.box(0, b.h + .015, 0, b.w - .16, .06, b.d - .16, material, group);
    } else if (b.type === 'bunker') {
      this.box(0, b.h / 2, 0, b.w, b.h, b.d, this.concrete, group);
      this.box(0, b.h, 0, b.w + .65, .3, b.d + .65, this.concrete, group);
      this.box(0, .25, 0, b.w + .25, .5, b.d + .25, this.stone, group);
      for (const x of [-b.w * .32, 0, b.w * .32]) {
        this.box(x, b.h * .65, b.d / 2 + .035, 2.4, 1.4, .12, m.dark, group);
        for (const dx of [-1.1, 0, 1.1]) this.box(x + dx, b.h * .65, b.d / 2 + .12, .08, 1.45, .08, m.rust, group);
        this.box(x, b.h * .65, b.d / 2 + .13, 2.4, .06, .08, m.metal, group);
      }
      this.box(-b.w * .3, 1.24, b.d / 2 + .06, 1.5, 2.48, .1, m.olive, group);
      this.box(-b.w * .3 + .54, 1.1, b.d / 2 + .16, .1, .1, .15, m.metal, group);
      const label = this.label(index ? 'COMMAND // 02' : 'RESTRICTED', 3.3, .75); group.add(label); label.position.set(1.3, 1.8, b.d / 2 + .08);
      for (let x = -b.w / 2 + 1; x < b.w / 2; x += 2.7) this.box(x, b.h / 2, b.d / 2 + .015, .035, b.h, .025, m.metal, group);
      for (let y = 1; y < b.h; y += 1.1) this.box(0, y, b.d / 2 + .015, b.w, .024, .025, m.metal, group);
      this.box(1.6, b.h + .55, 1, 2.5, 1, 2, m.metal, group);
      for (let i = 0; i < 9; i++) this.box(.6 + i * .24, b.h + .55, 2.02, .08, .7, .04, m.dark, group);
      this.cylinder(-2, b.h + 2, -2, .045, 4, m.metal, group);
      for (const y of [b.h + 2, b.h + 3]) this.box(-2, y, -2, 2.2, .025, .035, m.metal, group);
    } else if (b.type === 'barrier') {
      this.box(0, b.h * .4, 0, b.w, b.h * .8, b.d, this.concrete, group);
      this.box(0, b.h * .85, 0, b.w, b.h * .3, b.d * .56, this.concrete, group);
      for (let x = -b.w / 2 + .3; x < b.w / 2; x += .8) { const stripe = this.box(x, b.h * .52, b.d / 2 + .009, .38, .32, .014, m.sand, group); stripe.rotation.z = -.3; }
      for (const x of [-b.w * .35, b.w * .35]) this.box(x, .09, 0, .7, .18, b.d + .2, this.concrete, group);
    } else if (b.type === 'barrel') {
      this.cylinder(0, b.h / 2, 0, .39, b.h, m.rust, group);
      for (const y of [.04, .32, .8, b.h - .025]) this.cylinder(0, y, 0, .407, .035, m.metal, group);
      this.cylinder(.16, b.h + .02, .1, .045, .04, m.dark, group);
      const label = this.label('FLAMMABLE', .55, .18, '#24261f', '#b8a478'); group.add(label); label.position.set(0, .57, .405);
    } else {
      this.box(0, b.h / 2, 0, b.w, b.h, b.d, m.wood, group);
      for (const x of [-b.w * .43, b.w * .43]) for (const z of [-b.d / 2, b.d / 2]) this.box(x, b.h / 2, z, .12, b.h, .08, m.metal, group);
      for (let y = .3; y < b.h; y += .3) this.box(0, y, b.d / 2 + .01, b.w, .025, .025, m.dark, group);
      for (const y of [.08, b.h - .08]) this.box(0, y, b.d / 2 + .04, b.w, .14, .1, m.sand, group);
    }
    this.batch(group); return group;
  }
  createGun(sniper = false, parent = this.world) {
    const gun = new THREE.Group(); parent.add(gun); const m = this.materials;
    this.box(0, 0, -.16, .13, .18, .53, m.metal, gun);
    this.box(0, .018, -.51, .115, .145, sniper ? .58 : .4, m.dark, gun);
    this.box(0, -.19, -.06, .075, .27, .13, m.dark, gun).rotation.x = -.18;
    this.box(0, -.16, -.28, .08, sniper ? .14 : .3, .15, m.metal, gun).rotation.x = .1;
    this.box(0, -.008, .22, .11, .15, .29, m.olive, gun);
    this.box(0, -.05, .35, .14, .27, .08, m.dark, gun);
    const barrel = this.cylinder(0, .027, sniper ? -.99 : -.83, .028, sniper ? .55 : .35, m.metal, gun); barrel.rotation.x = Math.PI / 2;
    const muzzle = this.cylinder(0, .027, sniper ? -1.24 : -1.02, sniper ? .047 : .035, .12, m.dark, gun); muzzle.rotation.x = Math.PI / 2;
    for (let i = 0; i < 12; i++) this.box(0, .104, -.65 + i * .057, .15, .02, .022, m.dark, gun);
    for (const side of [-1, 1]) for (let i = 0; i < 7; i++) this.box(side * .061, .025, -.65 + i * .052, .009, .055, .028, m.metal, gun);
    if (sniper) {
      for (const z of [-.08, -.39]) this.box(0, .16, z, .08, .14, .06, m.metal, gun);
      const scope = this.cylinder(0, .25, -.25, .071, .49, m.dark, gun); scope.rotation.x = Math.PI / 2;
      for (const z of [-.51, .015]) { const rim = this.cylinder(0, .25, z, .089, .09, m.metal, gun); rim.rotation.x = Math.PI / 2; }
      const glass = this.cylinder(0, .25, .065, .068, .008, m.glass, gun); glass.rotation.x = Math.PI / 2;
      this.cylinder(0, .35, -.2, .04, .05, m.metal, gun);
      for (const x of [-.045, .045]) { const bipod = this.cylinder(x, -.18, -.76, .012, .37, m.metal, gun); bipod.rotation.x = -.8; }
    } else {
      for (const x of [-.05, .05]) this.box(x, .159, -.05, .018, .11, .08, m.dark, gun);
      this.box(0, .207, -.05, .115, .018, .08, m.dark, gun);
      this.box(0, .107, -.05, .115, .022, .09, m.dark, gun);
      this.box(0, .159, -.05, .073, .078, .004, m.optic, gun);
      this.box(0, .175, -.098, .008, .008, .006, m.red, gun);
    }
    this.batch(gun); return gun;
  }
  buildWeapon() {
    this.weaponRoot = new THREE.Group(); this.weaponRoot.scale.setScalar(.9); this.camera.add(this.weaponRoot);
    this.guns = { rifle: this.createGun(false, this.weaponRoot), sniper: this.createGun(true, this.weaponRoot) }; this.guns.sniper.visible = false;
    const m = this.materials;
    this.sphere(.03, -.14, .1, .083, .1, .12, m.glove, this.weaponRoot);
    const arm = this.cylinder(.12, -.25, .29, .078, .38, m.cloth, this.weaponRoot); arm.rotation.x = -.85; arm.rotation.z = .2;
    this.sphere(-.07, -.1, -.55, .065, .08, .11, m.glove, this.weaponRoot);
    const forearm = this.cylinder(-.15, -.25, -.3, .073, .52, m.cloth, this.weaponRoot); forearm.rotation.x = .9; forearm.rotation.z = -.22;
    this.weaponRoot.traverse(o => { if (o.isMesh) { o.castShadow = false; o.frustumCulled = false; } });
    this.muzzleFlash = new THREE.Mesh(new THREE.IcosahedronGeometry(.09, 0), new THREE.MeshBasicMaterial({ color: 0xffd58e, transparent: true, opacity: .9, blending: THREE.AdditiveBlending })); this.muzzleFlash.position.set(0, .027, -1.1); this.weaponRoot.add(this.muzzleFlash);
  }
  soldier(enemy) {
    const root = new THREE.Group(), body = new THREE.Group(); root.add(body); this.world.add(root); const m = this.materials;
    this.sphere(0, 1.18, 0, .32, .4, .21, m.olive, body);
    this.box(0, 1.27, .14, .53, .54, .13, m.dark, body);
    for (const x of [-.18, 0, .18]) this.box(x, 1.14, .24, .13, .21, .085, m.olive, body);
    this.box(0, 1.22, -.21, .42, .52, .22, m.olive, body);
    this.cylinder(0, 1.57, 0, .1, .14, m.cloth, body);
    this.sphere(0, 1.76, 0, .2, .24, .2, m.dark, body);
    this.sphere(0, 1.89, -.025, .245, .16, .245, m.olive, body);
    this.box(0, 1.8, .182, .31, .086, .045, m.glass, body);
    this.box(0, 1.69, .19, .22, .12, .045, m.cloth, body);
    for (const side of [-1, 1]) {
      const upper = this.cylinder(side * .35, 1.32, .04, .105, .4, m.cloth, body); upper.rotation.x = -.6; upper.rotation.z = side * .2;
      const forearm = this.cylinder(side * .28, 1.16, .25, .085, .38, m.olive, body); forearm.rotation.x = -1.15; forearm.rotation.z = -side * .45;
      this.sphere(side * .2, 1.14, .41, .08, .08, .09, m.glove, body);
    }
    const gun = this.createGun(false, body); gun.position.set(.15, 1.17, .4); gun.rotation.y = Math.PI; gun.scale.setScalar(.8);
    const legs = [-1, 1].map(side => {
      const leg = new THREE.Group(); leg.position.set(side * .15, .86, 0); body.add(leg);
      this.cylinder(0, -.22, 0, .12, .43, m.cloth, leg); this.sphere(0, -.43, .04, .12, .13, .12, m.dark, leg);
      this.cylinder(0, -.59, 0, .1, .33, m.olive, leg); this.box(0, -.8, .075, .22, .17, .37, m.dark, leg); return leg;
    });
    const alert = this.sphere(0, 2.22, 0, .065, .065, .065, m.red, root); alert.visible = false;
    return { root, body, legs, alert, dead: false };
  }
  tracer(from, to, hostile = false) {
    const geometry = new THREE.BufferGeometry().setFromPoints([V(from.x, from.y, from.z), V(to.x, to.y, to.z)]);
    const line = new THREE.Line(geometry, new THREE.LineBasicMaterial({ color: hostile ? 0xff7540 : 0xffdeb0, transparent: true, opacity: .8 })); this.world.add(line);
    this.effects.push({ object: line, life: .09, max: .09, disposable: true });
  }
  particles(position, count, color, force = 5, chunks = false) {
    const rng = seeded(Math.floor(this.clock * 1000) + count);
    for (let i = 0; i < count; i++) {
      const material = chunks ? this.materials.wood : new THREE.MeshBasicMaterial({ color, transparent: true, opacity: .9 });
      const object = this.mesh(chunks ? this.boxGeo : this.sphereGeo, material, V(position.x, position.y, position.z), chunks ? V(.1 + rng() * .3, .1 + rng() * .2, .1 + rng() * .3) : V(.02, .02, .02));
      object.castShadow = false;
      this.effects.push({ object, life: chunks ? 2.5 : .35 + rng() * .45, max: chunks ? 2.5 : .8, velocity: V((rng() - .5) * force, rng() * force * .8, (rng() - .5) * force), chunks, ownMaterial: !chunks });
    }
  }
  events(events, sim) {
    for (const e of events) {
      if (e.type === 'shot') { this.recoil = sim.weapon === 'sniper' ? .18 : .085; this.flashTime = .045; this.tracer(e.from, e.to); if (!e.hit) this.particles(e.to, 4, 0xffd58a, 2); }
      if (e.type === 'enemy-shot') this.tracer(e.from, e.to, true);
      if (e.type === 'damage') this.shake = .045;
      if (e.type === 'land') this.shake = .025;
      if (e.type === 'explosion') {
        this.shake = Math.max(this.shake, .23 / (1 + Math.hypot(e.x - sim.player.x, e.z - sim.player.z) / 5));
        this.particles(e, 35, 0xffb058, 11); this.particles(e, 12, 0x8a7860, 8, true);
        const sphere = this.mesh(this.sphereGeo, new THREE.MeshBasicMaterial({ color: 0xffb65a, transparent: true, opacity: .65, depthWrite: false, blending: THREE.AdditiveBlending }), V(e.x, e.y, e.z), V(1, 1, 1));
        this.effects.push({ object: sphere, life: .4, max: .4, expand: 13, ownMaterial: true });
        const smoke = this.mesh(this.sphereGeo, new THREE.MeshBasicMaterial({ color: 0x5c5a52, transparent: true, opacity: .3, depthWrite: false }), V(e.x, e.y + 1, e.z), V(1, 1, 1));
        this.effects.push({ object: smoke, life: 2.2, max: 2.2, expand: 3, ownMaterial: true });
        const flash = new THREE.PointLight(0xffaa50, 120, 15, 2); flash.position.set(e.x, e.y + .5, e.z); this.world.add(flash); this.effects.push({ object: flash, life: .18, max: .18 });
      }
      if (e.type === 'destroy') { this.coverModels.get(e.id).visible = false; this.particles(e, 22, 0xb4a289, 8, true); }
    }
  }
  reset() {
    for (const models of [this.enemyModels, this.grenadeModels, this.pickupModels]) {
      for (const model of models.values()) { this.world.remove(model.root || model); if (model.root) this.disposeSoldier(model); }
      models.clear();
    }
    for (const group of this.coverModels.values()) group.visible = true;
    for (const e of this.effects) this.removeEffect(e); this.effects = []; this.recoil = this.shake = 0;
  }
  disposeSoldier(model) {
    model.root.traverse(object => { if (object.geometry && ![this.boxGeo, this.cylinderGeo, this.sphereGeo].includes(object.geometry)) object.geometry.dispose(); });
  }
  removeEffect(e) { this.world.remove(e.object); if (e.disposable) { e.object.geometry.dispose(); e.object.material.dispose(); } else if (e.ownMaterial) e.object.material.dispose(); }
  update(dt, sim, mode) {
    this.clock += dt;
    if (!this.weaponRoot) return;
    const playing = sim && mode !== 'menu'; this.weaponRoot.visible = !!playing;
    if (playing) {
      const p = sim.player, active = mode === 'playing', step = active ? dt : 0;
      this.recoil *= Math.exp(-step * 14); this.shake *= Math.exp(-step * 10);
      const bob = sim.moving && p.grounded && !sim.aiming && !sim.climbing ? Math.sin(sim.time * (sim.sprinting ? 17 : 11)) * (p.prone ? .012 : .024) : 0;
      this.camera.position.set(p.x, sim.eye.y + bob, p.z); this.camera.rotation.set(p.pitch + this.recoil * .055 + Math.sin(this.clock * 91) * this.shake, p.yaw + Math.sin(this.clock * 71) * this.shake * .4, 0);
      const fov = sim.aiming ? sim.weapon === 'sniper' ? 2 * Math.atan(Math.tan(38 * Math.PI / 180) / 6) * 180 / Math.PI : 53 : sim.sprinting ? 83 : 76;
      this.camera.fov += (fov - this.camera.fov) * Math.min(1, dt * 17); this.camera.updateProjectionMatrix();
      this.guns.rifle.visible = sim.weapon === 'rifle'; this.guns.sniper.visible = sim.weapon === 'sniper';
      this.weaponRoot.visible = !(sim.aiming && sim.weapon === 'sniper') && !sim.climbing;
      const reload = sim.weapons[sim.weapon].reload;
      this.weaponRoot.position.set(sim.aiming ? 0 : .27, sim.aiming ? -.1575 : -.29 + bob * .4, -.65 + this.recoil);
      this.weaponRoot.rotation.set(sim.sprinting ? -.48 : reload ? -.4 : this.recoil * .5, reload ? -.4 : -.008, reload ? -.6 : sim.sprinting ? .2 : -.025);
      this.flashTime = Math.max(0, (this.flashTime || 0) - step); this.muzzleFlash.visible = this.flashTime > 0;
      this.muzzleFlash.rotation.z = this.clock * 170; this.muzzleFlash.scale.set(1, .6, 2.5); this.flash.intensity = this.flashTime > 0 ? 9 : 0;
      this.flash.position.copy(this.camera.position).add(V(0, -.2, -1).applyEuler(this.camera.rotation));
      for (const e of sim.enemies) {
        let model = this.enemyModels.get(e.id);
        if (!model) { model = this.soldier(e); this.enemyModels.set(e.id, model); }
        model.root.position.set(e.x, .02, e.z); model.root.rotation.y = e.yaw;
        model.alert.visible = e.health > 0 && e.windup > 0;
        if (e.health <= 0) { const fall = Math.min(1, (sim.time - e.deadAt) * 3); model.body.rotation.x = -fall * Math.PI / 2; model.body.position.y = -.1 * fall; model.root.visible = sim.time - e.deadAt < 8; }
        else { model.body.rotation.z = Math.sin(e.stride) * .025; model.legs[0].rotation.x = e.moving ? Math.sin(e.stride) * .48 : 0; model.legs[1].rotation.x = e.moving ? -Math.sin(e.stride) * .48 : 0; }
      }
      for (const [id, model] of this.enemyModels) if (!sim.enemies.some(e => e.id === id)) { this.world.remove(model.root); this.disposeSoldier(model); this.enemyModels.delete(id); }
      for (const g of sim.projectiles) {
        let model = this.grenadeModels.get(g.id);
        if (!model) { model = this.sphere(0, 0, 0, .095, .12, .095, this.materials.olive); this.grenadeModels.set(g.id, model); }
        model.position.set(g.x, g.y, g.z); model.rotation.x = this.clock * 12;
      }
      for (const [id, model] of this.grenadeModels) if (!sim.projectiles.some(g => g.id === id)) { this.world.remove(model); this.grenadeModels.delete(id); }
      for (const pack of sim.pickups) {
        let model = this.pickupModels.get(pack.id);
        if (!model) { model = this.box(pack.x, .3, pack.z, .6, .35, .45, this.materials.olive); this.pickupModels.set(pack.id, model); }
        model.position.y = .32 + Math.sin(this.clock * 2) * .06; model.rotation.y = this.clock * .4;
      }
      for (const [id, model] of this.pickupModels) if (!sim.pickups.some(g => g.id === id)) { this.world.remove(model); this.pickupModels.delete(id); }
      this.extraction.visible = !!sim.extractionAnnounced; this.extraction.material.opacity = .55 + Math.sin(this.clock * 3) * .25;
    } else {
      this.camera.position.set(13 + Math.sin(this.clock * .045) * 1.5, 6.4, 34); this.camera.lookAt(-4, 2.4, -13); this.camera.fov = 61; this.camera.updateProjectionMatrix();
    }
    if (mode === 'playing') {
      for (const e of this.effects) {
        e.life -= dt;
        if (e.velocity) { e.velocity.y -= 10 * dt; e.object.position.addScaledVector(e.velocity, dt); if (e.object.position.y < .06) { e.object.position.y = .06; e.velocity.y *= -.25; e.velocity.x *= .8; e.velocity.z *= .8; } e.object.rotation.x += dt * 4; }
        if (e.expand) { e.object.scale.addScalar(dt * e.expand); e.object.position.y += dt * .7; }
        if (e.ownMaterial || e.disposable) e.object.material.opacity = Math.max(0, e.life / e.max) * .65;
        if (e.object.isLight) e.object.intensity = Math.max(0, e.life / e.max) * 120;
      }
      this.effects = this.effects.filter(e => { if (e.life > 0) return true; this.removeEffect(e); return false; });
    }
    this.dust.rotation.y = this.clock * .002;
    this.composer.render();
  }
  setQuality(quality) { this.quality = quality; this.ao.enabled = quality === 'high'; this.renderer.setPixelRatio(Math.min(devicePixelRatio, quality === 'high' ? 1.5 : 1)); this.resize(); }
  resize() { this.camera.aspect = innerWidth / innerHeight; this.camera.updateProjectionMatrix(); this.renderer.setSize(innerWidth, innerHeight); this.composer.setSize(innerWidth, innerHeight); this.ao.setSize(Math.ceil(innerWidth * .6), Math.ceil(innerHeight * .6)); }
  dispose() {
    window.removeEventListener('resize', this.onResize); this.reset();
    const geometries = new Set(), materials = new Set(), textures = new Set();
    this.scene.traverse(o => { if (o.geometry) geometries.add(o.geometry); if (o.material) for (const m of Array.isArray(o.material) ? o.material : [o.material]) materials.add(m); });
    for (const m of materials) { for (const value of Object.values(m)) if (value?.isTexture) textures.add(value); m.dispose(); }
    geometries.forEach(g => g.dispose()); textures.forEach(t => t.dispose()); this.environment?.dispose(); this.composer.passes.forEach(p => p.dispose?.()); this.composer.dispose(); this.renderer.dispose();
  }
}
