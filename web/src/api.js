// Thin client for the FastAPI backend.

async function j(url, opts) {
  const r = await fetch(url, opts)
  if (!r.ok) {
    let msg = r.statusText
    try {
      const body = await r.json()
      msg = typeof body.detail === 'string' ? body.detail : JSON.stringify(body.detail)
    } catch { /* not JSON */ }
    throw new Error(msg || `HTTP ${r.status}`)
  }
  return r.json()
}

const post = (url, body, signal) =>
  j(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal })

export const qs = (o) =>
  Object.entries(o)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&')

export const obsString = (hab, radio, relays = []) =>
  [`${hab.lon.toFixed(7)},${hab.lat.toFixed(7)},${radio.habitat_mast_m}`, ...relays.map((r) => `${r.lon.toFixed(7)},${r.lat.toFixed(7)},${r.height_m}`)].join(';')

export const walkParams = (walk) => {
  const keys = ['flat_speed', 'max_slope', 'caution_slope', 'max_rough', 'sand_penalty', 'hazard_aversion', 'load_kg']
  const o = {}
  for (const k of keys) if (walk && walk[k] != null) o[k] = walk[k]
  return o
}

export const api = {
  sites: () => j('/api/sites'),
  site: (id) => j(`/api/sites/${id}`),
  plan: (id, body, signal) => post(`/api/sites/${id}/plan`, body, signal),
  route: (id, body) => post(`/api/sites/${id}/route`, body),
  walkback: (id, body) => post(`/api/sites/${id}/walkback`, body),
  viewshed: (id, body) => post(`/api/sites/${id}/viewshed`, body),
  query: (id, params, signal) => j(`/api/sites/${id}/query?${qs(params)}`, { signal }),
  conditions: (id, utc) => j(`/api/sites/${id}/conditions${utc ? `?utc=${encodeURIComponent(utc)}` : ''}`),
  spaceWeather: () => j('/api/spaceweather'),
  liveWeather: (id) => j(`/api/sites/${id}/weather/live`),
  roverImages: (mission, sol, solEnd) => j(`/api/rover/${mission}/images?${qs({ sol, sol_end: solEnd, per_page: 48 })}`),
  ingenuity: (id) => j(`/api/sites/${id}/ingenuity`),
  suggestStops: (id, body) => post(`/api/sites/${id}/suggest-stops`, body),
  ingenuityImages: (sol) => j(`/api/ingenuity/images?${qs({ sol, per_page: 36 })}`),
  roverNearest: (id, lon, lat) => j(`/api/sites/${id}/rover/nearest?${qs({ lon, lat, n: 4 })}`),
  waysHome: (id, params, signal) => j(`/api/sites/${id}/ways-home?${qs(params)}`, { signal }),
  skylineFix: (id, body) => post(`/api/sites/${id}/skyline/fix`, body),
  envelope: (id, params) => j(`/api/sites/${id}/envelope?${qs(params)}`),
  orrery: () => j('/api/orrery'),
  autoplan: (id, body) => post(`/api/sites/${id}/autoplan`, body),
  scout: (id, body) => post(`/api/sites/${id}/scout`, body),
  tags: (id) => j(`/api/sites/${id}/tags`),
  addTag: (id, body) => post(`/api/sites/${id}/tags`, body),
  deleteTag: (id, tagId) => j(`/api/sites/${id}/tags/${tagId}`, { method: 'DELETE' }),
  scoreRoute: (id, body) => post(`/api/sites/${id}/score-route`, body),
  rescue: (id, body) => post(`/api/sites/${id}/rescue`, body),
  caches: (id, body) => post(`/api/sites/${id}/caches`, body),
  skylineCheck: (id, params) => j(`/api/sites/${id}/skyline/check?${qs(params)}`),
  gridLines: (id) => j(`/api/sites/${id}/grid-lines`),
  chemistry: (id, q) => j(`/api/sites/${id}/chemistry${q ? `?${qs(q)}` : ''}`),
  radar: (id, q) => j(`/api/sites/${id}/radar${q ? `?${qs(q)}` : ''}`),
  radarRunUrl: (id, run) => `/api/sites/${id}/radar/run/${run}.png`,
  pathHome: (id, params, signal) => j(`/api/sites/${id}/ways-home/path?${qs(params)}`, { signal }),
  file: (id, name) => `/api/sites/${id}/files/${name}`,
  tileUrl: (id, layer, params = {}) => {
    const q = qs(params)
    return `/api/sites/${id}/tiles/${layer}/{z}/{x}/{y}.png${q ? `?${q}` : ''}`
  },
  overlayUrl: (id, layer, params = {}) => `/api/sites/${id}/overlay/${layer}.png?${qs(params)}`,
  async floatArray(url) {
    const r = await fetch(url)
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    return new Float32Array(await r.arrayBuffer())
  },
  terrain: (id, size) => api.floatArray(`/api/sites/${id}/terrain?size=${size}`),
  regionalTerrain: (id, size) => api.floatArray(`/api/sites/${id}/regional-terrain?size=${size}`),
  async grid(id, layer, params) {
    const r = await fetch(`/api/sites/${id}/grid/${layer}.bin?${qs(params)}`)
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    const [h, w] = r.headers.get('X-Shape').split(',').map(Number)
    const dtype = r.headers.get('X-Dtype')
    const buf = await r.arrayBuffer()
    return { data: dtype === 'uint8' ? new Uint8Array(buf) : new Float32Array(buf), w, h, grid: r.headers.get('X-Grid') }
  },
}
