/* ============================================================================
   gl.js — WebGL2 engine that runs the REAL shader logic (a GLSL ES 3.0 port of
   the app's Metal über-shader) on the GPU. Exposes window.DotEngine with the
   same surface app.js expects, so it transparently replaces the 2D engine.js
   when WebGL2 is available. engine.js stays as the fallback for old browsers.
============================================================================ */
(function () {
  "use strict";
  const testGL = document.createElement("canvas").getContext("webgl2");
  if (!testGL) return;                         // no WebGL2 → keep canvas engine
  // (further down, we also probe-compile the shader and bail if it fails, so a
  //  shader bug degrades to the 2D canvas engine instead of a blank site.)

  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* effect name → (id, packer(params)->{p0,p1,p2,a,b}). Mirrors Effects.swift. */
  const BLACK = [0, 0, 0], WHITE = [1, 1, 1], GREEN = [0.1, 1.0, 0.45];
  const INK = [0.05, 0.06, 0.09], PAPER = [0.92, 0.93, 0.96], CYAN = [0.3, 0.9, 1.0];
  const v4 = (a, b, c, d) => [a || 0, b || 0, c || 0, d || 0];
  const g = (p, k, d) => (p && p[k] != null ? p[k] : d);

  const FX = {
    halftone: { id: 4, a: PAPER, b: INK, pack: p => ({ p0: v4(g(p,"cell",10), g(p,"angle",0.4)) }) },
    ascii:    { id: 18, a: BLACK, b: GREEN, pack: p => ({ p0: v4(g(p,"cell",12), 0, g(p,"color",1)) }) },
    dither:   { id: 3, a: BLACK, b: CYAN, pack: p => ({ p0: v4(g(p,"cell",2.4), g(p,"levels",4), g(p,"mono",1), g(p,"method",1)) }) },
    matrix:   { id: 19, a: BLACK, b: GREEN, pack: p => ({ p0: v4(g(p,"cell",14), g(p,"speed",1), g(p,"reveal",1)) }) },
    dots:     { id: 5, a: BLACK, b: CYAN, pack: p => ({ p0: v4(g(p,"cell",13), 0, 0) }) },
    thermal:  { id: 33, pack: p => ({ p0: v4(g(p,"gain",1.1)) }) },
    neon:     { id: 28, a: BLACK, b: CYAN, pack: p => ({ p0: v4(g(p,"gain",3), g(p,"cell",4)) }) },
    voronoi:  { id: 16, pack: p => ({ p0: v4(g(p,"count",26)) }) },
    hex:      { id: 24, pack: p => ({ p0: v4(g(p,"cell",18)) }) },
    gameboy:  { id: 27, pack: p => ({ p0: v4(g(p,"dither",2)) }) },
    scanlines:{ id: 10, pack: p => ({ p0: v4(g(p,"cell",2.2), 0.4) }) },
    vhs:      { id: 17, pack: p => ({ p0: v4(g(p,"amount",1)) }) },
    nes:      { id: 36, pack: p => ({ p0: v4(6, g(p,"scan",0.32), 1.35) }) },
    threshold:{ id: 6, a: INK, b: [0.95,0.7,0.2], pack: p => ({ p0: v4(g(p,"thr",0.5), g(p,"soft",0.03)) }) },
    kaleidoscope:{ id: 21, pack: p => ({ p0: v4(g(p,"seg",8), g(p,"spin",1)) }) },
    swirl:    { id: 30, pack: p => ({ p0: v4(g(p,"amount",6), g(p,"spin",0.6)) }) },
    ripple:   { id: 31, pack: p => ({ p0: v4(g(p,"amp",2), g(p,"freq",40), g(p,"speed",2)) }) },
    starfield:{ id: 37, a: BLACK, b: WHITE, pack: p => ({ p0: v4(g(p,"speed",1), g(p,"count",12)/12*10 || 10, g(p,"warp",0.45), 1) }) },
    universe: { id: 39, pack: p => ({ p0: v4(g(p,"scale",1), g(p,"speed",1), g(p,"stars",1), g(p,"planets",1)), p2: v4(-2.13, 0.66, 1, 1) }) },
    blackhole:{ id: 40, pack: p => ({ p0: v4(g(p,"mass",0.4), g(p,"brightness",5), g(p,"rot",-8.7), g(p,"disk",1)), p1: v4(g(p,"speed",1), g(p,"stars",1), g(p,"angle",0.22), 0) }) },
  };
  // starfield density: site passes count(80..400); map to shader density ~ count/24
  FX.starfield.pack = p => ({ p0: v4(g(p,"speed",1), Math.max(3, (g(p,"count",240)) / 24), g(p,"warp",0.45), 1) });

  const VERT = `#version 300 es
  void main(){ vec2 p = vec2(float((gl_VertexID<<1)&2), float(gl_VertexID&2));
    gl_Position = vec4(p*2.0-1.0, 0.0, 1.0); }`;

  const FRAG = `#version 300 es
  precision highp float;
  precision highp int;
  out vec4 O;
  uniform int uEffect; uniform float uTime; uniform vec2 uRes;
  uniform vec4 uP0, uP1, uP2; uniform vec3 uColA, uColB;
  uniform sampler2D uGlyph; uniform int uGlyphCount; uniform float uGlyphW;
  const vec3 LUMA = vec3(0.299,0.587,0.114);
  float luma(vec3 c){ return dot(c, LUMA); }
  float hash21(vec2 p){ p = fract(p*vec2(123.34,456.21)); p += dot(p, p+45.32); return fract(p.x*p.y); }
  vec2 hash22(vec2 p){ float n=hash21(p); return vec2(n, hash21(p+n)); }
  float vnoise(vec2 p){ vec2 i=floor(p), f=fract(p); vec2 u=f*f*(3.0-2.0*f);
    float a=hash21(i), b=hash21(i+vec2(1,0)), c=hash21(i+vec2(0,1)), d=hash21(i+vec2(1,1));
    return mix(mix(a,b,u.x), mix(c,d,u.x), u.y); }
  float fbm(vec2 p){ float a=0.5,f=0.0; for(int i=0;i<5;i++){ f+=a*vnoise(p); p*=2.02; a*=0.5; } return f; }
  float hash31(vec3 p){ return fract(sin(dot(p, vec3(127.1,311.7,74.7)))*43758.5453); }
  float noise3(vec3 p){ vec3 i=floor(p), f=fract(p); vec3 u=f*f*(3.0-2.0*f);
    float a=hash31(i), b=hash31(i+vec3(1,0,0)), c=hash31(i+vec3(0,1,0)), d=hash31(i+vec3(1,1,0));
    float e=hash31(i+vec3(0,0,1)), f2=hash31(i+vec3(1,0,1)), gg=hash31(i+vec3(0,1,1)), h=hash31(i+vec3(1,1,1));
    return mix(mix(mix(a,b,u.x),mix(c,d,u.x),u.y), mix(mix(e,f2,u.x),mix(gg,h,u.x),u.y), u.z); }
  float fbm3(vec3 p, float lac, float pers){ float v=0.0, amp=0.5; for(int i=0;i<4;i++){ v+=noise3(p)*amp; p*=lac; amp*=pers; } return v; }
  vec3 blackbody(float K){ float t=clamp((K-1000.0)/9000.0,0.0,1.0);
    float r=clamp(1.0-(t-0.8)*2.0,0.5,1.0); float gn=smoothstep(0.0,0.5,t)*(1.0-max((t-0.7)*0.3,0.0));
    float bl=smoothstep(0.3,1.0,t)*t; return vec3(r,gn,bl); }
  vec3 aces(vec3 x){ return clamp((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14),0.0,1.0); }
  float ign(vec2 p){ return fract(52.9829189*fract(0.06711056*p.x+0.00583715*p.y))-0.5; }
  float bayer(int m, ivec2 c){
    if(m==0){ float t[4]=float[4](-0.5,0.0,0.25,-0.25); return t[(c.y&1)*2+(c.x&1)]; }
    // bayer4 normalized -0.5..0.5
    float b4[16]=float[16](0.,8.,2.,10.,12.,4.,14.,6.,3.,11.,1.,9.,15.,7.,13.,5.);
    return b4[(c.y&3)*4+(c.x&3)]/16.0-0.5; }
  float ditherThr(int m, ivec2 c){ if(m==3) return ign(vec2(c)); if(m==4) return hash21(vec2(c))-0.5; return bayer(m, c); }
  vec3 heatRamp(float t){ t=clamp(t,0.0,1.0);
    vec3 c=mix(vec3(0.0,0.0,0.10), vec3(0.5,0.0,0.6), smoothstep(0.0,0.35,t));
    c=mix(c, vec3(1.0,0.25,0.0), smoothstep(0.30,0.65,t));
    c=mix(c, vec3(1.0,0.9,0.2), smoothstep(0.60,0.85,t));
    c=mix(c, vec3(1.0), smoothstep(0.85,1.0,t)); return c; }
  vec2 hexCenter(vec2 p){ vec2 r=vec2(1.0,1.7320508), h=r*0.5;
    vec2 a=mod(p,r)-h, b=mod(p-h,r)-h; return dot(a,a)<dot(b,b)? p-a : p-b; }

  // ---- procedural source: a colourful animated field for effects to chew on ----
  vec3 srcCol(vec2 uv){
    float gg = clamp(dot(uv-0.5, vec2(cos(0.9),sin(0.9)))+0.5, 0.0, 1.0);
    vec3 base = mix(vec3(0.04,0.07,0.20), vec3(0.10,0.78,0.92), gg);
    float n = fbm(uv*3.0 + vec2(uTime*0.05, uTime*0.03));
    float n2 = fbm(uv*6.5 - vec2(uTime*0.04, uTime*0.02));
    float lum = smoothstep(0.35, 0.95, n*0.75 + n2*0.45);
    base = mix(base, vec3(0.96,0.99,1.0), lum*0.6);
    base += vec3(0.10,0.04,0.18) * smoothstep(0.6,1.0, n2);
    return clamp(base, 0.0, 1.0);
  }
  float srcL(vec2 uv){ return luma(srcCol(uv)); }
  float glyphInk(int gi, vec2 local){
    gi = clamp(gi, 0, uGlyphCount-1);
    vec2 a = vec2((float(gi)+local.x)/float(uGlyphCount), local.y);
    return texture(uGlyph, a).r;
  }
  float sobelMag(vec2 uv, float scale){
    vec2 o = scale/uRes; float gx=0.0, gy=0.0;
    gx += srcL(uv+vec2(-o.x,-o.y))*-1.0 + srcL(uv+vec2(o.x,-o.y))*1.0
        + srcL(uv+vec2(-o.x,0))*-2.0 + srcL(uv+vec2(o.x,0))*2.0
        + srcL(uv+vec2(-o.x,o.y))*-1.0 + srcL(uv+vec2(o.x,o.y))*1.0;
    gy += srcL(uv+vec2(-o.x,-o.y))*-1.0 + srcL(uv+vec2(0,-o.y))*-2.0 + srcL(uv+vec2(o.x,-o.y))*-1.0
        + srcL(uv+vec2(-o.x,o.y))*1.0 + srcL(uv+vec2(0,o.y))*2.0 + srcL(uv+vec2(o.x,o.y))*1.0;
    return length(vec2(gx,gy));
  }

  void main(){
    vec2 uv = gl_FragCoord.xy / uRes; uv.y = 1.0 - uv.y;
    vec2 px = uv * uRes; float t = uTime; int E = uEffect;
    vec3 base = srcCol(uv); float L = luma(base);
    vec3 outc = base;

    if(E==4){ float cell=max(uP0.x,2.0); float ang=uP0.y; mat2 R=mat2(cos(ang),-sin(ang),sin(ang),cos(ang));
      vec2 rp=R*px; vec2 gp=(floor(rp/cell)+0.5)*cell; vec2 cc=(transpose(R)*gp)/uRes;
      float lv=srcL(cc); vec2 lo=(rp-gp)/cell; float d=length(lo)*2.0; float r=sqrt(1.0-lv);
      outc=mix(uColA, uColB, smoothstep(r+0.05,r-0.05,d)); }
    else if(E==18){ float cell=max(uP0.x,4.0); ivec2 cp=ivec2(floor(px/cell));
      vec2 cc=(vec2(cp)+0.5)*cell/uRes; vec3 c=srcCol(cc); float lv=luma(c);
      int gi=int(lv*float(uGlyphCount)); vec2 lo=(px-vec2(cp)*cell)/cell;
      float ink=glyphInk(gi, lo); vec3 fg = uP0.z>0.5? c : uColB; outc=mix(uColA, fg, ink); }
    else if(E==3){ float cell=max(uP0.x,1.0); float lv2=max(uP0.y,2.0); bool mono=uP0.z>0.5; int m=int(uP0.w+0.5);
      ivec2 cp=ivec2(floor(px/cell)); vec2 cc=(vec2(cp)+0.5)*cell/uRes; vec3 c=srcCol(cc);
      float thr=(m==3)?ign(vec2(cp)):ditherThr(m,cp);
      if(mono){ float v=luma(c)+thr/(lv2-1.0); float q=floor(v*(lv2-1.0)+0.5)/(lv2-1.0); outc=mix(uColA,uColB,clamp(q,0.0,1.0)); }
      else { vec3 v=c+thr/(lv2-1.0); outc=clamp(floor(v*(lv2-1.0)+0.5)/(lv2-1.0),0.0,1.0); } }
    else if(E==19){ float cell=max(uP0.x,6.0); float speed=uP0.y; ivec2 cp=ivec2(floor(px/cell));
      float colSeed=hash21(vec2(float(cp.x),3.0)); float colSpeed=0.4+colSeed*1.6;
      float head=fract(colSeed+t*speed*0.08*colSpeed)*(uRes.y/cell+12.0); float dist=head-float(cp.y);
      float bright = dist>=0.0? exp(-dist*0.18):0.0;
      float gsel=floor(hash21(vec2(float(cp.x), float(cp.y)+floor(t*6.0)))*float(uGlyphCount));
      vec2 lo=(px-vec2(cp)*cell)/cell; float ink=glyphInk(int(gsel),lo)*bright;
      float srcMod=mix(1.0, srcL((vec2(cp)+0.5)*cell/uRes)+0.3, uP0.z);
      vec3 col=uColB; if(dist<1.0&&dist>=0.0) col=mix(col, vec3(1.0), 0.7);
      outc=uColA + col*ink*srcMod; }
    else if(E==5){ float cell=max(uP0.x,2.0); vec2 gp=(floor(px/cell)+0.5)*cell; float lv=srcL(gp/uRes);
      float d=length(px-gp)/(cell*0.5); float r=mix(0.05,1.0,pow(lv,0.7)); outc=mix(uColA,uColB,smoothstep(r,r-0.12,d)); }
    else if(E==33){ outc=heatRamp(L*uP0.x); }
    else if(E==28){ float gain=uP0.x; float gm=sobelMag(uv,max(uP0.y,1.0)); float e=pow(clamp(gm*gain,0.0,1.0),1.4); outc=uColA+uColB*e; }
    else if(E==16){ float sc=max(uP0.x,1.0); vec2 gp=uv*sc*vec2(uRes.x/uRes.y,1.0); vec2 cl=floor(gp);
      float best=1e9; vec2 bc=gp; for(int j=-1;j<=1;j++)for(int i=-1;i<=1;i++){ vec2 nb=cl+vec2(i,j); vec2 ct=nb+hash22(nb); float d=distance(gp,ct); if(d<best){best=d;bc=ct;} }
      vec2 cuv=bc/(sc*vec2(uRes.x/uRes.y,1.0)); outc=srcCol(clamp(cuv,0.0,1.0)); }
    else if(E==24){ float s=max(uP0.x,4.0); vec2 p=px/s; vec2 ct=hexCenter(p)*s/uRes; outc=srcCol(clamp(ct,0.0,1.0)); }
    else if(E==27){ vec3 p0=vec3(0.06,0.22,0.06),p1=vec3(0.19,0.38,0.19),p2=vec3(0.55,0.67,0.06),p3=vec3(0.61,0.74,0.06);
      float l=L; float thr=bayer(1, ivec2(px/max(uP0.x,1.0))); l=clamp(l+thr*0.5,0.0,1.0);
      outc = l<0.25?p0 : l<0.5?p1 : l<0.75?p2 : p3; }
    else if(E==10){ float sp=max(uP0.x,1.0); float inten=uP0.y; float s=0.5+0.5*sin(px.y/sp*3.14159);
      vec3 c=base*(1.0-inten*(1.0-s)); float m=0.85+0.15*cos(px.x*2.094); outc=c*m; }
    else if(E==17){ float amt=uP0.x; float yj=sin(uv.y*120.0+t*8.0)*0.0015*amt; float wob=(vnoise(vec2(uv.y*30.0,t))-0.5)*0.01*amt;
      float off=(0.004+0.006*vnoise(vec2(t,uv.y*8.0)))*amt; vec2 d=vec2(yj+wob,0.0);
      vec3 c=vec3(srcCol(uv+d+vec2(off,0)).r, srcCol(uv+d).g, srcCol(uv+d-vec2(off,0)).b);
      c*=0.9+0.1*sin(px.y*1.4); c+=(hash21(px+floor(t*50.0))-0.5)*0.10*amt;
      float band=step(0.992,fract(uv.y*1.3-t*0.4)); outc=mix(c,c+0.25,band*amt); }
    else if(E==36){ float cell=max(uP0.x,2.0); float scan=uP0.y; ivec2 cp=ivec2(floor(px/cell));
      vec3 c=srcCol((vec2(cp)+0.5)*cell/uRes); float l=luma(c); c=clamp(mix(vec3(l),c,max(uP0.z,0.0)),0.0,1.0);
      // quantize to a small curated NES-ish set (palette match in-shader is costly; use ramp)
      vec3 pal[6]=vec3[6](vec3(0.06,0.09,0.25),vec3(0.09,0.37,0.62),vec3(0.17,0.66,0.66),vec3(0.34,0.72,0.37),vec3(0.82,0.72,0.37),vec3(0.93,0.95,0.84));
      int idx=int(clamp(l*6.0,0.0,5.0)); vec3 q=pal[idx];
      // tint toward source hue a touch
      q=mix(q, q*0.6+c*0.7, 0.25);
      float s=1.0-scan*(0.5-0.5*cos(px.y/cell*6.2831853)); outc=q*s; }
    else if(E==6){ float thr=uP0.x; float soft=max(uP0.y,0.001); outc=mix(uColA,uColB,smoothstep(thr-soft,thr+soft,L)); }
    else if(E==21){ float seg=max(uP0.x,2.0); float spin=uP0.y; vec2 c=uv-0.5; float r=length(c);
      float a=atan(c.y,c.x)+t*0.15*spin; float sa=6.2831853/seg; a=mod(a,sa); a=min(a,sa-a);
      vec2 q=0.5+vec2(cos(a),sin(a))*r; outc=srcCol(clamp(q,0.0,1.0)); }
    else if(E==30){ float amt=uP0.x; vec2 c=uv-0.5; float r=length(c); float a=amt*(0.5-r)+t*0.1*uP0.y;
      float s=sin(a),co=cos(a); vec2 q=vec2(c.x*co-c.y*s, c.x*s+c.y*co)+0.5; outc=srcCol(clamp(q,0.0,1.0)); }
    else if(E==31){ float amp=uP0.x; float freq=uP0.y; float speed=uP0.z; vec2 c=uv-0.5; float r=length(c)+1e-5;
      float off=sin(r*freq-t*speed)*amp*0.01; vec2 q=uv+(c/r)*off; outc=srcCol(clamp(q,0.0,1.0)); }

    /* ---------- generative: starfield ---------- */
    else if(E==37){ float speed=uP0.x; float density=max(uP0.y,1.0); float warp=uP0.z; float sz=max(uP0.w,0.2);
      vec2 uv2=(uv-0.5)*vec2(uRes.x/uRes.y,1.0); vec2 rd=normalize(uv2+1e-5); vec3 acc=vec3(0.0);
      for(int i=0;i<18;i++){ float fi=(float(i)+0.5)/18.0; float depth=fract(fi+t*speed*0.08);
        float scale=mix(density*2.0,density*0.25,depth); float fade=depth*(1.0-depth)*4.0;
        vec2 p=uv2*scale+vec2(fi*91.7, fi*47.3); vec2 cell=floor(p); vec2 f=fract(p)-0.5;
        vec2 jit=(hash22(cell+fi*71.0)-0.5)*0.7; vec2 fd=f-jit; fd-=rd*dot(fd,rd)*warp;
        float d=length(fd); float r=0.05*sz; float star=smoothstep(r,r*0.28,d);
        float b=hash21(cell+fi*31.0); acc+=star*fade*(0.55+0.55*b); }
      outc=mix(uColA, uColB, clamp(acc,0.0,1.0)); }

    /* ---------- generative: universe (top-down heliocentric) ---------- */
    else if(E==39){ float aspect=uRes.x/uRes.y; vec2 sc=(uv-0.5)*vec2(aspect,1.0);
      float scale=max(uP0.x,0.3); float speed=uP0.y; float starsAmt=max(uP0.z,0.0); float planetSpeed=uP0.w;
      const float TILT=0.82; float rc=length(sc); vec3 col=vec3(0.0);
      col += vec3(0.10,0.05,0.02)*smoothstep(0.95*scale,0.0,rc);
      for(int Lr=0;Lr<2;Lr++){ float s=5.0+float(Lr)*4.0; vec2 gp=sc*s; vec2 cell=floor(gp); vec2 f=fract(gp)-0.5;
        vec2 j=(hash22(cell+float(Lr)*17.0)-0.5)*0.8; float star=smoothstep(0.05,0.0,length(f-j))*step(0.86,hash21(cell+float(Lr)*5.0));
        col+=vec3(0.7,0.8,1.0)*star*(0.4+0.6*hash21(cell))*0.6*starsAmt; }
      float bsz[8]=float[8](0.016,0.024,0.026,0.020,0.050,0.044,0.033,0.032);
      float osp[8]=float[8](1.60,1.18,1.00,0.81,0.44,0.32,0.23,0.18);
      vec3 fb[8]=vec3[8](vec3(0.6,0.6,0.62),vec3(0.85,0.75,0.5),vec3(0.2,0.4,0.7),vec3(0.8,0.4,0.25),vec3(0.8,0.66,0.45),vec3(0.85,0.75,0.5),vec3(0.6,0.85,0.9),vec3(0.35,0.45,0.85));
      if(uP2.w>0.5){ for(int i=0;i<8;i++){ float orad=(0.12+float(i)*0.072)*scale;
        float rp=length(vec2(sc.x/orad, sc.y/(orad*TILT))); col+=vec3(0.42,0.42,0.48)*smoothstep(0.004,0.0,abs(rp-1.0))*0.33; } }
      float sunR=0.026*scale;
      col+=vec3(1.0,0.55,0.22)*smoothstep(sunR*9.0,sunR*1.2,rc)*0.30;
      col+=vec3(1.0,0.82,0.45)*smoothstep(sunR*2.4,sunR*0.9,rc)*0.85;
      col+=vec3(1.0,0.97,0.9)*smoothstep(sunR*1.1,sunR*0.55,rc);
      for(int i=0;i<8;i++){ float orad=(0.12+float(i)*0.072)*scale; float ph=hash21(vec2(float(i),7.0))*6.2831853;
        float a=t*speed*0.07*osp[i]*planetSpeed+ph; vec2 pp=vec2(cos(a)*orad, sin(a)*orad*TILT); float pr=bsz[i]*scale;
        if(i==5){ vec2 rl=(sc-pp)/vec2(pr*2.2, pr*2.2*TILT); float rr=length(rl);
          float ring=smoothstep(1.0,0.93,rr)*smoothstep(0.6,0.66,rr); ring*=1.0-0.7*smoothstep(0.79,0.805,rr)*smoothstep(0.85,0.835,rr);
          col=mix(col, vec3(0.82,0.74,0.54), ring*0.7); }
        vec2 lp=(sc-pp)/pr; float r2=dot(lp,lp);
        if(r2<1.0){ vec3 n=vec3(lp.x,-lp.y,sqrt(1.0-r2)); vec2 sd=normalize(-pp+1e-5); vec3 sdir=normalize(vec3(sd.x,-sd.y,0.18));
          vec3 c2 = i==2? vec3(0.18,0.4,0.7) : fb[i];
          // simple latitude shading bands for a little detail
          c2 *= 0.85+0.15*sin(n.y*8.0);
          float lit=smoothstep(-0.4,0.45,dot(n,sdir))*0.82+0.18; lit*=mix(0.75,1.0,n.z);
          vec3 pc=c2*lit;
          if(i==2 && uP2.z>0.5){ float md=length(vec2(lp.x-0.2, lp.y+0.1)); pc=mix(pc, vec3(0.3,1.0,0.45), smoothstep(0.3,0.0,md)*(0.5+0.5*sin(t*3.0))); }
          col=mix(col, pc, smoothstep(1.0,0.9,r2)); } }
      outc=col; }

    /* ---------- generative: black hole (raymarch) ---------- */
    else if(E==40){ float mass=max(uP0.x,0.05); float brightness=uP0.y; float rotSpeed=uP0.z; float diskScale=max(uP0.w,0.3);
      float speed=max(uP1.x,0.0); float starsAmt=max(uP1.y,0.0); float angle=clamp(uP1.z,0.03,1.45); float ts=t*speed;
      float rs=mass*2.0; float innerR=4.1*diskScale, outerR=14.5*diskScale;
      const float diskTemp=49.78, tempFalloff=5.22, turbScale=1.81, turbStretch=0.75;
      const float turbSharp=7.4, turbCycle=5.0, turbLac=2.5, turbPers=0.8;
      const float edgeIn=0.18, edgeOut=0.5, lensing=2.4, dopplerStr=1.0, stepSize=1.0;
      vec2 sp=(uv-0.5)*2.0; sp.y=-sp.y; sp.x*=uRes.x/uRes.y;
      float ce=cos(angle), se=sin(angle); float ct=ts*0.025;
      vec3 camPos=vec3(sin(ct)*20.0*ce, -se*20.0, -cos(ct)*20.0*ce);
      vec3 fwd=normalize(-camPos); vec3 right=normalize(cross(vec3(0,1,0),fwd)); vec3 cup=cross(fwd,right);
      vec3 rayDir=normalize(fwd+right*sp.x+cup*sp.y); vec3 rayPos=camPos, prevPos=camPos;
      vec3 acc=vec3(0.0); float alpha=0.0; int state=0;
      for(int s=0;s<32;s++){ if(alpha>0.99) break; float r=length(rayPos);
        if(r<rs*1.01){ state=2; break; } if(r>100.0){ state=1; break; }
        vec3 toC=-rayPos/r; rayDir=normalize(rayDir+toC*(rs/(r*r)*stepSize*lensing));
        prevPos=rayPos; rayPos+=rayDir*stepSize;
        if(prevPos.y*rayPos.y<0.0){ float tt=-prevPos.y/(rayPos.y-prevPos.y); vec3 hit=mix(prevPos,rayPos,tt);
          float hitR=sqrt(hit.x*hit.x+hit.z*hit.z);
          if(hitR>innerR && hitR<outerR){ float ang=atan(hit.z,hit.x); float normR=clamp((hitR-innerR)/(outerR-innerR),0.0,1.0);
            float tf=pow(innerR/hitR,tempFalloff); vec3 dc=blackbody(mix(1500.0,diskTemp*1000.0,tf));
            float rsgn=sign(rotSpeed); vec3 velDir=vec3(-sin(ang)*rsgn,0.0,cos(ang)*rsgn);
            float beta=(1.0/sqrt(hitR/innerR))*0.3; float dopp=1.0/(1.0-beta*dot(velDir,rayDir));
            dc*=clamp(pow(dopp,3.0*dopplerStr),0.1,5.0);
            float dl=dot(dc,vec3(0.3,0.59,0.11)); dc=mix(dc, vec3(dl,dl*0.9,dl*0.74), 0.4);
            float edge=smoothstep(0.0,edgeIn,normR)*smoothstep(1.0,1.0-edgeOut,normR);
            float cyc=mod(ts,turbCycle); float blend=cyc/turbCycle;
            float kp1=cyc*rotSpeed/pow(hitR,1.5); float kp2=(cyc+turbCycle)*rotSpeed/pow(hitR,1.5);
            float ra1=ang+kp1, ra2=ang+kp2;
            vec3 nc1=vec3(hitR*turbScale, cos(ra1)/max(turbStretch,0.1), sin(ra1)/max(turbStretch,0.1));
            vec3 nc2=vec3(hitR*turbScale, cos(ra2)/max(turbStretch,0.1), sin(ra2)/max(turbStretch,0.1));
            float tb=mix(fbm3(nc2,turbLac,turbPers), fbm3(nc1,turbLac,turbPers), blend);
            float op=pow(clamp(tb,0.0,1.0),turbSharp)*edge; float rem=1.0-alpha;
            acc+=dc*brightness*op*rem; alpha+=rem*op; } } }
      if(state!=2 && alpha<0.99){ vec3 bg=vec3(0.0);
        float theta=atan(rayDir.z,rayDir.x), phi=asin(clamp(rayDir.y,-1.0,1.0)); vec2 scd=vec2(theta,phi)*50.0;
        vec2 cell=floor(scd), cuv=fract(scd); float sprob=step(1.0-0.1*starsAmt,hash21(cell));
        vec2 spos=hash22(cell+42.0)*0.8+0.1; float dts=length(cuv-spos); float bsv=hash21(cell+100.0)*0.03+0.012;
        float si=(smoothstep(bsv,0.0,dts)+smoothstep(bsv*3.0,0.0,dts)*0.3)*sprob;
        bg+=mix(vec3(0.8,0.9,1.0),vec3(1.0,0.95,0.8),hash21(cell+200.0))*si*0.7*starsAmt;
        float n1=fbm3(rayDir*2.0,2.0,0.5)*2.0-1.0; bg+=vec3(0.027,0.122,0.267)*clamp(n1+0.5,0.0,1.0)*0.06;
        float n2=fbm3(rayDir*5.5,2.0,0.5)*2.0-1.0; bg+=vec3(0.004,0.024,0.082)*clamp(n2+0.05,0.0,1.0)*0.22;
        acc+=bg*(1.0-alpha); }
      outc=aces(acc); }

    O = vec4(outc, 1.0);
  }`;

  function compile(gl, type, src) {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { console.error("GL shader:", gl.getShaderInfoLog(s)); return null; }
    return s;
  }

  // glyph atlas (monospace ramp) shared across all views
  let glyphCanvas = null, glyphCount = 12;
  function buildGlyphCanvas() {
    if (glyphCanvas) return glyphCanvas;
    const chars = " .:-=+*#%@".split(""); glyphCount = chars.length;   // dark→light ramp
    const cw = 24, ch = 24; const cv = document.createElement("canvas");
    cv.width = cw * chars.length; cv.height = ch; const x = cv.getContext("2d");
    x.fillStyle = "#000"; x.fillRect(0, 0, cv.width, ch);
    x.fillStyle = "#fff"; x.font = "700 18px ui-monospace, Menlo, monospace";
    x.textAlign = "center"; x.textBaseline = "middle";
    chars.forEach((c, i) => x.fillText(c, i * cw + cw / 2, ch / 2 + 1));
    glyphCanvas = cv; return cv;
  }

  const PROG = new WeakMap();   // gl context → {program, locs}
  function getProgram(gl) {
    if (PROG.has(gl)) return PROG.get(gl);
    const vs = compile(gl, gl.VERTEX_SHADER, VERT), fs = compile(gl, gl.FRAGMENT_SHADER, FRAG);
    if (!vs || !fs) return null;
    const p = gl.createProgram(); gl.attachShader(p, vs); gl.attachShader(p, fs); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) { console.error("GL link:", gl.getProgramInfoLog(p)); return null; }
    const L = (n) => gl.getUniformLocation(p, n);
    const locs = { uEffect: L("uEffect"), uTime: L("uTime"), uRes: L("uRes"), uP0: L("uP0"), uP1: L("uP1"),
      uP2: L("uP2"), uColA: L("uColA"), uColB: L("uColB"), uGlyph: L("uGlyph"), uGlyphCount: L("uGlyphCount") };
    const glyphTex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, glyphTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, buildGlyphCanvas());
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const out = { program: p, locs, glyphTex }; PROG.set(gl, out); return out;
  }

  /* --------- a GL-backed view bound to one <canvas>, app.js-compatible -------- */
  let scheduled = false; const views = new Set();
  function tickAll(now) {
    scheduled = false;
    views.forEach((v) => v._draw(now));
    if ([...views].some((v) => !v.paused && v.visible)) schedule();
  }
  function schedule() { if (!scheduled) { scheduled = true; requestAnimationFrame(tickAll); } }

  class GLView {
    constructor(canvas, opts) {
      this.canvas = canvas; this.paused = false; this.visible = true;
      this.gl = canvas.getContext("webgl2", { antialias: true, premultipliedAlpha: false });
      this.role = canvas.dataset.role || "tile";
      this.fx = FX[opts.effect] || FX.halftone; this.params = opts.params || {};
      this.t0 = performance.now();
      const prog = getProgram(this.gl); this.prog = prog;
      this._sizeFromCSS();
      new ResizeObserver(() => this._sizeFromCSS()).observe(canvas);
      new IntersectionObserver((es) => es.forEach((e) => { this.visible = e.isIntersecting; if (this.visible) schedule(); }),
        { rootMargin: "120px" }).observe(canvas);
      views.add(this); schedule();
    }
    _sizeFromCSS() {
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      const w = Math.max(1, Math.round(this.canvas.clientWidth * dpr));
      const h = Math.max(1, Math.round(this.canvas.clientHeight * dpr));
      if (this.canvas.width !== w) this.canvas.width = w; if (this.canvas.height !== h) this.canvas.height = h;
    }
    setEffect(name) { if (FX[name]) this.fx = FX[name]; schedule(); }
    setParams(p) { this.params = p || {}; schedule(); }
    setSource() {}
    _draw(now) {
      if (!this.prog || this.paused || !this.visible) return;
      const gl = this.gl, L = this.prog.locs;
      gl.viewport(0, 0, this.canvas.width, this.canvas.height);
      gl.useProgram(this.prog.program);
      const packed = this.fx.pack ? this.fx.pack(this.params) : {};
      const p0 = packed.p0 || [0,0,0,0], p1 = packed.p1 || [0,0,0,0], p2 = packed.p2 || [0,0,0,0];
      const a = this.fx.a || [0,0,0], b = this.fx.b || [1,1,1];
      gl.uniform1i(L.uEffect, this.fx.id);
      gl.uniform1f(L.uTime, (now - this.t0) / 1000);
      gl.uniform2f(L.uRes, this.canvas.width, this.canvas.height);
      gl.uniform4f(L.uP0, p0[0], p0[1], p0[2], p0[3]);
      gl.uniform4f(L.uP1, p1[0], p1[1], p1[2], p1[3]);
      gl.uniform4f(L.uP2, p2[0], p2[1], p2[2], p2[3]);
      gl.uniform3f(L.uColA, a[0], a[1], a[2]);
      gl.uniform3f(L.uColB, b[0], b[1], b[2]);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, this.prog.glyphTex);
      gl.uniform1i(L.uGlyph, 0); gl.uniform1i(L.uGlyphCount, glyphCount);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
  }

  // Effect order/labels (superset; app.js only references a subset)
  const ORDER = ["ascii","halftone","dither","matrix","dots","thermal","neon","voronoi","hex","gameboy","scanlines","vhs","nes","starfield","universe","blackhole"];
  const LABEL = { ascii:"ASCII", halftone:"Halftone", dither:"Dithering", matrix:"Matrix Rain", dots:"Dots",
    thermal:"Thermal", neon:"Neon Edges", voronoi:"Voronoi", hex:"Hex Mosaic", gameboy:"Game Boy",
    scanlines:"Phosphor", vhs:"VHS", nes:"NES 8-Bit", starfield:"Starfield", universe:"Universe", blackhole:"Black Hole" };

  // Probe-compile the über-shader once. If it fails to build, leave engine.js's
  // 2D canvas engine in place rather than overriding it with a broken renderer.
  if (!getProgram(testGL)) { console.warn("DotEngine: WebGL2 shader failed to build; using canvas fallback."); return; }

  window.DotEngine = {
    reduce,
    EFFECT_ORDER: ORDER,
    EFFECT_LABEL: LABEL,
    backend: "webgl2",
    register(el, opts) { return new GLView(el, opts || {}); },
  };
})();
