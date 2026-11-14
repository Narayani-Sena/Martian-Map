// Mars geodesy helpers. Same local projection as marsgeo/grid.py:
//   x = R cos(lat0) (lon - lon0),  y = R (lat - lat0)   (metres east / north of the site centre)

export const MARS_R = 3396190
const rad = (d) => (d * Math.PI) / 180
const deg = (r) => (r * 180) / Math.PI

export function makeGrid(g) {
  const kx = (MARS_R * Math.cos(rad(g.lat0)) * Math.PI) / 180
  const ky = (MARS_R * Math.PI) / 180
  return {
    ...g,
    kx,
    ky,
    toXY: (lon, lat) => [(lon - g.lon0) * kx, (lat - g.lat0) * ky],
    toLonLat: (x, y) => [g.lon0 + x / kx, g.lat0 + y / ky],
    toRC(lon, lat) {
      const x = (lon - g.lon0) * kx
      const y = (lat - g.lat0) * ky
      return [(g.y_max - y) / g.res - 0.5, (x - g.x_min) / g.res - 0.5]
    },
    xyToRC: (x, y) => [(g.y_max - y) / g.res - 0.5, (x - g.x_min) / g.res - 0.5],
    get xMax() { return g.x_min + g.width * g.res },
    get yMin() { return g.y_max - g.height * g.res },
  }
}

export function sampleBilinear(arr, w, h, r, c) {
  if (r < -0.5 || c < -0.5 || r > h - 0.5 || c > w - 0.5) return NaN
  const r0 = Math.max(0, Math.min(h - 1, Math.floor(r)))
  const c0 = Math.max(0, Math.min(w - 1, Math.floor(c)))
  const r1 = Math.min(h - 1, r0 + 1)
  const c1 = Math.min(w - 1, c0 + 1)
  const fr = Math.max(0, Math.min(1, r - r0))
  const fc = Math.max(0, Math.min(1, c - c0))
  return arr[r0 * w + c0] * (1 - fr) * (1 - fc) + arr[r0 * w + c1] * (1 - fr) * fc +
    arr[r1 * w + c0] * fr * (1 - fc) + arr[r1 * w + c1] * fr * fc
}

export function sampleNearest(arr, w, h, r, c) {
  const ri = Math.round(r)
  const ci = Math.round(c)
  if (ri < 0 || ci < 0 || ri >= h || ci >= w) return undefined
  return arr[ri * w + ci]
}

export function distanceM(a, b) {
  const p1 = rad(a.lat)
  const p2 = rad(b.lat)
  const dp = p2 - p1
  const dl = rad(b.lon - a.lon)
  const s = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2
  return 2 * MARS_R * Math.asin(Math.min(1, Math.sqrt(s)))
}

export function bearingDeg(a, b) {
  const p1 = rad(a.lat)
  const p2 = rad(b.lat)
  const dl = rad(b.lon - a.lon)
  const y = Math.sin(dl) * Math.cos(p2)
  const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl)
  return (deg(Math.atan2(y, x)) + 360) % 360
}

export const compass = (b) => ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'][Math.round(b / 22.5) % 16]

// Interpolate a value from sorted xs -> ys (linear, clamped)
export function interp(xs, ys, x) {
  if (!xs || xs.length === 0) return NaN
  if (x <= xs[0]) return ys[0]
  const n = xs.length
  if (x >= xs[n - 1]) return ys[n - 1]
  let lo = 0
  let hi = n - 1
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1
    if (xs[mid] <= x) lo = mid
    else hi = mid
  }
  const f = (x - xs[lo]) / (xs[hi] - xs[lo] || 1)
  const a = ys[lo]
  const b = ys[hi]
  if (a == null || b == null) return a ?? b
  return a + (b - a) * f
}

// Index of the last xs[i] <= x
export function bisect(xs, x) {
  let lo = 0
  let hi = xs.length - 1
  if (x < xs[0]) return 0
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1
    if (xs[mid] <= x) lo = mid
    else hi = mid
  }
  return x >= xs[hi] ? hi : lo
}
