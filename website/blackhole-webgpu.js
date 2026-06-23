// blackhole-webgpu.js — the REAL black-hole shader (the original WebGPU / three.tsl
// code) running on the site. Mounts onto a given <canvas>, full-res, 60fps. If WebGPU
// is unavailable the page keeps the 2D-canvas fallback in engine.js.
import * as THREE from 'three/webgpu';
import {
  pass, uniform, Fn, Loop, Break, If, screenUV,
  vec2, vec3, vec4, float,
  length, normalize, cross, dot, sin, cos, atan, asin, sqrt, pow,
  fract, clamp, smoothstep, mix, floor, step, sign
} from 'three/tsl';
import { bloom } from 'three/addons/tsl/display/BloomNode.js';

const config = {
  blackHoleMass: 0.4, diskInnerRadius: 4.1, diskOuterRadius: 14.5,
  diskTemperature: 49.78, temperatureFalloff: 5.22, diskBrightness: 5,
  diskRotationSpeed: -8.7, turbulenceScale: 1.81, turbulenceStretch: 0.75,
  turbulenceSharpness: 7.4, turbulenceCycleTime: 5, turbulenceLacunarity: 2.5,
  turbulencePersistence: 0.8, diskEdgeSoftnessInner: 0.18, diskEdgeSoftnessOuter: 0.5,
  gravitationalLensing: 2.4, dopplerStrength: 1.0, stepSize: 1,
  starsEnabled: true, starBackgroundColor: '#000000', starDensity: 0.1,
  starSize: 1.2, starBrightness: 0.1,
  nebulaEnabled: true, nebula1Scale: 2, nebula1Density: 0.5, nebula1Brightness: 0.01,
  nebula1Color: '#071f44', nebula2Scale: 5.5, nebula2Density: 0.05,
  nebula2Brightness: 0.21, nebula2Color: '#010615',
  bloomStrength: 0.68, bloomRadius: 0, bloomThreshold: 0.45
};

const uniforms = {
  blackHoleMass: uniform(config.blackHoleMass),
  diskInnerRadius: uniform(config.diskInnerRadius),
  diskOuterRadius: uniform(config.diskOuterRadius),
  diskTemperature: uniform(config.diskTemperature),
  temperatureFalloff: uniform(config.temperatureFalloff),
  diskBrightness: uniform(config.diskBrightness),
  diskRotationSpeed: uniform(config.diskRotationSpeed),
  turbulenceScale: uniform(config.turbulenceScale),
  turbulenceStretch: uniform(config.turbulenceStretch),
  turbulenceSharpness: uniform(config.turbulenceSharpness),
  turbulenceCycleTime: uniform(config.turbulenceCycleTime),
  turbulenceLacunarity: uniform(config.turbulenceLacunarity),
  turbulencePersistence: uniform(config.turbulencePersistence),
  diskEdgeSoftnessInner: uniform(config.diskEdgeSoftnessInner),
  diskEdgeSoftnessOuter: uniform(config.diskEdgeSoftnessOuter),
  gravitationalLensing: uniform(config.gravitationalLensing),
  dopplerStrength: uniform(config.dopplerStrength),
  stepSize: uniform(config.stepSize),
  starsEnabled: uniform(config.starsEnabled ? 1.0 : 0.0),
  starBackgroundColor: uniform(new THREE.Color(config.starBackgroundColor)),
  starDensity: uniform(config.starDensity),
  starSize: uniform(config.starSize),
  starBrightness: uniform(config.starBrightness),
  nebulaEnabled: uniform(config.nebulaEnabled ? 1.0 : 0.0),
  nebula1Scale: uniform(config.nebula1Scale),
  nebula1Density: uniform(config.nebula1Density),
  nebula1Brightness: uniform(config.nebula1Brightness),
  nebula1Color: uniform(new THREE.Color(config.nebula1Color)),
  nebula2Scale: uniform(config.nebula2Scale),
  nebula2Density: uniform(config.nebula2Density),
  nebula2Brightness: uniform(config.nebula2Brightness),
  nebula2Color: uniform(new THREE.Color(config.nebula2Color)),
  time: uniform(0),
  resolution: uniform(new THREE.Vector2(1, 1)),
  cameraPosition: uniform(new THREE.Vector3(0, -2, -18)),
  cameraTarget: uniform(new THREE.Vector3(0, 0, 0))
};

