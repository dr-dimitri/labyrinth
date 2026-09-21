import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { HDRLoader } from 'three/addons/loaders/HDRLoader.js';
import { loadGuardianTemplate } from './guardian.js';
import { loadForestWolfTemplate } from './forest-wolf.js';

const assetUrl = path => `${import.meta.env.BASE_URL}assets/${path}`;
const MATERIAL_MAPS = {
  color: 'map', normal: 'normalMap', roughness: 'roughnessMap',
  ao: 'aoMap', height: 'displacementMap',
};

/** Shared, locally bundled photographic materials and model templates. */
export async function loadPhotorealAssets(renderer, onProgress = () => {}) {
  const manager = new THREE.LoadingManager();
  manager.onProgress = (_url, loaded, total) => onProgress(`MATERIALIEN UND MODELLE … ${loaded} / ${total}`);
  const anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
  const loader = new THREE.TextureLoader(manager);
  const textures = new Set();
  const geometries = new Set();
  const materials = new Set();

  async function materialSet(name, options) {
    const maps = {};
    await Promise.all(Object.entries(MATERIAL_MAPS).map(async ([file, slot]) => {
      const texture = await loader.loadAsync(assetUrl(`textures/${name}/${file}.jpg`));
      texture.colorSpace = file === 'color' ? THREE.SRGBColorSpace : THREE.NoColorSpace;
      texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
      texture.anisotropy = anisotropy;
      texture.channel = 0;
      maps[slot] = texture;
      textures.add(texture);
    }));
    const material = new THREE.MeshStandardMaterial({
      ...maps, color: 0xffffff, metalness: 0, roughness: 1,
      normalScale: new THREE.Vector2(.85, .85), aoMapIntensity: .85,
      displacementScale: 0, vertexColors: true, ...options,
    });
    materials.add(material);
    return material;
  }

  async function model(name) {
    const { scene } = await new GLTFLoader(manager).loadAsync(assetUrl(`models/environment/${name}.glb`));
    scene.updateMatrixWorld(true);
    scene.traverse(object => {
      if (!object.isMesh) return;
      object.userData.persistentAsset = true;
      object.castShadow = object.receiveShadow = true;
      geometries.add(object.geometry);
      for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
        materials.add(material);
        if (name === 'rock') { material.vertexColors = false; material.roughness = 1.8; }
        for (const value of Object.values(material)) {
          if (!value?.isTexture) continue;
          value.anisotropy = anisotropy;
          textures.add(value);
        }
      }
    });
    return scene;
  }

  const [wall, floor, statue, rock, guardian, hdri, forestGround, forestBark, forestRock, forestEarth, fern, fernAlpha, forestWolf] = await Promise.all([
    materialSet('wall', { normalScale: new THREE.Vector2(1, 1) }),
    materialSet('floor', { displacementScale: .055, displacementBias: -.045 }),
    model('statue'), model('rock'),
    loadGuardianTemplate({ manager, maxAnisotropy: anisotropy }),
    new HDRLoader(manager).loadAsync(assetUrl('textures/environment/night.hdr')),
    materialSet('forest-ground', { normalScale: new THREE.Vector2(1.1, 1.1), displacementScale: 0 }),
    materialSet('forest-bark', { normalScale: new THREE.Vector2(1.15, 1.15), displacementScale: 0 }),
    materialSet('forest-rock', { normalScale: new THREE.Vector2(1.2, 1.2), displacementScale: 0 }),
    materialSet('forest-earth', { normalScale: new THREE.Vector2(1, 1), displacementScale: 0 }),
    model('fern'), loader.loadAsync(assetUrl('textures/forest-fern/alpha.jpg')),
    loadForestWolfTemplate({ manager, maxAnisotropy: anisotropy }),
  ]);
  fernAlpha.flipY = false; fernAlpha.colorSpace = THREE.NoColorSpace; fernAlpha.anisotropy = anisotropy; textures.add(fernAlpha);
  let foliage;
  fern.traverse(object => {
    if (!object.isMesh) return;
    for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
      material.alphaMap = fernAlpha; material.alphaTest = .45; material.transparent = false;
      material.side = THREE.DoubleSide; material.depthWrite = true; material.roughness = 1;
      foliage ||= { map: material.map, alphaMap: fernAlpha };
    }
  });
  for (const template of [guardian, forestWolf]) template.traverse(object => {
    if (!object.isMesh) return;
    geometries.add(object.geometry);
    for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
      materials.add(material);
      for (const value of Object.values(material)) if (value?.isTexture) textures.add(value);
    }
  });
  onProgress('WALDBEWOHNER ERWACHEN …');
  // Bake the articulated orc's organic surfaces during the loading screen,
  // so the first encounter only clones the cached shape buffers.
  const { ForestCreature } = await import('./forest-creatures.js');
  new ForestCreature({}, 'orc').dispose();
  onProgress('MONDLICHT UND REFLEXIONEN …');
  hdri.mapping = THREE.EquirectangularReflectionMapping;
  const pmrem = new THREE.PMREMGenerator(renderer);
  const environmentTarget = pmrem.fromEquirectangular(hdri);
  pmrem.dispose(); hdri.dispose();

  // Props without vertex colors need separate material variants. All variants
  // share their 2K source maps, so maze changes never re-decode large textures.
  const trim = wall.clone(); trim.vertexColors = false; trim.color.setHex(0xc5c0b5);
  const masonry = wall.clone(); masonry.color.setHex(0xdad5c8);
  const ceiling = wall.clone(); ceiling.vertexColors = false; ceiling.color.setHex(0x656763);
  const plinth = floor.clone(); plinth.vertexColors = false; plinth.displacementScale = 0;
  for (const material of [trim, masonry, ceiling, plinth]) materials.add(material);

  return {
    wall, floor, trim, masonry, ceiling, plinth, statue, rock, guardian, forestWolf,
    forest: { ground: forestGround, bark: forestBark, rock: forestRock, earth: forestEarth, fern, foliage },
    environment: environmentTarget.texture,
    dispose() {
      for (const template of [guardian, forestWolf]) template.traverse(object => { if (object.isSkinnedMesh) object.skeleton.dispose(); });
      geometries.forEach(geometry => geometry.dispose());
      materials.forEach(material => material.dispose());
      textures.forEach(texture => texture.dispose());
      environmentTarget.dispose();
    },
  };
}
