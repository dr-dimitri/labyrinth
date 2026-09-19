#include <metal_stdlib>
using namespace metal;
struct Vertex { float3 position; float3 normal; float2 uv; };
struct Instance { float4x4 model; float4 normal0; float4 normal1; float4 normal2; float4 tint; float4 material; };
struct Uniforms { float4x4 viewProjection; float4x4 inverseViewProjection; float4x4 lightViewProjection; float4 eyeTime; float4 sunDirection; float4 fogColor; float4 viewport; };
struct Raster { float4 position [[position]]; float3 world; float3 normal; float2 uv; float4 tint; float4 material; float4 shadow; };
float3 windPosition(float3 p, float2 uv, float material, float time) {
  if(material>3.5 && material<4.5) {
    // Flex only the tips of individual twigs. No whole-tree billboard rotation.
    float flexibility=pow(saturate((0.884-uv.y)/0.794),1.6);
    float gust=sin(time*1.25+p.x*0.115+p.z*0.13)+sin(time*2.1+p.y*0.37)*0.3;
    p.x+=gust*0.13*flexibility; p.z+=sin(time*1.7+p.x*0.18)*0.06*flexibility;
  }
  if(material>7.5 && material<8.5) {
    p.x+=sin(time*1.4+p.x*0.31+p.z*0.24)*0.035*uv.y*uv.y;
    p.z+=cos(time*1.1+p.z*0.27)*0.02*uv.y*uv.y;
  }
  return p;
}
vertex Raster worldVertex(uint vi [[vertex_id]],uint ii [[instance_id]],const device Vertex *vertices [[buffer(0)]],const device Instance *instances [[buffer(1)]],constant Uniforms &u [[buffer(2)]]) {
  Vertex v=vertices[vi]; Instance i=instances[ii]; Raster o;
  float4 p=i.model*float4(v.position,1); p.xyz=windPosition(p.xyz,v.uv,i.material.w,u.eyeTime.w);
  o.position=u.viewProjection*p; o.world=p.xyz; o.normal=normalize(float3x3(i.normal0.xyz,i.normal1.xyz,i.normal2.xyz)*v.normal);
  o.uv=v.uv; o.tint=i.tint; o.material=i.material; o.shadow=u.lightViewProjection*p; return o;
}
vertex Raster shadowVertex(uint vi [[vertex_id]],uint ii [[instance_id]],const device Vertex *vertices [[buffer(0)]],const device Instance *instances [[buffer(1)]],constant Uniforms &u [[buffer(2)]]) {
  Vertex v=vertices[vi]; Instance i=instances[ii]; Raster o;
  float4 p=i.model*float4(v.position,1); p.xyz=windPosition(p.xyz,v.uv,i.material.w,u.eyeTime.w);
  o.position=u.lightViewProjection*p; o.world=p.xyz; o.uv=v.uv; o.material=i.material; o.tint=i.tint; o.normal=v.normal; o.shadow=o.position; return o;
}
fragment void shadowFragment(Raster in [[stage_in]],texture2d<float> pineAlpha [[texture(0)]],sampler surface [[sampler(0)]]) {
  if(in.material.w>3.5 && in.material.w<4.5 && pineAlpha.sample(surface,in.uv).r<0.43) discard_fragment();
}
float3 aces(float3 c) { return saturate((c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14)); }
float hash(float3 p) { return fract(sin(dot(p,float3(12.9898,78.233,39.425)))*43758.5453); }
float noise(float2 p) { float2 i=floor(p),f=fract(p); f=f*f*(3-2*f); return mix(mix(hash(float3(i,0)),hash(float3(i+float2(1,0),0)),f.x),mix(hash(float3(i+float2(0,1),0)),hash(float3(i+1,0)),f.x),f.y); }
float3 perturbNormal(float3 n,float3 position,float2 uv,float3 map,float strength) {
  float3 q1=dfdx(position),q2=dfdy(position); float2 st1=dfdx(uv),st2=dfdy(uv);
  float3 t=q1*st2.y-q2*st1.y, b=q2*st1.x-q1*st2.x;
  float det=dot(t,t); if(det<0.000000001) return n;
  t=normalize(t-n*dot(n,t)); b=normalize(b-n*dot(n,b));
  return normalize(n*max(map.z,0.15)+t*map.x*strength+b*map.y*strength);
}
fragment float4 worldFragment(Raster in [[stage_in]],constant Uniforms &u [[buffer(2)]],
  texture2d<float> earthColor [[texture(0)]],texture2d<float> earthNormal [[texture(1)]],texture2d<float> earthRough [[texture(2)]],
  texture2d<float> concreteColor [[texture(3)]],texture2d<float> concreteNormal [[texture(4)]],texture2d<float> concreteRough [[texture(5)]],
  texture2d<float> rockColor [[texture(6)]],texture2d<float> rockNormal [[texture(7)]],texture2d<float> rockRough [[texture(8)]],
  texture2d<float> pineColor [[texture(9)]],depth2d<float> shadowMap [[texture(10)]],
  texture2d<float> barkColor [[texture(11)]],texture2d<float> barkNormal [[texture(12)]],texture2d<float> barkRough [[texture(13)]],
  texture2d<float> groundColor [[texture(14)]],texture2d<float> groundNormal [[texture(15)]],texture2d<float> groundRough [[texture(16)]],
  texture2d<float> asphaltColor [[texture(17)]],texture2d<float> asphaltNormal [[texture(18)]],texture2d<float> asphaltRough [[texture(19)]],
  texture2d<float> pineNormal [[texture(20)]],texture2d<float> pineAlpha [[texture(21)]],texture2d<float> pineRough [[texture(22)]],texture2d<float> photoSky [[texture(23)]],
  sampler surface [[sampler(0)]],sampler shadowSampler [[sampler(1)]]) {
  float3 n=normalize(in.normal),albedo=in.tint.rgb,map=float3(0,0,1);
  float rough=in.material.x,metal=in.material.y,emissive=in.material.z,coverage=1.0,canopyAO=1.0;
  int id=int(in.material.w+0.5); float2 uv; float3 absN=abs(n);
  if(absN.y>absN.x && absN.y>absN.z) uv=in.world.xz; else if(absN.x>absN.z) uv=in.world.zy; else uv=in.world.xy;
  uv*=0.5;
  if(id==1 || id==7) {
    uv=in.world.xz*0.76923; float2 leafUV=in.world.xz*0.5+float2(12.73,4.29);
    float macro=noise(in.world.xz*0.041); float forest=smoothstep(0.2,0.75,macro+smoothstep(7.0,32.0,abs(in.world.x))*0.36);
    if(id==7) forest=max(forest,0.6);
    float3 soil=earthColor.sample(surface,uv).rgb,leaves=groundColor.sample(surface,leafUV).rgb;
    // Different scales/materials and low-frequency colour masks suppress obvious
    // repeats without multiplying texture storage or adding terrain draw calls.
    albedo*=mix(soil,leaves,forest)*(0.83+macro*0.22+noise(in.world.xz*0.14)*0.10);
    rough*=mix(earthRough.sample(surface,uv).r,groundRough.sample(surface,leafUV).r,forest);
    map=mix(earthNormal.sample(surface,uv).xyz,groundNormal.sample(surface,leafUV).xyz,forest)*2-1;
    float exposed=smoothstep(0.12,0.38,1.0-n.y)*(0.45+noise(in.world.xz*0.35)*0.4);
    albedo=mix(albedo,rockColor.sample(surface,uv*0.6).rgb*in.tint.rgb,exposed);
    n=perturbNormal(n,in.world,uv,map,0.9);
  } else if(id==2) {
    albedo*=concreteColor.sample(surface,uv).rgb;
    float gray=dot(albedo,float3(0.2126,0.7152,0.0722)); albedo=mix(albedo,float3(gray),0.6);
    rough*=concreteRough.sample(surface,uv).r; map=concreteNormal.sample(surface,uv).xyz*2-1; n=perturbNormal(n,in.world,uv,map,0.55);
  } else if(id==3) {
    uv*=0.84034;
    float3 w=pow(absN,float3(5)); w/=max(w.x+w.y+w.z,0.001);
    float3 rocky=rockColor.sample(surface,in.world.zy*0.42017).rgb*w.x+rockColor.sample(surface,in.world.xz*0.42017).rgb*w.y+rockColor.sample(surface,in.world.xy*0.42017).rgb*w.z;
    albedo*=rocky*(0.8+noise(in.world.xz*0.18)*0.34); rough*=rockRough.sample(surface,uv).r;
    map=rockNormal.sample(surface,uv).xyz*2-1; n=perturbNormal(n,in.world,uv,map,0.82);
  } else if(id==4) {
    float alpha=pineAlpha.sample(surface,in.uv).r;
    if(alpha<0.12) discard_fragment();
    // 4x MSAA turns the sampled mask into stable subpixel needle coverage.
    coverage=saturate((alpha-0.2)/max(fwidth(alpha),0.16)+0.5);
    albedo*=pineColor.sample(surface,in.uv).rgb; rough*=pineRough.sample(surface,in.uv).r;
    canopyAO=clamp(metal,0.38,1.0); metal=0; emissive=0;
    if(dot(n,u.eyeTime.xyz-in.world)<0) n=-n;
    map=pineNormal.sample(surface,in.uv).xyz*2-1; n=perturbNormal(n,in.world,in.uv,map,0.28);
  } else if(id==5) {
    uv=float2(in.uv.x*1.65,in.uv.y*max(in.material.z,1.0)); emissive=0;
    albedo*=barkColor.sample(surface,uv).rgb; rough*=barkRough.sample(surface,uv).r;
    map=barkNormal.sample(surface,uv).xyz*2-1; n=perturbNormal(n,in.world,uv,map,0.9);
  } else if(id==6) {
    uv=in.world.xz*0.48077; albedo*=asphaltColor.sample(surface,uv).rgb;
    float shoulder=smoothstep(4.4,6.0,abs(in.world.x)); float grime=shoulder*(0.45+noise(in.world.xz*0.7)*0.25);
    albedo=mix(albedo,earthColor.sample(surface,in.world.xz*0.76923).rgb*0.52,grime);
    albedo*=0.91+noise(in.world.xz*0.12)*0.14; rough=max(0.78,rough*asphaltRough.sample(surface,uv).r);
    map=asphaltNormal.sample(surface,uv).xyz*2-1; n=perturbNormal(n,in.world,uv,map,0.55);
  } else if(id==14) {
    // Fabric-space camouflage follows the articulated body without swimming.
    float2 clothUV=in.uv*float2(11.0,16.0);
    float patch=noise(clothUV+noise(clothUV*0.57)*3.0);
    float blotch=noise(clothUV*1.9+float2(7.2,19.8));
    float3 pattern=mix(float3(0.58,0.61,0.46),float3(1.12,1.03,0.79),smoothstep(0.32,0.52,patch));
    pattern=mix(pattern,float3(0.33,0.37,0.28),smoothstep(0.60,0.74,blotch));
    float weave=sin(in.uv.x*920)*sin(in.uv.y*760);
    albedo*=pattern*(0.98+weave*0.025); rough=0.93; metal=0;
  } else if(id>=9 && id<=13) {
    // Fine UV-space finishes remain stable as the weapon moves; unlike world
    // hash blocks they do not crawl across the receiver or gloves.
    float grain=hash(float3(floor(in.uv*1500),float(id)));
    if(id==9) { albedo*=0.96+grain*0.07; rough=clamp(rough+(grain-0.5)*0.035,0.23,0.65); }
    else if(id==10) { albedo*=0.95+grain*0.085; metal=0.03; rough=max(0.66,rough); }
    else if(id==11) { float weave=sin(in.uv.x*900)*sin(in.uv.y*900); albedo*=0.96+weave*0.035+grain*0.04; rough=0.9; metal=0; }
    else if(id==12) { rough=0.10; metal=0; }
    else { albedo*=0.96+grain*0.045+sin(in.uv.y*850)*0.013; rough=0.28; metal=0.93; }
  } else {
    float weather=hash(floor(in.world*110)); float stain=noise(in.world.xz*2.1+in.world.y);
    albedo*=0.91+weather*0.11+stain*0.045;
  }
  rough=clamp(rough,id==12 ? 0.10:0.16,1.0);
  float3 l=normalize(u.sunDirection.xyz),v=normalize(u.eyeTime.xyz-in.world),h=normalize(l+v);
  float nl=max(dot(n,l),0.0),nv=max(dot(n,v),0.05),nh=max(dot(n,h),0.0),vh=max(dot(v,h),0.0);
  float alpha=rough*rough,a2=alpha*alpha,den=nh*nh*(a2-1)+1;
  float distribution=a2/max(M_PI_F*den*den,0.0001),k=(rough+1)*(rough+1)*0.125;
  float geometry=(nl/(nl*(1-k)+k))*(nv/(nv*(1-k)+k));
  float3 f0=mix(float3(0.04),albedo,metal),fresnel=f0+(1-f0)*pow(1-vh,5.0);
  float3 specular=distribution*geometry*fresnel/max(4*nl*nv,0.001);
  float visibility=1; float3 projected=in.shadow.xyz/in.shadow.w; float2 shadowUV=projected.xy*float2(0.5,-0.5)+0.5;
  if(all(shadowUV>0.0) && all(shadowUV<1.0) && projected.z>0 && projected.z<1) {
    float bias=max(0.00014,0.00055*(1-nl)); float2 texel=1.0/float2(shadowMap.get_width(),shadowMap.get_height()); visibility=0;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) visibility+=shadowMap.sample_compare(shadowSampler,shadowUV+float2(x,y)*texel,projected.z-bias);
    visibility/=9;
  }
  float3 ambient=mix(float3(0.12,0.115,0.085),float3(0.38,0.46,0.51),n.y*0.5+0.5)*albedo;
  float contact=mix(0.64,1.0,saturate(in.world.y*1.8)); if(id==1 || id==7 || id==6) contact=0.95;
  float3 irradiance=float3(3.05,2.90,2.52);
  float3 lit=ambient*contact*canopyAO+(albedo*(1-metal)/M_PI_F+specular)*irradiance*nl*visibility;
  if(id==4) {
    float wrap=pow(max(dot(-l,v),0.0),3.0); float transmission=(0.10+wrap*0.55)*max(0.0,0.5-dot(n,l)*0.5);
    lit+=albedo*float3(1.1,1.30,0.83)*transmission*mix(0.5,1.0,visibility)*canopyAO;
  }
  if(id>=9 && id<=13) {
    float3 reflected=reflect(-v,n);
    float2 envUV=float2(fract(atan2(reflected.z,reflected.x)/(2*M_PI_F)+0.97),acos(clamp(reflected.y,-1.0,1.0))/M_PI_F);
    float3 environment=photoSky.sample(surface,envUV,level(rough*7.0)).rgb;
    lit+=environment*fresnel*(0.35+metal*0.55)*(1-rough*0.5);
    // A restrained sky fill preserves bevels on dark anodised parts in shadow.
    lit+=albedo*float3(0.08,0.095,0.11)*(0.25+0.75*max(n.y,0.0));
    if(id==12) {
      // A convex coated lens reflects the actual sky; its dark interior stays
      // visible through the centre while grazing angles catch stronger glints.
      float glassFresnel=0.055+0.945*pow(1-nv,5.0);
      float3 coating=mix(float3(0.68,0.92,1.0),float3(0.45,0.73,0.63),pow(1-nv,2.0));
      lit=albedo*0.28+environment*coating*(0.13+glassFresnel*0.85)+specular*irradiance*nl*visibility;
    }
  }
  lit+=albedo*emissive;
  float distance=length(u.eyeTime.xyz-in.world),fogDistance=max(0.0,distance-45.0);
  float fog=1-exp(-fogDistance*fogDistance*0.0000065); lit=mix(lit,u.fogColor.rgb,fog);
  return float4(aces(lit*1.03),coverage);
}
struct SkyRaster { float4 position [[position]]; float2 uv; };
vertex SkyRaster skyVertex(uint id [[vertex_id]]) { float2 p=float2((id<<1)&2,id&2); SkyRaster o; o.uv=p; o.position=float4(p*2-1,0.99999,1); return o; }
fragment float4 skyFragment(SkyRaster in [[stage_in]],constant Uniforms &u [[buffer(2)]],texture2d<float> photoSky [[texture(23)]],sampler surface [[sampler(0)]]) {
  float4 p=u.inverseViewProjection*float4(in.uv*2-1,1,1); float3 ray=normalize(p.xyz/p.w-u.eyeTime.xyz);
  float azimuth=atan2(ray.z,ray.x)/(2*M_PI_F)+0.97;
  float elevation=acos(clamp(ray.y,-1.0,1.0))/M_PI_F;
  // Pure photographic sky uses spherical UVs without stretching a cutoff row.
  float2 uv=float2(fract(azimuth),elevation);
  float3 photo=photoSky.sample(surface,uv).rgb;
  float horizon=1-smoothstep(-0.015,0.055,ray.y); photo=mix(photo,u.fogColor.rgb*0.70,horizon*0.45);
  return float4(photo,1); // Source panorama is already tonemapped; no second ACES.
}

