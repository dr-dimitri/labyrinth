import * as THREE from 'three';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';

// Uses the existing contact-shadow depth buffer; no second scene render. Fog is
// integrated along the actual camera ray, so nearby silhouettes stay crisp.
export class DepthAtmospherePass extends ShaderPass {
  constructor(depthTexture) {
    super({
      uniforms: {
        tDiffuse: { value: null }, tDepth: { value: depthTexture },
        projectionInverse: { value: new THREE.Matrix4() }, cameraWorld: { value: new THREE.Matrix4() },
        eye: { value: new THREE.Vector3() }, fogTint: { value: new THREE.Color(0x627d85) },
        density: { value: .009 }, heightBase: { value: 0 }, heightFalloff: { value: .12 },
        shaftStrength: { value: 0 }, lightDirection: { value: new THREE.Vector3() },
        shadowTransform: { value: new THREE.Matrix4() }, tShadow: { value: null }, shadowReady: { value: false },
      },
      vertexShader: `varying vec2 vUv;
        void main(){ vUv=uv; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0); }`,
      fragmentShader: `
        varying vec2 vUv;
        uniform sampler2D tDiffuse, tDepth, tShadow;
        uniform mat4 projectionInverse, cameraWorld, shadowTransform;
        uniform vec3 eye, fogTint, lightDirection;
        uniform float density, heightBase, heightFalloff, shaftStrength;
        uniform bool shadowReady;
        #include <packing>
        float visibleToMoon(vec3 p) {
          if(!shadowReady) return 0.0;
          vec4 q=shadowTransform*vec4(p,1.0); q.xyz/=q.w;
          if(q.x<0.0||q.x>1.0||q.y<0.0||q.y>1.0||q.z<0.0||q.z>1.0) return 0.0;
          return step(q.z-.0012,unpackRGBAToDepth(texture2D(tShadow,q.xy)));
        }
        void main(){
          vec4 color=texture2D(tDiffuse,vUv);
          float z=texture2D(tDepth,vUv).x;
          // Background sky already has its own colour; don't fog it as a wall.
          if(z>=.999999){gl_FragColor=color;return;}
          vec4 v=projectionInverse*vec4(vUv*2.0-1.0,z*2.0-1.0,1.0); v/=v.w;
          vec3 hit=(cameraWorld*v).xyz, delta=hit-eye;
          float distanceToSurface=length(delta), lengthInFog=max(0.0,min(distanceToSurface,110.0)-2.5);
          vec3 ray=normalize(delta);
          float opticalDepth=0.0, litMist=0.0;
          float jitter=fract(sin(dot(gl_FragCoord.xy,vec2(12.9898,78.233)))*43758.5453);
          for(int i=0;i<6;i++){
            float t=(float(i)+.3+jitter*.4)/6.0;
            vec3 p=eye+ray*(2.5+lengthInFog*t);
            float heightDensity=clamp(exp((heightBase-p.y)*heightFalloff),.12,2.1);
            opticalDepth+=heightDensity/6.0;
            if(shaftStrength>.001) litMist+=heightDensity*visibleToMoon(p)/6.0;
          }
          float fogAmount=1.0-exp(-density*lengthInFog*opticalDepth);
          float forwardGlow=.35+.65*pow(max(0.0,dot(ray,lightDirection)),4.0);
          vec3 air=fogTint*(.55+shaftStrength*litMist*forwardGlow);
          gl_FragColor=vec4(mix(color.rgb,air,min(fogAmount,.84)),color.a);
        }`,
    });
    this.material.depthTest = false; this.material.depthWrite = false;
  }
  update(camera, moon, profile) {
    const u = this.uniforms;
    u.projectionInverse.value.copy(camera.projectionMatrixInverse);
    u.cameraWorld.value.copy(camera.matrixWorld);
    u.eye.value.copy(camera.position);
    u.fogTint.value.setHex(profile.haze);
    u.density.value = profile.hazeDensity;
    u.heightBase.value = profile.heightBase;
    u.heightFalloff.value = profile.heightFalloff;
    u.shaftStrength.value = profile.shafts;
    u.lightDirection.value.copy(moon.position).sub(moon.target.position).normalize();
    u.shadowReady.value = Boolean(moon.castShadow && moon.shadow.map);
    if (moon.shadow.map) {
      u.tShadow.value = moon.shadow.map.texture;
      u.shadowTransform.value.copy(moon.shadow.matrix);
    }
  }
}
