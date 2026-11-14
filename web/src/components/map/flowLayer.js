// Ways home (feature A1): the trunks of the walk-home network as moving dashes that flow toward the haven.
// One canvas over the map (like Leaflet's own canvas renderer), redrawn ~40 times a second. The fine network
// underneath comes from the server as ordinary raster tiles; this layer only draws the bigger streams.
import L from 'leaflet'

const RAMP_MIN = [0, 15, 30, 60, 90, 130]
const RAMP_RGB = [[255, 247, 232], [188, 240, 255], [118, 204, 255], [104, 146, 255], [148, 112, 252], [196, 92, 236]]

export function rampRGB(m) {
  if (!(m > 0)) return RAMP_RGB[0]
  for (let i = 1; i < RAMP_MIN.length; i++) {
    if (m <= RAMP_MIN[i]) {
      const f = (m - RAMP_MIN[i - 1]) / (RAMP_MIN[i] - RAMP_MIN[i - 1])
      return RAMP_RGB[i - 1].map((a, k) => Math.round(a + (RAMP_RGB[i][k] - a) * f))
    }
  }
  return RAMP_RGB[RAMP_RGB.length - 1]
}

export const rampCss = (m, a = 1) => `rgba(${rampRGB(m).join(',')},${a})`

export const FlowLayer = L.Layer.extend({
  options: { pane: 'flow', fps: 40, speed: 1 },

  initialize(data, options) {
    L.setOptions(this, options)
    this._data = data
    this._t0 = performance.now()
    this._tick = this._tick.bind(this)
    this._paths = []
  },

  onAdd(map) {
    const c = (this._canvas = L.DomUtil.create('canvas', 'flow-canvas'))
    c.style.position = 'absolute'
    c.style.pointerEvents = 'none'
    map.getPane(this.options.pane).appendChild(c)
    this._ctx = c.getContext('2d')
    map.on('moveend zoomend resize viewreset', this._reset, this)
    map.on('zoomstart', this._hide, this)
    this._reset()
    this._raf = requestAnimationFrame(this._tick)
  },

  onRemove(map) {
    cancelAnimationFrame(this._raf)
    map.off('moveend zoomend resize viewreset', this._reset, this)
    map.off('zoomstart', this._hide, this)
    this._canvas.remove()
    this._canvas = null
  },

  setData(data) {
    this._data = data
    this._reset()
  },

  _hide() {
    if (this._canvas) this._canvas.style.visibility = 'hidden'
  },

  _reset() {
    const map = this._map
    if (!map || !this._canvas) return
    const size = map.getSize()
    const pad = 0.25
    const min = map.containerPointToLayerPoint([-size.x * pad, -size.y * pad]).round()
    const w = Math.round(size.x * (1 + 2 * pad))
    const h = Math.round(size.y * (1 + 2 * pad))
    const dpr = Math.min(2, window.devicePixelRatio || 1)
    const c = this._canvas
    L.DomUtil.setPosition(c, min)
    c.width = Math.round(w * dpr)
    c.height = Math.round(h * dpr)
    c.style.width = `${w}px`
    c.style.height = `${h}px`
    this._dpr = dpr
    this._w = w
    this._h = h
    const zk = Math.max(0.55, Math.min(2.4, 1.32 ** (map.getZoom() - 16)))
    this._zk = zk
    const total = this._data?.n_reach || 1
    const lmax = Math.log2(total)
    const out = []
    for (const s of this._data?.streams || []) {
      const path = new Path2D()
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
      s.c.forEach(([lon, lat], i) => {
        const p = map.latLngToLayerPoint([lat, lon]).subtract(min)
        if (i === 0) path.moveTo(p.x, p.y)
        else path.lineTo(p.x, p.y)
        if (p.x < x0) x0 = p.x
        if (p.x > x1) x1 = p.x
        if (p.y < y0) y0 = p.y
        if (p.y > y1) y1 = p.y
      })
      if (x1 < -20 || y1 < -20 || x0 > w + 20 || y0 > h + 20) continue
      const f = s.f[s.f.length - 1]
      const lw = Math.max(0, Math.log2(Math.max(2, f)) / lmax)
      const m = s.m[Math.floor(s.m.length / 2)]
      out.push({ path, lw, rgb: rampRGB(m).join(','), width: (0.9 + 5.2 * lw ** 1.7) * zk, phase: (s.m[0] || 0) * 3.1 })
    }
    out.sort((a, b) => a.lw - b.lw)
    this._paths = out
    c.style.visibility = 'visible'
    this._draw(performance.now())
  },

  _tick(now) {
    this._raf = requestAnimationFrame(this._tick)
    if (document.hidden || now - (this._last || 0) < 1000 / this.options.fps) return
    this._last = now
    this._draw(now)
  },

  _draw(now) {
    const ctx = this._ctx
    if (!ctx) return
    ctx.setTransform(this._dpr, 0, 0, this._dpr, 0, 0)
    ctx.clearRect(0, 0, this._w, this._h)
    const t = ((now - this._t0) / 1000) * this.options.speed
    const zk = this._zk
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    for (const p of this._paths) {
      const dash = (4 + 9 * p.lw) * zk
      const gap = (22 + 26 * p.lw) * zk
      ctx.setLineDash([dash, gap])
      // dashes move from the stream's upstream end toward home
      ctx.lineDashOffset = -(t * (26 + 34 * p.lw) * zk + p.phase)
      ctx.strokeStyle = `rgba(${p.rgb},${0.16 + 0.2 * p.lw})`
      ctx.lineWidth = p.width * 3.2
      ctx.stroke(p.path)
      ctx.strokeStyle = `rgba(${p.rgb},${0.75 + 0.25 * p.lw})`
      ctx.lineWidth = p.width
      ctx.stroke(p.path)
    }
    ctx.setLineDash([])
  },
})
