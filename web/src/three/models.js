import * as THREE from 'three'

// Low-poly procedural models. Units are metres; +Y up, model faces -Z.
const mat = (color, opts = {}) => new THREE.MeshStandardMaterial({ color, roughness: 0.6, metalness: 0.1, ...opts })

function shadowAll(obj) {
  obj.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true } })
  return obj
}

export function habitat() {
  const g = new THREE.Group()
  const white = mat(0xe9edf2, { roughness: 0.45 })
  const grey = mat(0x9aa4b1, { metalness: 0.5, roughness: 0.4 })
  const orange = mat(0xff7a3d, { roughness: 0.5 })
  // main dome, half buried under a regolith berm for radiation shielding
  const dome = new THREE.Mesh(new THREE.SphereGeometry(7, 40, 20, 0, Math.PI * 2, 0, Math.PI / 2), white)
  dome.scale.set(1, 0.72, 1)
  g.add(dome)
  const berm = new THREE.Mesh(new THREE.CylinderGeometry(8.6, 9.6, 2.2, 40, 1, true), mat(0x9b6a4b, { roughness: 1 }))
  berm.position.y = 0.9
  g.add(berm)
  // two cylindrical modules
  for (const [x, z, ry] of [[11, 2, 0], [-3, 12, Math.PI / 2]]) {
    const mod = new THREE.Mesh(new THREE.CylinderGeometry(2.4, 2.4, 10, 24), white)
    mod.rotation.z = Math.PI / 2
    const holder = new THREE.Group()
    holder.add(mod)
    holder.position.set(x, 2.4, z)
    holder.rotation.y = ry
    for (const s of [-1, 1]) {
      const cap = new THREE.Mesh(new THREE.SphereGeometry(2.4, 20, 10, 0, Math.PI * 2, 0, Math.PI / 2), white)
      cap.rotation.z = (s * -Math.PI) / 2
      cap.position.x = s * 5
      holder.add(cap)
    }
    const stripe = new THREE.Mesh(new THREE.CylinderGeometry(2.45, 2.45, 0.6, 24), orange)
    stripe.rotation.z = Math.PI / 2
    holder.add(stripe)
    g.add(holder)
  }
  // airlock
  const lock = new THREE.Mesh(new THREE.BoxGeometry(3, 3, 3.6), grey)
  lock.position.set(0, 1.5, -8.4)
  g.add(lock)
  const door = new THREE.Mesh(new THREE.BoxGeometry(1.4, 2.1, 0.1), mat(0x222831, { emissive: 0x4fd1ff, emissiveIntensity: 0.25 }))
  door.position.set(0, 1.3, -10.25)
  g.add(door)
  // solar arrays
  for (let i = 0; i < 4; i++) {
    const p = new THREE.Group()
    const panel = new THREE.Mesh(new THREE.BoxGeometry(6, 0.12, 3), mat(0x1a2a4a, { metalness: 0.7, roughness: 0.25, emissive: 0x061024 }))
    panel.rotation.x = -0.45
    panel.position.y = 1.6
    const post = new THREE.Mesh(new THREE.CylinderGeometry(0.08, 0.08, 1.6), grey)
    post.position.y = 0.8
    p.add(panel, post)
    p.position.set(-22 + i * 7, 0, -4)
    g.add(p)
  }
  // radio mast + dish + beacon
  const mast = new THREE.Mesh(new THREE.CylinderGeometry(0.15, 0.25, 12), grey)
  mast.position.set(8, 6, -6)
  g.add(mast)
  const dish = new THREE.Mesh(new THREE.SphereGeometry(1.1, 20, 8, 0, Math.PI * 2, 0, 0.9), white)
  dish.rotation.x = -Math.PI / 2.4
  dish.position.set(8, 10.5, -6.6)
  g.add(dish)
  const beacon = new THREE.Mesh(new THREE.SphereGeometry(0.28, 12, 8), new THREE.MeshBasicMaterial({ color: 0xff3b3b }))
  beacon.position.set(8, 12.2, -6)
  beacon.userData.blink = true
  g.add(beacon)
  return shadowAll(g)
}

function wheels(g, xs, z, r, w, material) {
  for (const x of xs) {
    for (const s of [-1, 1]) {
      const wh = new THREE.Mesh(new THREE.CylinderGeometry(r, r, w, 16), material)
      wh.rotation.z = Math.PI / 2
      wh.position.set(s * z, r, x)
      g.add(wh)
    }
  }
}

