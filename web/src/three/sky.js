import * as THREE from 'three'

// Mars sky: butterscotch by day (suspended dust), a blue glow around the Sun that
// dominates at sunset (dust forward-scatters blue light), dark with stars at night.
export function makeSky(radius) {
  const uniforms = {
    sunDir: { value: new THREE.Vector3(0, 1, 0) },
    tau: { value: 0.5 },
    time: { value: 0 },
  }
  const mat = new THREE.ShaderMaterial({
    uniforms,
    side: THREE.BackSide,
    depthWrite: false,
    fog: false,
    vertexShader: /* glsl */ `
      varying vec3 vDir;
      void main() {
        vDir = normalize(position);
        vec4 p = modelViewMatrix * vec4(position, 1.0);
        gl_Position = projectionMatrix * p;
        gl_Position.z = gl_Position.w; // keep the sky at the far plane
      }`,
    fragmentShader: /* glsl */ `
      uniform vec3 sunDir;
      uniform float tau;
      varying vec3 vDir;
      float hash(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
      void main() {
        vec3 d = normalize(vDir);
        float h = clamp(d.y, -0.2, 1.0);
        float mu = dot(d, normalize(sunDir));
        float se = sunDir.y;
        float day = smoothstep(-0.10, 0.22, se);
        float twi = smoothstep(-0.30, 0.02, se) * (1.0 - smoothstep(0.02, 0.32, se));
        vec3 zenith = vec3(0.36, 0.25, 0.18);
        vec3 horizon = vec3(0.80, 0.62, 0.45);
        vec3 col = mix(horizon, zenith, pow(max(h, 0.0), 0.42));
        float dust = clamp(tau / 0.6, 0.4, 2.0);
        col = mix(col, horizon * 0.95, 0.15 * (dust - 1.0));
        // blue forward-scattering halo around the Sun
        float halo = pow(max(mu, 0.0), 10.0);
        float core = pow(max(mu, 0.0), 80.0);
        vec3 blue = vec3(0.42, 0.60, 0.88);
        col = mix(col, blue, clamp(halo * (0.25 + 0.75 * twi) + core * 0.5, 0.0, 1.0));
        // twilight: the sky away from the Sun goes dark first
        col *= mix(1.0, 0.18 + 0.82 * pow(max(mu * 0.5 + 0.5, 0.0), 3.0), twi);
        vec3 night = vec3(0.010, 0.011, 0.018);
        col = mix(night, col, max(day, twi * 0.55));
        // sun disc (~0.35 deg wide seen from Mars) and glare
        float disc = smoothstep(0.999986, 0.999995, mu);
        float vis = smoothstep(-0.03, 0.01, se);
        col += vec3(1.0, 0.97, 0.92) * disc * 6.0 * vis;
        col += vec3(1.0, 0.9, 0.78) * pow(max(mu, 0.0), 900.0) * 2.0 * vis;
        // stars
        float starAmt = 1.0 - smoothstep(-0.18, -0.02, se);
        if (starAmt > 0.0 && d.y > 0.0) {
          vec3 cell = floor(d * 380.0);
          float r = hash(cell);
          float s = step(0.9975, r) * (0.5 + 0.5 * hash(cell + 7.0));
          col += vec3(s) * starAmt * smoothstep(0.0, 0.15, d.y);
        }
        // below the horizon: dusty ground haze
        col = mix(col, horizon * 0.55 * max(day, 0.05), smoothstep(0.0, -0.08, d.y));
        gl_FragColor = vec4(col, 1.0);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
      }`,
  })
  const mesh = new THREE.Mesh(new THREE.SphereGeometry(radius, 48, 24), mat)
  mesh.frustumCulled = false
  mesh.renderOrder = -1
  return { mesh, uniforms }
}

// Approximate sky colour toward the horizon (used for fog and ambient light).
export function horizonColor(sunElevDeg, tau = 0.5) {
  const se = Math.sin((sunElevDeg * Math.PI) / 180)
  const day = THREE.MathUtils.smoothstep(se, -0.1, 0.22)
  const twi = THREE.MathUtils.smoothstep(se, -0.3, 0.02) * (1 - THREE.MathUtils.smoothstep(se, 0.02, 0.32))
  const c = new THREE.Color(0.8, 0.62, 0.45).multiplyScalar(Math.max(0.03, Math.max(day, twi * 0.5)))
  if (tau > 0.8) c.lerp(new THREE.Color(0.7, 0.52, 0.38), 0.3)
  return c
}