/* ---- shader utilities (verbatim) ---- */
const hash21 = Fn(([p]) => fract(sin(dot(p, vec2(127.1, 311.7))).mul(43758.5453)));
const hash31 = Fn(([p]) => fract(sin(dot(p, vec3(127.1, 311.7, 74.7))).mul(43758.5453)));
const hash22 = Fn(([p]) => vec2(
  fract(sin(dot(p, vec2(127.1, 311.7))).mul(43758.5453)),
  fract(sin(dot(p, vec2(269.5, 183.3))).mul(43758.5453))
));
const noise3D = Fn(([p]) => {
  const i = floor(p), f = fract(p);
  const u = f.mul(f).mul(float(3.0).sub(f.mul(2.0)));
  const a = hash31(i), b = hash31(i.add(vec3(1, 0, 0))), c = hash31(i.add(vec3(0, 1, 0))), d = hash31(i.add(vec3(1, 1, 0)));
  const e = hash31(i.add(vec3(0, 0, 1))), f2 = hash31(i.add(vec3(1, 0, 1))), g = hash31(i.add(vec3(0, 1, 1))), h = hash31(i.add(vec3(1, 1, 1)));
  return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y), mix(mix(e, f2, u.x), mix(g, h, u.x), u.y), u.z);
});
const fbm = Fn(([p, lacunarity, persistence]) => {
  const value = float(0.0).toVar(), amplitude = float(0.5).toVar(), pos = p.toVar();
  value.addAssign(noise3D(pos).mul(amplitude)); pos.mulAssign(lacunarity); amplitude.mulAssign(persistence);
  value.addAssign(noise3D(pos).mul(amplitude)); pos.mulAssign(lacunarity); amplitude.mulAssign(persistence);
  value.addAssign(noise3D(pos).mul(amplitude)); pos.mulAssign(lacunarity); amplitude.mulAssign(persistence);
  value.addAssign(noise3D(pos).mul(amplitude));
  return value;
});
const blackbodyColor = Fn(([tempK]) => {
  const t = clamp(tempK.sub(1000.0).div(9000.0), float(0.0), float(1.0));
  const red = clamp(float(1.0).sub(t.sub(0.8).mul(2.0)), float(0.5), float(1.0));
  const green = smoothstep(float(0.0), float(0.5), t).mul(float(1.0).sub(t.sub(0.7).mul(0.3).max(0.0)));
  const blue = smoothstep(float(0.3), float(1.0), t).mul(t);
  return vec3(red, green, blue);
});
const starField = Fn(([rayDir]) => {
  const theta = atan(rayDir.z, rayDir.x), phi = asin(clamp(rayDir.y, float(-1.0), float(1.0)));
  const gridScale = float(60.0).div(uniforms.starSize);
  const scaledCoord = vec2(theta, phi).mul(gridScale);
  const cell = floor(scaledCoord), cellUV = fract(scaledCoord), cellHash = hash21(cell);
  const starProb = step(float(1.0).sub(uniforms.starDensity), cellHash);
  const starPos = hash22(cell.add(42.0)).mul(0.8).add(0.1);
  const distToStar = length(cellUV.sub(starPos));
  const baseSizeVar = hash21(cell.add(100.0)).mul(0.03).add(0.01);
  const finalStarSize = baseSizeVar.mul(uniforms.starSize);
  const starCore = smoothstep(finalStarSize, float(0.0), distToStar);
  const starGlow = smoothstep(finalStarSize.mul(3.0), float(0.0), distToStar).mul(0.3);
  const starIntensity = starCore.add(starGlow).mul(starProb);
  const colorTemp = hash21(cell.add(200.0));
  const starColor = mix(vec3(0.8, 0.9, 1.0), vec3(1.0, 0.95, 0.8), colorTemp);
  return starColor.mul(starIntensity).mul(uniforms.starBrightness);
});
const nebulaField = Fn(([rayDir]) => {
  const n1 = fbm(rayDir.mul(uniforms.nebula1Scale), float(2.0), float(0.5)).mul(2.0).sub(1.0);
  const layer1 = clamp(n1.add(uniforms.nebula1Density), float(0.0), float(1.0));
  const color1 = uniforms.nebula1Color.mul(layer1).mul(uniforms.nebula1Brightness);
  const n2 = fbm(rayDir.mul(uniforms.nebula2Scale), float(2.0), float(0.5)).mul(2.0).sub(1.0);
  const layer2 = clamp(n2.add(uniforms.nebula2Density), float(0.0), float(1.0));
  const color2 = uniforms.nebula2Color.mul(layer2).mul(uniforms.nebula2Brightness);
  return color1.add(color2);
});
const accretionDiskColor = Fn(([hitR, hitAngle, time, rayDir]) => {
  const innerR = uniforms.diskInnerRadius, outerR = uniforms.diskOuterRadius;
  const normR = clamp(hitR.sub(innerR).div(outerR.sub(innerR)), float(0.0), float(1.0));
  const peakTempK = uniforms.diskTemperature.mul(1000.0), outerTempK = float(1500.0);
  const tempFalloff = pow(innerR.div(hitR), uniforms.temperatureFalloff);
  const tempK = mix(outerTempK, peakTempK, tempFalloff);
  const diskColor = blackbodyColor(tempK).toVar('diskColor');
  const rotationSign = sign(uniforms.diskRotationSpeed);
  const velocityDir = vec3(sin(hitAngle).negate().mul(rotationSign), float(0.0), cos(hitAngle).mul(rotationSign));
  const velocityMagnitude = float(1.0).div(sqrt(hitR.div(innerR)));
  const beta = velocityMagnitude.mul(0.3);
  const cosTheta = dot(velocityDir, rayDir);
  const dopplerFactor = float(1.0).div(float(1.0).sub(beta.mul(cosTheta)));
  const dopplerBoost = pow(dopplerFactor, float(3.0).mul(uniforms.dopplerStrength));
  diskColor.mulAssign(clamp(dopplerBoost, float(0.1), float(5.0)));
  const edgeFalloff = smoothstep(float(0.0), uniforms.diskEdgeSoftnessInner, normR)
    .mul(smoothstep(float(1.0), float(1.0).sub(uniforms.diskEdgeSoftnessOuter), normR));
  const ringOpacity = float(1.0).toVar('ringOpacity');
  const cycleLength = uniforms.turbulenceCycleTime;
  const cyclicTime = time.mod(cycleLength);
  const blendFactor = cyclicTime.div(cycleLength);
  const keplerianPhase1 = cyclicTime.mul(uniforms.diskRotationSpeed).div(pow(hitR, float(1.5)));
  const keplerianPhase2 = cyclicTime.add(cycleLength).mul(uniforms.diskRotationSpeed).div(pow(hitR, float(1.5)));
  const rotatedAngle1 = hitAngle.add(keplerianPhase1), rotatedAngle2 = hitAngle.add(keplerianPhase2);
  const noiseCoord1 = vec3(hitR.mul(uniforms.turbulenceScale), cos(rotatedAngle1).div(uniforms.turbulenceStretch.max(0.1)), sin(rotatedAngle1).div(uniforms.turbulenceStretch.max(0.1)));
  const noiseCoord2 = vec3(hitR.mul(uniforms.turbulenceScale), cos(rotatedAngle2).div(uniforms.turbulenceStretch.max(0.1)), sin(rotatedAngle2).div(uniforms.turbulenceStretch.max(0.1)));
  const turbulence1 = fbm(noiseCoord1, uniforms.turbulenceLacunarity, uniforms.turbulencePersistence);
  const turbulence2 = fbm(noiseCoord2, uniforms.turbulenceLacunarity, uniforms.turbulencePersistence);
  const turbulence = mix(turbulence2, turbulence1, blendFactor);
  ringOpacity.assign(pow(clamp(turbulence, float(0.0), float(1.0)), uniforms.turbulenceSharpness));
  return vec4(diskColor.mul(uniforms.diskBrightness), ringOpacity.mul(edgeFalloff));
});

