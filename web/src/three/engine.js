import * as THREE from 'three'
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js'
import { Line2 } from 'three/examples/jsm/lines/Line2.js'
import { LineGeometry } from 'three/examples/jsm/lines/LineGeometry.js'
import { LineMaterial } from 'three/examples/jsm/lines/LineMaterial.js'
import { api } from '../api.js'
import { makeGrid, sampleBilinear, interp } from '../lib/geo.js'
import { marsTime, sunPosition } from '../lib/mars24.js'
import { horizonColor, makeSky } from './sky.js'
import * as M from './models.js'

const QUALITY = {
  low: { mesh: 257, tex: 2048, normal: 2048, regional: 129, shadow: 1024, pixelRatio: 1 },
  medium: { mesh: 513, tex: 2048, normal: 2048, regional: 257, shadow: 2048, pixelRatio: 1.25 },
  high: { mesh: 1025, tex: 4096, normal: 4096, regional: 257, shadow: 2048, pixelRatio: 1.5 },
}
const EYE = 1.65 // suited eye height (m)
const MARS_G = 3.721

function loadTexture(url, srgb = true) {
  return new Promise((resolve, reject) => {
    new THREE.TextureLoader().load(url, (t) => {
      if (srgb) t.colorSpace = THREE.SRGBColorSpace
      resolve(t)
    }, undefined, reject)
  })
}

function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = url
  })
}

export class MarsScene {
  constructor(container, { onProgress, onWalk } = {}) {
    this.container = container
    this.onProgress = onProgress || (() => {})
    this.onWalk = onWalk || (() => {})
    this.labels = []
    this.disposed = false
    this.mode = 'orbit'
    this.walk = { x: 0, y: 0, z: 0, yaw: 0, pitch: -0.05, vy: 0, auto: true, t: 0, speed: 20, playing: false, bob: 0, keys: {}, lastEmit: 0, grounded: true }
    this.tmp = new THREE.Vector3()

    const r = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance', logarithmicDepthBuffer: true })
    r.toneMapping = THREE.ACESFilmicToneMapping
    r.toneMappingExposure = 1.05
    r.shadowMap.enabled = true
    r.shadowMap.type = THREE.PCFSoftShadowMap
    r.setSize(container.clientWidth, container.clientHeight)
    container.appendChild(r.domElement)
    r.domElement.style.display = 'block'
    this.renderer = r

    this.scene = new THREE.Scene()
    this.camera = new THREE.PerspectiveCamera(55, container.clientWidth / container.clientHeight, 0.2, 400000)
    this.scene.fog = new THREE.FogExp2(0xc89e72, 0.000022)

    this.sky = makeSky(300000)
    this.scene.add(this.sky.mesh)
    this.sun = new THREE.DirectionalLight(0xfff1e0, 3)
    this.sun.castShadow = true
    this.sun.shadow.bias = -0.0004
    this.sun.shadow.normalBias = 0.8
    this.scene.add(this.sun, this.sun.target)
    this.hemi = new THREE.HemisphereLight(0xd8a57a, 0x4a2a18, 0.8)
    this.scene.add(this.hemi)

    this.controls = new OrbitControls(this.camera, r.domElement)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.08
    this.controls.maxPolarAngle = Math.PI * 0.495
    this.controls.minDistance = 8
    this.controls.maxDistance = 70000

    this.labelLayer = document.createElement('div')
    Object.assign(this.labelLayer.style, { position: 'absolute', inset: '0', pointerEvents: 'none', overflow: 'hidden' })
    container.appendChild(this.labelLayer)

    this.routeGroup = new THREE.Group()
    this.markerGroup = new THREE.Group()
    this.crumbs = new THREE.Group()
    this.crew = new THREE.Group()
    this.scene.add(this.routeGroup, this.markerGroup, this.crumbs, this.crew)

    this.clock = new THREE.Clock()
    this._resize = () => this.resize()
    window.addEventListener('resize', this._resize)
    this.ro = new ResizeObserver(this._resize)
    this.ro.observe(container)
    this._bindInput()
    this.renderer.setAnimationLoop(() => this.frame())
  }