export function pressurizedRover() {
  const g = new THREE.Group()
  const body = new THREE.Mesh(new THREE.BoxGeometry(3.2, 2.4, 7), mat(0xeef1f5, { roughness: 0.4 }))
  body.position.y = 2.2
  g.add(body)
  const cab = new THREE.Mesh(new THREE.BoxGeometry(3, 1.4, 2), mat(0x10202e, { metalness: 0.6, roughness: 0.15 }))
  cab.position.set(0, 2.6, -3.2)
  g.add(cab)
  const stripe = new THREE.Mesh(new THREE.BoxGeometry(3.25, 0.35, 7.05), mat(0xff7a3d))
  stripe.position.y = 1.6
  g.add(stripe)
  wheels(g, [-2.4, 0, 2.4], 1.75, 0.65, 0.5, mat(0x30353d, { roughness: 0.9 }))
  return shadowAll(g)
}

export function curiosity() {
  const g = new THREE.Group()
  const metal = mat(0xc9c2b4, { metalness: 0.4, roughness: 0.5 })
  const dark = mat(0x3a3a3a, { roughness: 0.8 })
  const body = new THREE.Mesh(new THREE.BoxGeometry(2.2, 0.7, 2.8), metal)
  body.position.y = 1.2
  g.add(body)
  const rtg = new THREE.Mesh(new THREE.CylinderGeometry(0.3, 0.35, 1.2, 12), dark)
  rtg.rotation.x = -0.9
  rtg.position.set(0, 1.4, 1.8)
  g.add(rtg)
  const mast = new THREE.Mesh(new THREE.CylinderGeometry(0.06, 0.06, 1.3), metal)
  mast.position.set(-0.6, 2.1, -1.0)
  g.add(mast)
  const head = new THREE.Mesh(new THREE.BoxGeometry(0.6, 0.35, 0.35), metal)
  head.position.set(-0.6, 2.85, -1.0)
  g.add(head)
  wheels(g, [-1.1, 0, 1.1], 1.25, 0.26, 0.4, dark)
  return shadowAll(g)
}

export function astronaut(accent = 0xff7a3d) {
  const g = new THREE.Group()
  const suit = mat(0xf2f2f0, { roughness: 0.7 })
  const torso = new THREE.Mesh(new THREE.CapsuleGeometry(0.28, 0.55, 4, 10), suit)
  torso.position.y = 1.15
  g.add(torso)
  const pack = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.65, 0.28), mat(0xdcdcdc))
  pack.position.set(0, 1.25, 0.3)
  g.add(pack)
  const helmet = new THREE.Mesh(new THREE.SphereGeometry(0.2, 16, 12), mat(0xffffff, { roughness: 0.3 }))
  helmet.position.y = 1.72
  g.add(helmet)
  const visor = new THREE.Mesh(new THREE.SphereGeometry(0.17, 16, 10, 0, Math.PI), mat(0xd6a35a, { metalness: 0.9, roughness: 0.1 }))
  visor.rotation.y = Math.PI
  visor.position.set(0, 1.72, -0.06)
  g.add(visor)
  for (const s of [-1, 1]) {
    const leg = new THREE.Mesh(new THREE.CapsuleGeometry(0.11, 0.62, 4, 8), suit)
    leg.position.set(s * 0.14, 0.42, 0)
    g.add(leg)
    const arm = new THREE.Mesh(new THREE.CapsuleGeometry(0.09, 0.5, 4, 8), suit)
    arm.position.set(s * 0.38, 1.15, 0)
    g.add(arm)
  }
  const band = new THREE.Mesh(new THREE.CylinderGeometry(0.3, 0.3, 0.08, 16), mat(accent))
  band.position.y = 1.45
  g.add(band)
  return shadowAll(g)
}

export function relayMast(h = 3) {
  const g = new THREE.Group()
  const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.06, 0.12, h), mat(0xb7c0cd, { metalness: 0.6 }))
  pole.position.y = h / 2
  g.add(pole)
  const base = new THREE.Mesh(new THREE.CylinderGeometry(0.6, 0.7, 0.3, 3), mat(0x3b4350))
  base.position.y = 0.15
  g.add(base)
  const light = new THREE.Mesh(new THREE.SphereGeometry(0.14, 10, 8), new THREE.MeshBasicMaterial({ color: 0x4fd1ff }))
  light.position.y = h + 0.1
  light.userData.blink = true
  g.add(light)
  return shadowAll(g)
}

export function beacon(color = 0xff7a3d, height = 60) {
  const g = new THREE.Group()
  const beam = new THREE.Mesh(
    new THREE.CylinderGeometry(0.5, 0.9, height, 16, 1, true),
    new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.32, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide, fog: false }),
  )
  beam.position.y = height / 2
  g.add(beam)
  const ring = new THREE.Mesh(
    new THREE.RingGeometry(2.2, 3, 40),
    new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.85, side: THREE.DoubleSide, depthWrite: false }),
  )
  ring.rotation.x = -Math.PI / 2
  ring.position.y = 0.35
  ring.userData.pulse = true
  g.add(ring)
  return g
}