// The glTF vertex layout is 64 bytes in Swift and Metal. Joint indices address
// the concatenated body/visor skins; every palette matrix is already in world space.
struct SoldierSkinVertex { float3 position; float3 normal; float2 uv; ushort4 joints; float4 weights; };
struct SoldierRaster { float4 position [[position]]; float3 world; float3 normal; float2 uv; float4 shadow; };
float4x4 soldierSkinMatrix(SoldierSkinVertex v,const device float4x4 *joints,uint offset) {
  return joints[offset+v.joints.x]*v.weights.x+joints[offset+v.joints.y]*v.weights.y+
         joints[offset+v.joints.z]*v.weights.z+joints[offset+v.joints.w]*v.weights.w;
}
vertex SoldierRaster soldierVertex(uint vi [[vertex_id]],uint ii [[instance_id]],
  const device SoldierSkinVertex *vertices [[buffer(0)]],const device float4x4 *joints [[buffer(1)]],
  constant Uniforms &u [[buffer(2)]],constant uint &paletteCount [[buffer(3)]]) {
  SoldierSkinVertex v=vertices[vi];float4x4 skin=soldierSkinMatrix(v,joints,ii*paletteCount);
  float4 world=skin*float4(v.position,1);SoldierRaster o;
  o.position=u.viewProjection*world;o.world=world.xyz;o.uv=v.uv;o.shadow=u.lightViewProjection*world;
  // Cofactors retain the correct surface normal under blended/nonuniform bone
  // transforms, including the model's centimetre-to-metre normalisation.
  float3 a=skin[0].xyz,b=skin[1].xyz,c=skin[2].xyz;
  float3 normal=cross(b,c)*v.normal.x+cross(c,a)*v.normal.y+cross(a,b)*v.normal.z;
  float determinant=dot(a,cross(b,c));if(determinant<0) normal=-normal;
  o.normal=normalize(normal);return o;
}
vertex SoldierRaster soldierShadowVertex(uint vi [[vertex_id]],uint ii [[instance_id]],
  const device SoldierSkinVertex *vertices [[buffer(0)]],const device float4x4 *joints [[buffer(1)]],
  constant Uniforms &u [[buffer(2)]],constant uint &paletteCount [[buffer(3)]]) {
  SoldierSkinVertex v=vertices[vi];float4 p=soldierSkinMatrix(v,joints,ii*paletteCount)*float4(v.position,1);
  SoldierRaster o;o.position=u.lightViewProjection*p;o.world=p.xyz;o.uv=v.uv;o.normal=v.normal;o.shadow=o.position;return o;
}
fragment void soldierShadowFragment(SoldierRaster in [[stage_in]],texture2d<float> color [[texture(0)]],
  sampler surface [[sampler(0)]],constant uint &material [[buffer(3)]]) {
  if(material!=2 && color.sample(surface,in.uv).a<0.35) discard_fragment();
}
float3 soldierMappedNormal(float3 n,float3 p,float2 uv,float3 map) {
  float3 p1=dfdx(p),p2=dfdy(p);float2 uv1=dfdx(uv),uv2=dfdy(uv);
  float determinant=uv1.x*uv2.y-uv1.y*uv2.x;
  if(abs(determinant)<1e-10) return n;
  float3 t=(p1*uv2.y-p2*uv1.y)/determinant,b=(p2*uv1.x-p1*uv2.x)/determinant;
  t-=n*dot(t,n);b-=n*dot(b,n);
  if(dot(t,t)<1e-10 || dot(b,b)<1e-10) return n;
  return normalize(n*max(map.z,0.2)+normalize(t)*map.x*0.8+normalize(b)*map.y*0.8);
}
fragment float4 soldierFragment(SoldierRaster in [[stage_in]],constant Uniforms &u [[buffer(2)]],
  constant uint &material [[buffer(3)]],texture2d<float> color [[texture(0)]],
  texture2d<float> normalMap [[texture(1)]],texture2d<float> roughnessMap [[texture(2)]],
  depth2d<float> shadowMap [[texture(10)]],texture2d<float> photoSky [[texture(23)]],
  sampler surface [[sampler(0)]],sampler shadowSampler [[sampler(1)]]) {
  bool visor=material==2,skin=material==1;float4 texel=color.sample(surface,in.uv);
  if(!visor && texel.a<0.35) discard_fragment();
  float3 n=normalize(in.normal),v=normalize(u.eyeTime.xyz-in.world);
  if(dot(n,v)<0) n=-n;
  float3 detail=normalMap.sample(surface,in.uv).xyz*2-1;
  if(skin) detail.xy*=0.7;
  if(!visor) n=soldierMappedNormal(n,in.world,in.uv,detail);
  float3 albedo=visor ? float3(0.013,0.027,0.029):texel.rgb;
  float brightness=dot(albedo,float3(0.2126,0.7152,0.0722));
  // Lighter hard plates are slightly smoother; darker textile retains a broad,
  // matte response. The colour map itself supplies the photographic detail.
  float armor=skin ? 0:smoothstep(0.12,0.38,brightness)*(1-saturate(length(detail.xy)*1.4));
  float rough=visor ? 0.16:skin ? 0.60:clamp(roughnessMap.sample(surface,in.uv).r-armor*0.09,0.76,0.96);
  float3 l=normalize(u.sunDirection.xyz),h=normalize(l+v);
  float nl=max(dot(n,l),0.0),nv=max(dot(n,v),0.05),nh=max(dot(n,h),0.0),vh=max(dot(v,h),0.0);
  float alpha=rough*rough,a2=alpha*alpha,den=nh*nh*(a2-1)+1;
  float distribution=a2/max(M_PI_F*den*den,0.0001),k=(rough+1)*(rough+1)*0.125;
  float geometry=(nl/(nl*(1-k)+k))*(nv/(nv*(1-k)+k));
  float3 f0=visor ? float3(0.055,0.063,0.066):float3(0.035);
  float3 fresnel=f0+(1-f0)*pow(1-vh,5.0),specular=distribution*geometry*fresnel/max(4*nl*nv,0.001);
  float visibility=1;float3 projected=in.shadow.xyz/in.shadow.w;float2 shadowUV=projected.xy*float2(0.5,-0.5)+0.5;
  if(all(shadowUV>0.0) && all(shadowUV<1.0) && projected.z>0 && projected.z<1) {
    float bias=max(0.00012,0.0005*(1-nl));float2 texelSize=1.0/float2(shadowMap.get_width(),shadowMap.get_height());visibility=0;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) visibility+=shadowMap.sample_compare(shadowSampler,shadowUV+float2(x,y)*texelSize,projected.z-bias);
    visibility/=9;
  }
  float3 ambient=mix(float3(0.13,0.125,0.10),float3(0.38,0.46,0.51),n.y*0.5+0.5)*albedo;
  float3 lit=ambient+(albedo/M_PI_F+specular)*float3(3.05,2.90,2.52)*nl*visibility;
  if(skin) {
    float wrap=max(0.0,saturate((dot(n,l)+0.25)/1.25)-nl);
    lit+=albedo*float3(0.52,0.27,0.17)*wrap*0.28;
  }
  float3 reflected=reflect(-v,n);float2 envUV=float2(fract(atan2(reflected.z,reflected.x)/(2*M_PI_F)+0.97),acos(clamp(reflected.y,-1.0,1.0))/M_PI_F);
  float3 environment=photoSky.sample(surface,envUV,level(rough*7)).rgb;
  if(visor) {
    float grazing=0.06+0.94*pow(1-nv,5.0);
    lit=albedo*0.35+environment*float3(0.66,0.83,0.88)*(0.18+grazing*0.85)+specular*float3(3.05,2.90,2.52)*nl*visibility;
  } else { lit+=environment*f0*(0.18+armor*0.22); }
  float distance=length(u.eyeTime.xyz-in.world),fogDistance=max(0.0,distance-45.0);
  float fog=1-exp(-fogDistance*fogDistance*0.0000065);lit=mix(lit,u.fogColor.rgb,fog);
  return float4(aces(lit*1.03),1);
}