  // ------------------------------------------------------------------ loading
  async load(site, quality = 'medium') {
    this.site = site
    this.q = QUALITY[quality] || QUALITY.medium
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, this.q.pixelRatio))
    this.grid = makeGrid(site.grid)
    const g = site.grid
    this.W = g.width * g.res
    this.H = g.height * g.res
    this.cx = g.x_min + this.W / 2
    this.cy = g.y_max - this.H / 2
    this.yRef = site.elev_min

    this.onProgress('Downloading terrain…')
    const N = this.q.mesh
    const [heights, tex, nrm] = await Promise.all([
      api.terrain(site.id, N),
      loadTexture(api.file(site.id, `texture_${this.q.tex}.jpg`)),
      loadTexture(api.file(site.id, `normal_${this.q.normal}.jpg`), false),
    ])
    if (this.disposed) return
    this.N = N
    this.heights = heights
    this.baseTexImage = tex.image
    const maxAniso = this.renderer.capabilities.getMaxAnisotropy()
    tex.anisotropy = maxAniso
    nrm.anisotropy = maxAniso

    this.onProgress('Building the surface…')
    const geo = new THREE.PlaneGeometry(this.W, this.H, N - 1, N - 1)
    geo.rotateX(-Math.PI / 2)
    const pos = geo.attributes.position
    const nor = geo.attributes.normal
    for (let i = 0; i < pos.count; i++) {
      pos.setY(i, heights[i] - this.yRef)
      nor.setXYZ(i, 0, 1, 0) // lighting detail comes from the 1 m normal map
    }
    geo.computeBoundingSphere()
    this.terrainMat = new THREE.MeshStandardMaterial({ map: tex, normalMap: nrm, normalScale: new THREE.Vector2(1, 1), roughness: 0.96, metalness: 0 })
    this.terrain = new THREE.Mesh(geo, this.terrainMat)
    this.terrain.position.set(this.cx, 0, -this.cy)
    this.terrain.receiveShadow = true
    this.terrain.castShadow = true
    this.scene.add(this.terrain)
    this._addSkirt()

    if (site.regional_grid) {
      this.onProgress('Adding Mount Sharp and the crater…')
      try { await this._loadRegional(site) } catch (e) { console.warn('regional terrain', e) }
    }
    this._shadowFrustum(Math.max(this.W, this.H) * 0.6, this.cx, -this.cy)
    this.home()
    this.onProgress(null)
  }

  async _loadRegional(site) {
    const rg = site.regional_grid
    const n = this.q.regional
    const [h, tex] = await Promise.all([api.regionalTerrain(site.id, n), loadTexture(api.file(site.id, 'regional_texture.jpg'))])
    if (this.disposed) return
    const W = rg.width * rg.res
    const H = rg.height * rg.res
    const geo = new THREE.PlaneGeometry(W, H, n - 1, n - 1)
    geo.rotateX(-Math.PI / 2)
    const pos = geo.attributes.position
    const off = (site.regional_offset_m ?? 0) - this.yRef
    const rcx = rg.x_min + W / 2
    const rcy = rg.y_max - H / 2
    const margin = 120
    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i) + rcx
      const y = -pos.getZ(i) + rcy
      let z = h[i] + off
      const inside = x > this.grid.x_min - margin && x < this.grid.x_min + this.W + margin && y < this.grid.y_max + margin && y > this.grid.y_max - this.H - margin
      if (inside) z -= 60 // tuck under the detailed site mesh
      pos.setY(i, z)
    }
    geo.computeVertexNormals()
    const mat = new THREE.MeshStandardMaterial({ map: tex, roughness: 1, metalness: 0 })
    this.regional = new THREE.Mesh(geo, mat)
    this.regional.position.set(rcx, 0, -rcy)
    this.regional.receiveShadow = false
    this.scene.add(this.regional)
  }

  _addSkirt() {
    // vertical curtain around the site edge hides the seam with the coarse regional mesh
    const N = this.N
    const pts = []
    const edge = (i, j) => {
      const x = this.grid.x_min + (j / (N - 1)) * this.W
      const y = this.grid.y_max - (i / (N - 1)) * this.H
      return [x, this.heights[i * N + j] - this.yRef, -y]
    }
    for (let j = 0; j < N; j++) pts.push(edge(0, j))
    for (let i = 1; i < N; i++) pts.push(edge(i, N - 1))
    for (let j = N - 2; j >= 0; j--) pts.push(edge(N - 1, j))
    for (let i = N - 2; i >= 0; i--) pts.push(edge(i, 0))
    const verts = []
    for (let k = 0; k < pts.length - 1; k++) {
      const [x0, y0, z0] = pts[k]
      const [x1, y1, z1] = pts[k + 1]
      verts.push(x0, y0, z0, x1, y1, z1, x0, y0 - 90, z0, x1, y1, z1, x1, y1 - 90, z1, x0, y0 - 90, z0)
    }
    const geo = new THREE.BufferGeometry()
    geo.setAttribute('position', new THREE.Float32BufferAttribute(verts, 3))
    geo.computeVertexNormals()
    this.scene.add(new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: 0x8a5a3c, roughness: 1, side: THREE.DoubleSide })))
  }

  // ------------------------------------------------------------------ geometry helpers
  heightAt(x, y) {
    // x east, y north (site metres) -> terrain height relative to yRef
    if (!this.heights) return 0
    const N = this.N
    const c = ((x - this.grid.x_min) / this.W) * (N - 1)
    const r = ((this.grid.y_max - y) / this.H) * (N - 1)
    const v = sampleBilinear(this.heights, N, N, r, c)
    return Number.isFinite(v) ? v - this.yRef : 0
  }

  local(lon, lat, lift = 0) {
    const [x, y] = this.grid.toXY(lon, lat)
    return new THREE.Vector3(x, this.heightAt(x, y) + lift, -y)
  }

  // ------------------------------------------------------------------ scene content
  setMarkers({ habitat, stops, shelters = [], relays = [], rover }) {
    if (!this.grid) return
    this.markerGroup.clear()
    this.labels.forEach((l) => l.el.remove())
    this.labels = []
    const hab = M.habitat()
    hab.position.copy(this.local(habitat.lon, habitat.lat, -0.3))
    this.markerGroup.add(hab)
    this._label(habitat.name || 'Habitat', this.local(habitat.lon, habitat.lat, 22), 'hab')
    this.habPos = hab.position.clone()
    stops.forEach((s, i) => {
      const p = this.local(s.lon, s.lat)
      const b = M.beacon(0xff7a3d, 45)
      b.position.copy(p)
      this.markerGroup.add(b)
      this._label(`${i + 1} · ${s.name}`, p.clone().add(new THREE.Vector3(0, 48, 0)), 'stop')
    })
    for (const sh of shelters) {
      const pr = M.pressurizedRover()
      pr.position.copy(this.local(sh.lon, sh.lat))
      pr.rotation.y = 0.6
      this.markerGroup.add(pr)
      this._label(sh.name, this.local(sh.lon, sh.lat, 8), '')
    }
    for (const r of relays) {
      const m = M.relayMast(r.height_m || 3)
      m.position.copy(this.local(r.lon, r.lat))
      this.markerGroup.add(m)
      this._label(`Relay ${r.id}`, this.local(r.lon, r.lat, (r.height_m || 3) + 4), '')
    }
    if (rover) {
      const c = M.curiosity()
      c.position.copy(this.local(rover.lon, rover.lat))
      c.rotation.y = 2.2
      this.markerGroup.add(c)
      this._label(`${rover.name} · sol ${rover.sol}`, this.local(rover.lon, rover.lat, 6), '')
    }
  }

  _label(text, pos, cls) {
    const el = document.createElement('div')
    el.className = `label3d ${cls}`
    el.textContent = text
    this.labelLayer.appendChild(el)
    this.labels.push({ el, pos })
  }

  setRoute(plan) {
    this.routeGroup.clear()
    this.crumbs.clear()
    this.profile = plan?.profile || null
    if (!plan || !this.grid) return
    const p = plan.profile
    const pts = []
    this.routeXY = []
    for (let i = 0; i < p.lon.length; i++) {
      const v = this.local(p.lon[i], p.lat[i], 1.2)
      pts.push(v.x, v.y, v.z)
      this.routeXY.push([v.x, -v.z])
    }
    const geo = new LineGeometry()
    geo.setPositions(pts)
    this.lineMat = new LineMaterial({ color: 0x4cb0ff, linewidth: 4, transparent: true, opacity: 0.95, depthTest: true })
    this.lineMat.resolution.set(this.container.clientWidth, this.container.clientHeight)
    const line = new Line2(geo, this.lineMat)
    line.computeLineDistances()
    this.routeGroup.add(line)
    // AR breadcrumbs for the first-person view: a glowing chevron every ~12 m
    const chev = new THREE.ShapeGeometry(new THREE.Shape([new THREE.Vector2(0, 0.7), new THREE.Vector2(0.55, -0.4), new THREE.Vector2(0, -0.1), new THREE.Vector2(-0.55, -0.4)]))
    chev.rotateX(-Math.PI / 2)
    const cmat = new THREE.MeshBasicMaterial({ color: 0x4fd1ff, transparent: true, opacity: 0.85, depthWrite: false, side: THREE.DoubleSide })
    let last = -1e9
    for (let i = 1; i < p.d.length; i++) {
      if (p.d[i] - last < 12) continue
      last = p.d[i]
      const a = this.local(p.lon[i - 1], p.lat[i - 1])
      const b = this.local(p.lon[i], p.lat[i], 0.12)
      const m = new THREE.Mesh(chev, cmat)
      m.position.copy(b)
      m.rotation.y = Math.atan2(-(b.x - a.x), -(b.z - a.z))
      this.crumbs.add(m)
    }
    this.crumbs.visible = this.mode === 'walk'
    this.events = plan.events
  }

  setCrewAt(t) {
    // place EV1 + EV2 along the planned route at EVA time t (seconds)
    this.crew.clear()
    if (!this.profile || t == null) return
    const p = this.profile
    const d = interp(p.t, p.d, t)
    for (const [k, off, accent] of [[0, 0, 0xff7a3d], [1, -6, 0x4fd1ff]]) {
      const dd = Math.max(0, d + off)
      const lon = interp(p.d, p.lon, dd)
      const lat = interp(p.d, p.lat, dd)
      const lon2 = interp(p.d, p.lon, dd + 3)
      const lat2 = interp(p.d, p.lat, dd + 3)
      const a = this.local(lon, lat)
      const b = this.local(lon2, lat2)
      const fig = M.astronaut(accent)
      fig.scale.setScalar(1)
      fig.position.copy(a)
      fig.rotation.y = Math.atan2(-(b.x - a.x), -(b.z - a.z)) + Math.PI
      this.crew.add(fig)
      if (k === 0) this.crewPos = a.clone()
    }
  }

  async setDrape(url) {
    if (!this.terrainMat || !this.baseTexImage) return
    if (!url) {
      if (this.drapeTex) { this.drapeTex.dispose(); this.drapeTex = null }
      this.terrainMat.map = this._baseTex || this.terrainMat.map
      this.terrainMat.needsUpdate = true
      return
    }
    this._baseTex = this._baseTex || this.terrainMat.map
    const ov = await loadImage(url)
    const size = this.baseTexImage.width
    const cv = document.createElement('canvas')
    cv.width = cv.height = size
    const ctx = cv.getContext('2d')
    ctx.drawImage(this.baseTexImage, 0, 0, size, size)
    ctx.globalAlpha = 0.85
    ctx.drawImage(ov, 0, 0, size, size)
    const t = new THREE.CanvasTexture(cv)
    t.colorSpace = THREE.SRGBColorSpace
    t.anisotropy = this.renderer.capabilities.getMaxAnisotropy()
    if (this.drapeTex) this.drapeTex.dispose()
    this.drapeTex = t
    this.terrainMat.map = t
    this.terrainMat.needsUpdate = true
  }

  setSun(date, tau = 0.5) {
    if (!this.site) return
    const mt = marsTime(date)
    const { elevation, azimuth } = sunPosition(mt, this.site.center.lat, this.site.center.lon)
    this.sunElev = elevation
    this.sunAz = azimuth
    const el = THREE.MathUtils.degToRad(elevation)
    const az = THREE.MathUtils.degToRad(azimuth)
    const dir = new THREE.Vector3(Math.sin(az) * Math.cos(el), Math.sin(el), -Math.cos(az) * Math.cos(el))
    this.sky.uniforms.sunDir.value.copy(dir)
    this.sky.uniforms.tau.value = tau
    const day = THREE.MathUtils.smoothstep(Math.sin(el), -0.05, 0.25)
    this.sun.intensity = 3.2 * day
    this.sun.color.setRGB(1, 0.93 + 0.05 * day, 0.85 + 0.1 * day)
    this.sunDir = dir
    this.hemi.intensity = 0.15 + 0.9 * day
    const hc = horizonColor(elevation, tau)
    this.hemi.color.copy(hc).multiplyScalar(1.2)
    this.scene.fog.color.copy(hc)
    this.scene.fog.density = 0.000014 * Math.max(0.6, tau / 0.5)
    this._placeSun()
  }

  _placeSun() {
    if (!this.sunDir) return
    const c = this.mode === 'walk' ? new THREE.Vector3(this.walk.x, 0, -this.walk.y) : new THREE.Vector3(this.cx, 0, -this.cy)
    this.sun.position.copy(c).addScaledVector(this.sunDir, 4000)
    this.sun.target.position.copy(c)
    this.sun.target.updateMatrixWorld()
  }

  _shadowFrustum(half) {
    const cam = this.sun.shadow.camera
    cam.left = -half
    cam.right = half
    cam.top = half
    cam.bottom = -half
    cam.near = 10
    cam.far = 9000
    cam.updateProjectionMatrix()
    this.sun.shadow.mapSize.set(this.q?.shadow || 2048, this.q?.shadow || 2048)
    if (this.sun.shadow.map) { this.sun.shadow.map.dispose(); this.sun.shadow.map = null }
  }

  // ------------------------------------------------------------------ cameras
  home() {
    const t = this.habPos || new THREE.Vector3(this.cx, this.heightAt(this.cx, this.cy), -this.cy)
    this.controls.target.copy(t)
    this.camera.position.set(t.x + 900, t.y + 650, t.z + 1100)
    this.controls.update()
  }

  lookToward(azDeg, dist = 1800, height = 380) {
    const t = this.controls.target.clone()
    const a = THREE.MathUtils.degToRad(azDeg)
    this.camera.position.set(t.x - Math.sin(a) * dist, t.y + height, t.z + Math.cos(a) * dist)
    this.controls.update()
  }

  focusOn(target, dist = 260) {
    this.controls.target.copy(target)
    const dir = this.camera.position.clone().sub(target).normalize()
    this.camera.position.copy(target).addScaledVector(dir, dist)
    this.controls.update()
  }

  flyRoute(seconds = 45) {
    if (!this.routeXY?.length) return
    this.fly = { t0: performance.now(), dur: seconds * 1000 }
  }

  setMode(mode) {
    this.mode = mode
    this.controls.enabled = mode === 'orbit'
    this.crumbs.visible = mode === 'walk'
    this.crew.visible = mode !== 'walk'
    this.camera.near = mode === 'walk' ? 0.1 : 0.5
    this.camera.fov = mode === 'walk' ? 70 : 55
    this.camera.updateProjectionMatrix()
    if (mode === 'walk') {
      this._shadowFrustum(220)
      const start = this.habPos ? { x: this.habPos.x, y: -this.habPos.z } : { x: this.cx, y: this.cy }
      Object.assign(this.walk, { x: start.x + 12, y: start.y - 14, vy: 0 })
      this.walk.z = this.heightAt(this.walk.x, this.walk.y)
      if (this.routeXY?.length > 2) {
        const [x1, y1] = this.routeXY[Math.min(6, this.routeXY.length - 1)]
        this.walk.yaw = Math.atan2(x1 - this.walk.x, y1 - this.walk.y)
      }
    } else {
      this._shadowFrustum(Math.max(this.W || 3000, this.H || 3000) * 0.6)
      this.home()
    }
    this._placeSun()
  }

  // ------------------------------------------------------------------ walking
  _bindInput() {
    const k = this.walk.keys
    this._kd = (e) => {
      if (this.mode !== 'walk' || e.target.tagName === 'INPUT') return
      k[e.code] = true
      if (e.code === 'Space' && this.walk.grounded) { this.walk.vy = 1.6; this.walk.grounded = false }
      if (['KeyW', 'KeyA', 'KeyS', 'KeyD', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(e.code)) this.walk.auto = false
      if (e.code === 'KeyP') this.walk.auto = !this.walk.auto
    }
    this._ku = (e) => { k[e.code] = false }
    window.addEventListener('keydown', this._kd)
    window.addEventListener('keyup', this._ku)
    const el = this.renderer.domElement
    let drag = null
    this._pd = (e) => { if (this.mode === 'walk') { drag = { x: e.clientX, y: e.clientY }; el.setPointerCapture(e.pointerId) } }
    this._pm = (e) => {
      if (!drag || this.mode !== 'walk') return
      this.walk.yaw += (e.clientX - drag.x) * 0.0042
      this.walk.pitch = THREE.MathUtils.clamp(this.walk.pitch - (e.clientY - drag.y) * 0.0035, -1.2, 1.0)
      this.walk.lookOverride = performance.now()
      drag = { x: e.clientX, y: e.clientY }
    }
    this._pu = () => { drag = null }
    el.addEventListener('pointerdown', this._pd)
    el.addEventListener('pointermove', this._pm)
    el.addEventListener('pointerup', this._pu)
  }

  _walkStep(dt) {
    const w = this.walk
    const k = w.keys
    if (w.playing) w.t += dt * w.speed
    if (w.auto && this.profile) {
      const p = this.profile
      const t = THREE.MathUtils.clamp(w.t, p.t[0], p.t[p.t.length - 1])
      const d = interp(p.t, p.d, t)
      const lon = interp(p.d, p.lon, d)
      const lat = interp(p.d, p.lat, d)
      const [x, y] = this.grid.toXY(lon, lat)
      const ahead = interp(p.d, p.d, d + 10)
      const [x2, y2] = this.grid.toXY(interp(p.d, p.lon, ahead), interp(p.d, p.lat, ahead))
      const moving = Math.hypot(x - w.x, y - w.y)
      w.speedNow = moving / Math.max(dt, 1e-3)
      w.x = x
      w.y = y
      if (Math.hypot(x2 - x, y2 - y) > 0.5 && performance.now() - (w.lookOverride || 0) > 2500) {
        const target = Math.atan2(x2 - x, y2 - y)
        let dy = target - w.yaw
        dy = Math.atan2(Math.sin(dy), Math.cos(dy))
        w.yaw += dy * Math.min(1, dt * 2.5)
      }
      w.bob += moving * 1.6
    } else {
      const run = k.ShiftLeft || k.ShiftRight ? 2.6 : 1
      const sp = 1.3 * run * Math.max(1, w.speed / 10)
      let f = 0
      let s = 0
      if (k.KeyW || k.ArrowUp) f += 1
      if (k.KeyS || k.ArrowDown) f -= 1
      if (k.KeyA) s -= 1
      if (k.KeyD) s += 1
      if (k.ArrowLeft) w.yaw -= dt * 1.4
      if (k.ArrowRight) w.yaw += dt * 1.4
      const nx = w.x + (Math.sin(w.yaw) * f + Math.cos(w.yaw) * s) * sp * dt
      const ny = w.y + (Math.cos(w.yaw) * f - Math.sin(w.yaw) * s) * sp * dt
      const inside = nx > this.grid.x_min + 2 && nx < this.grid.x_min + this.W - 2 && ny < this.grid.y_max - 2 && ny > this.grid.y_max - this.H + 2
      if (inside) {
        const moved = Math.hypot(nx - w.x, ny - w.y)
        w.x = nx
        w.y = ny
        w.bob += moved * 1.6
        w.speedNow = moved / Math.max(dt, 1e-3)
      } else w.speedNow = 0
    }
    // Mars gravity: slow, floaty jumps
    const ground = this.heightAt(w.x, w.y)
    w.vy -= MARS_G * dt
    w.z += w.vy * dt
    if (w.z <= ground) { w.z = ground; w.vy = 0; w.grounded = true }
    const bob = Math.sin(w.bob) * 0.045
    this.camera.position.set(w.x, w.z + EYE + bob, -w.y)
    const look = new THREE.Vector3(Math.sin(w.yaw) * Math.cos(w.pitch), Math.sin(w.pitch), -Math.cos(w.yaw) * Math.cos(w.pitch))
    this.camera.lookAt(this.camera.position.clone().add(look))
    // keep shadows crisp around the walker
    if (!this._lastShadowMove || Math.hypot(w.x - this._lastShadowMove[0], w.y - this._lastShadowMove[1]) > 30) {
      this._lastShadowMove = [w.x, w.y]
      this._placeSun()
    }
    const now = performance.now()
    if (now - w.lastEmit > 120) {
      w.lastEmit = now
      const ahead = this.heightAt(w.x + Math.sin(w.yaw) * 6, w.y + Math.cos(w.yaw) * 6)
      const slopeAhead = Math.abs(Math.atan2(ahead - ground, 6)) * (180 / Math.PI)
      const [lon, lat] = this.grid.toLonLat(w.x, w.y)
      this.onWalk({
        x: w.x, y: w.y, lon, lat, heading: ((THREE.MathUtils.radToDeg(w.yaw) % 360) + 360) % 360, pitch: w.pitch,
        t: w.t, auto: w.auto, playing: w.playing, speed: w.speed, speedNow: w.speedNow || 0, slopeAhead,
        sunAz: this.sunAz, sunElev: this.sunElev, elev: ground + this.yRef,
      })
    }
  }

  // ------------------------------------------------------------------ frame loop
  frame() {
    if (this.disposed) return
    const dt = Math.min(0.1, this.clock.getDelta())
    const now = performance.now()
    if (this.mode === 'walk' && this.grid) this._walkStep(dt)
    else if (this.fly && this.routeXY?.length > 1) {
      const f = Math.min(1, (now - this.fly.t0) / this.fly.dur)
      const n = this.routeXY.length - 1
      const i = Math.floor(f * n)
      const [x, y] = this.routeXY[Math.min(n, i)]
      const [x2, y2] = this.routeXY[Math.min(n, i + 12)]
      const h = this.heightAt(x, y)
      const dir = new THREE.Vector2(x2 - x, y2 - y).normalize()
      const camPos = new THREE.Vector3(x - dir.x * 70, h + 42, -(y - dir.y * 70))
      this.camera.position.lerp(camPos, 0.08)
      this.controls.target.lerp(new THREE.Vector3(x2, this.heightAt(x2, y2), -y2), 0.1)
      if (f >= 1) this.fly = null
      this.controls.update()
    } else {
      this.controls.update()
    }
    // blink & pulse
    const s = 0.5 + 0.5 * Math.sin(now / 300)
    this.markerGroup.traverse((o) => {
      if (o.userData.blink) o.visible = Math.sin(now / 450) > -0.2
      if (o.userData.pulse) o.material.opacity = 0.45 + 0.4 * s
    })
    this.renderer.render(this.scene, this.camera)
    this._updateLabels()
  }

  _updateLabels() {
    if (!this.labels.length) return
    const w = this.container.clientWidth
    const h = this.container.clientHeight
    const camPos = this.camera.position
    for (const l of this.labels) {
      this.tmp.copy(l.pos).project(this.camera)
      const dist = camPos.distanceTo(l.pos)
      const visible = this.tmp.z < 1 && this.tmp.z > -1 && Math.abs(this.tmp.x) < 1.1 && Math.abs(this.tmp.y) < 1.1 && dist < 9000 && !(this.mode === 'walk' && dist < 25)
      l.el.style.display = visible ? 'block' : 'none'
      if (visible) l.el.style.transform = `translate(${((this.tmp.x + 1) / 2) * w}px, ${((1 - this.tmp.y) / 2) * h}px) translate(-50%, -100%)`
    }
  }

  resize() {
    const w = this.container.clientWidth
    const h = this.container.clientHeight
    if (!w || !h) return
    this.renderer.setSize(w, h)
    this.camera.aspect = w / h
    this.camera.updateProjectionMatrix()
    this.lineMat?.resolution.set(w, h)
  }

  dispose() {
    this.disposed = true
    this.renderer.setAnimationLoop(null)
    window.removeEventListener('resize', this._resize)
    window.removeEventListener('keydown', this._kd)
    window.removeEventListener('keyup', this._ku)
    this.ro.disconnect()
    this.controls.dispose()
    this.scene.traverse((o) => {
      if (o.geometry) o.geometry.dispose()
      if (o.material) (Array.isArray(o.material) ? o.material : [o.material]).forEach((m) => { m.map?.dispose(); m.normalMap?.dispose(); m.dispose() })
    })
    this.renderer.dispose()
    this.renderer.domElement.remove()
    this.labelLayer.remove()
  }
}