const blackHoleShader = Fn(() => {
  const rs = uniforms.blackHoleMass.mul(2.0);
  const uv = screenUV.sub(0.5).mul(2.0);
  const aspect = uniforms.resolution.x.div(uniforms.resolution.y);
  const screenPos = vec2(uv.x.mul(aspect), uv.y);
  const camPos = uniforms.cameraPosition, camTarget = uniforms.cameraTarget;
  const camForward = normalize(camTarget.sub(camPos));
  const camRight = normalize(cross(vec3(0.0, 1.0, 0.0), camForward));
  const camUp = cross(camForward, camRight);
  const rayDir = normalize(camForward.mul(float(1.0)).add(camRight.mul(screenPos.x)).add(camUp.mul(screenPos.y))).toVar('rayDir');
  const rayPos = camPos.toVar('rayPos'), prevPos = camPos.toVar('prevPos');
  const color = vec3(0.0).toVar('color'), alpha = float(0.0).toVar('alpha');
  const escaped = float(0.0).toVar('escaped'), captured = float(0.0).toVar('captured');
  const innerR = uniforms.diskInnerRadius, outerR = uniforms.diskOuterRadius;
  Loop(32, () => {
    If(escaped.greaterThan(0.5).or(captured.greaterThan(0.5)).or(alpha.greaterThan(0.99)), () => { Break(); });
    const r = length(rayPos);
    If(r.lessThan(rs.mul(1.01)), () => { captured.assign(1.0); Break(); });
    If(r.greaterThan(100.0), () => { escaped.assign(1.0); Break(); });
    const toCenter = rayPos.negate().div(r);
    rayDir.addAssign(toCenter.mul(rs.div(r.mul(r)).mul(uniforms.stepSize).mul(uniforms.gravitationalLensing)));
    rayDir.assign(normalize(rayDir));
    prevPos.assign(rayPos);
    rayPos.addAssign(rayDir.mul(uniforms.stepSize));
    If(prevPos.y.mul(rayPos.y).lessThan(0.0).and(alpha.lessThan(0.99)), () => {
      const t = prevPos.y.negate().div(rayPos.y.sub(prevPos.y));
      const hitPos = mix(prevPos, rayPos, t);
      const hitR = sqrt(hitPos.x.mul(hitPos.x).add(hitPos.z.mul(hitPos.z)));
      If(hitR.greaterThan(innerR).and(hitR.lessThan(outerR)), () => {
        const diskResult = accretionDiskColor(hitR, atan(hitPos.z, hitPos.x), uniforms.time, rayDir);
        const remainingAlpha = float(1.0).sub(alpha);
        color.addAssign(diskResult.xyz.mul(diskResult.w).mul(remainingAlpha));
        alpha.addAssign(remainingAlpha.mul(diskResult.w));
      });
    });
  });
  If(captured.lessThan(0.5), () => { escaped.assign(1.0); });
  If(escaped.greaterThan(0.5).and(alpha.lessThan(0.99)), () => {
    const bgColor = uniforms.starBackgroundColor.toVar('bgColor');
    If(uniforms.starsEnabled.greaterThan(0.5), () => { bgColor.addAssign(starField(rayDir)); });
    If(uniforms.nebulaEnabled.greaterThan(0.5), () => { bgColor.addAssign(nebulaField(rayDir)); });
    color.addAssign(bgColor.mul(float(1.0).sub(alpha)));
  });
  return vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
})();

let mounted = null;

async function mount(canvas) {
  if (mounted) return mounted;
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);
  const camera = new THREE.PerspectiveCamera(60, 1, 0.1, 1000);
  camera.position.set(0, -2, -18); camera.lookAt(0, 0, 0);

  const renderer = new THREE.WebGPURenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;

  const geometry = new THREE.SphereGeometry(100, 32, 32); geometry.scale(-1, 1, 1);
  const material = new THREE.MeshBasicNodeMaterial(); material.colorNode = blackHoleShader;
  const mesh = new THREE.Mesh(geometry, material); mesh.frustumCulled = false; scene.add(mesh);

  const sizeTo = () => {
    const w = Math.max(1, canvas.clientWidth), h = Math.max(1, canvas.clientHeight);
    renderer.setSize(w, h, false);
    uniforms.resolution.value.set(w, h);
    camera.aspect = w / h; camera.updateProjectionMatrix();
  };
  sizeTo();
  new ResizeObserver(sizeTo).observe(canvas);

  await renderer.init();
  const postProcessing = new THREE.PostProcessing(renderer);
  const scenePassColor = pass(scene, camera).getTextureNode();
  const bloomPass = bloom(scenePassColor);
  bloomPass.threshold.value = config.bloomThreshold;
  bloomPass.strength.value = config.bloomStrength;
  bloomPass.radius.value = config.bloomRadius;
  postProcessing.outputNode = scenePassColor.add(bloomPass);

  let active = false, raf = 0, last = performance.now();
  const D = 20, el = 0.2;                       // gentle elevation; slow azimuth orbit
  const frame = () => {
    raf = requestAnimationFrame(frame);
    const now = performance.now();
    const dt = Math.min((now - last) / 1000, 0.033); last = now;
    uniforms.time.value += dt;
    const az = uniforms.time.value * 0.08;
    uniforms.cameraPosition.value.set(Math.sin(az) * D * Math.cos(el), -Math.sin(el) * D, -Math.cos(az) * D * Math.cos(el));
    uniforms.cameraTarget.value.set(0, 0, 0);
    postProcessing.render();
  };
  mounted = {
    setActive(on) {
      if (on && !raf) { last = performance.now(); raf = requestAnimationFrame(frame); }
      else if (!on && raf) { cancelAnimationFrame(raf); raf = 0; }
      active = on;
    }
  };
  return mounted;
}

// Only claim support when a real GPU adapter exists — otherwise three's
// WebGPURenderer silently falls back to a WebGL2 path that can't compile this
// shader. When unsupported, the 2D canvas in engine.js renders the fallback.
window.DotBH = { supported: false, mount };
if (typeof navigator !== 'undefined' && navigator.gpu && navigator.gpu.requestAdapter) {
  navigator.gpu.requestAdapter().then((a) => { window.DotBH.supported = !!a; }).catch(() => {});
}
