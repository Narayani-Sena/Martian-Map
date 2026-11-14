import { create } from 'zustand'

const LS_KEY = (siteId) => `martian-map:mission:${siteId}`

export const DEFAULT_VECTORS = {
  route: true, stops: true, rings: true, traverse: true, waypoints: false, contours: false,
  shelters: true, refuges: false, labels: false, relays: true, ingenuity: true, suggestions: true, grid: false, chemistry: false,
}

export const useStore = create((set, get) => ({
  // ------------------------------------------------------------ site
  sites: [],
  siteId: null,
  site: null,
  siteError: null,

  // ------------------------------------------------------------ view
  mode: 'plan', // plan | 3d | walk
  panel: 'mission', // left panel id, or null when collapsed
  summaryOpen: false, // tablets: the EVA summary slides over the map (desktop shows it all the time)
  drawer: 'profile', // bottom drawer tab, or null when collapsed
  base: 'hirise',
  layers: {}, // id -> { on, opacity }
  vectors: { ...DEFAULT_VECTORS },
  tool: 'select', // select | add-stop | move-hab | add-relay | measure
  quality: 'medium', // low | medium | high (3D)
  drape: 'none', // overlay draped on the 3D terrain

  // ------------------------------------------------------------ mission
  habitat: null,
  stops: [],
  relays: [],
  radio: { habitat_mast_m: 12, suit_antenna_m: 2 },
  returnToHab: true,
  rover: { enabled: false, dropoff: null }, // rover-assisted EVA: PR-2 drives the crew to a drop-off (null = automatic)
  walk: {},
  suit: {},
  algorithm: 'astar',
  astarWeight: 1.0,
  startUtc: null,
  sepActive: false, // simulated solar-storm drill
  shadowT: 0, // terrain-shadow layer: seconds after the EVA start (2D map time slider)
  cmeDrill: null, // CME drill: ISO time of a pretend full-hit CME arrival (pinned, so a later start can clear it)

  // ------------------------------------------------------------ results
  plan: null,
  planLoading: false,
  planError: null,
  compare: null,
  compareLoading: false,
  conditions: null,
  spaceWeather: null,
  liveWeather: null,
  pointInfo: null,
  suggestions: null, // science stops the planner proposes (data-use item D3)
  suggestLoading: false,
  heliFlight: null, // Ingenuity flight picked on the map (Jezero)
  waysHome: null, // ways-home network: streams, gateways, basins (feature A1)
  pathHome: null, // the fastest way home from the last inspected point
  caches: [], // consumable caches / emergency O2 placed on the map (feature B4): extra havens
  skyFix: null, // skyline fix result (feature B1)
  envelope: null, // shrinking-world drill (feature A3): {lon, lat, name, minutes, data, area_ha, share}
  rescueCheck: null, // partner-down check of the route (feature B3)
  cacheSuggest: null, // suggested emergency caches (feature B4)
  orrery: null, // Sun, Earth, Mars, light time and CMEs (feature A5)
  lakeLevel: null, // ancient lake level, m (feature A4); null = the layer's default
  autoplan: null, // Plan it for me results (feature C3)
  apPreview: null, // which of its EVAs is drawn on the map
  scout: null, // Scout first: shaky stretches and the helicopter flight (C1)
  earthWalk: null, // walk it on Earth (F3): {on, sim, anchor, mars, acc, track, walked, wb}
  light: (() => { try { return localStorage.getItem('martian-map:light') || 'mars' } catch { return 'mars' } })(), // geologist's white balance (G6)
  tags: [], // crew tags (C2)
  tagKey: '', // changes when a hazard tag changes routing
  sketch: null, // Beat the planner: {points, result} (G3)
  askEarth: null, // when an answer from Earth arrives and where the crew is then (D2)
  live: { connected: false, history: [], clients: null, last: null }, // habitat console link (D1)
  skyFixOpts: { heading_known: true, noise_deg: 0.5 },

  // ------------------------------------------------------------ interaction
  hoverD: null, // distance along the route under the cursor (m)
  selectedStop: null,
  focus: null, // {lon, lat} to fly the map to
  walkT: 0, // seconds into the EVA timeline (walk mode)
  walkPlaying: false,
  walkSpeed: 20,
  toast: null,

  set: (patch) => set(typeof patch === 'function' ? patch(get()) : patch),

  setLayer: (id, patch) => set((s) => ({ layers: { ...s.layers, [id]: { ...(s.layers[id] || { on: false, opacity: 0.7 }), ...patch } } })),
  toggleVector: (id) => set((s) => ({ vectors: { ...s.vectors, [id]: !s.vectors[id] } })),
  notify: (text, kind = 'info') => {
    const id = Date.now()
    set({ toast: { id, text, kind } })
    setTimeout(() => { if (get().toast?.id === id) set({ toast: null }) }, 4200)
  },

  addStop: (lon, lat, extra = {}) => set((s) => {
    const n = s.stops.length + 1
    let id = `S${n}`
    while (s.stops.some((st) => st.id === id)) id = `S${Math.floor(Math.random() * 900 + 100)}`
    const stop = { id, name: `Stop ${n}`, kind: 'custom', lon, lat, dwell_min: 20, tasks: ['Photograph site', 'Collect sample'], ...extra }
    return { stops: [...s.stops, stop], selectedStop: id }
  }),
  updateStop: (id, patch) => set((s) => ({ stops: s.stops.map((st) => (st.id === id ? { ...st, ...patch } : st)) })),
  removeStop: (id) => set((s) => ({ stops: s.stops.filter((st) => st.id !== id), selectedStop: s.selectedStop === id ? null : s.selectedStop })),
  moveStop: (id, dir) => set((s) => {
    const i = s.stops.findIndex((st) => st.id === id)
    const j = i + dir
    if (i < 0 || j < 0 || j >= s.stops.length) return {}
    const arr = [...s.stops]
    ;[arr[i], arr[j]] = [arr[j], arr[i]]
    return { stops: arr }
  }),
  acceptSuggestion: (sg) => set((s) => {
    let id = `S${s.stops.length + 1}`
    while (s.stops.some((st) => st.id === id)) id = `S${Math.floor(Math.random() * 900 + 100)}`
    const stop = { id, name: sg.name, kind: sg.kind, lon: sg.lon, lat: sg.lat, dwell_min: sg.dwell_min, tasks: [...sg.tasks], science: sg.science }
    return { stops: [...s.stops, stop], selectedStop: id, suggestions: (s.suggestions || []).filter((x) => x.id !== sg.id) }
  }),
  startEnvelope: async (lon, lat, name) => {
    const s = get()
    set({ envelope: { lon, lat, name, minutes: s.envelope?.minutes ?? 120, data: null }, panel: 'breaks' })
    try {
      const q = new URLSearchParams({ lon, lat, havens: havensParam(havensList(s)), minutes_left: 120 })
      for (const [k, v] of Object.entries(s.walk || {})) if (v != null) q.set(k, v)
      const r = await fetch(`/api/sites/${s.siteId}/envelope?${q}`)
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const data = await r.json()
      const e = get().envelope
      if (e && e.lon === lon && e.lat === lat) set({ envelope: { ...e, data } })
    } catch (err) { get().notify(`Shrinking world: ${err.message}`, 'error') }
  },
  addRelay: (lon, lat) => set((s) => ({ relays: [...s.relays, { id: `R${s.relays.length + 1}`, lon, lat, height_m: 3 }] })),
  updateRelay: (id, patch) => set((s) => ({ relays: s.relays.map((r) => (r.id === id ? { ...r, ...patch } : r)) })),
  removeRelay: (id) => set((s) => ({ relays: s.relays.filter((r) => r.id !== id) })),

  // ------------------------------------------------------------ persistence
  loadMission(site) {
    let saved = null
    try { saved = JSON.parse(localStorage.getItem(LS_KEY(site.id)) || 'null') } catch { saved = null }
    const layers = {}
    for (const L of site.layers) layers[L.id] = { on: false, opacity: L.default_opacity ?? 0.7 }
    layers.hillshade.on = true
    const base = {
      habitat: { ...site.habitat },
      stops: site.stops.map((s) => ({ ...s })),
      relays: (site.radio?.relays || []).map((r, i) => ({ id: `R${i + 1}`, height_m: 3, ...r })),
      radio: { habitat_mast_m: site.radio?.habitat_mast_m ?? 12, suit_antenna_m: site.radio?.suit_antenna_m ?? 2 },
      walk: { ...site.defaults.walk },
      suit: { ...site.defaults.suit },
      startUtc: site.defaults.start_utc,
      rover: { enabled: false, dropoff: null },
      crew: ['EV1', 'EV2'],
    }
    set({ caches: [], ...base, ...(saved || {}), layers, plan: null, compare: null, selectedStop: null, walkT: 0, pointInfo: null, suggestions: null, heliFlight: null, cmeDrill: null, waysHome: null, pathHome: null, skyFix: null, envelope: null, rescueCheck: null, cacheSuggest: null, lakeLevel: null, autoplan: null, apPreview: null, scout: null, sketch: null })
  },
  saveMission() {
    const s = get()
    if (!s.siteId) return
    const keep = { habitat: s.habitat, stops: s.stops, relays: s.relays, radio: s.radio, walk: s.walk, suit: s.suit,
      algorithm: s.algorithm, astarWeight: s.astarWeight, returnToHab: s.returnToHab, rover: s.rover, caches: s.caches, crew: s.crew }
    try { localStorage.setItem(LS_KEY(s.siteId), JSON.stringify(keep)) } catch { /* private mode */ }
  },
  resetMission() {
    try { localStorage.removeItem(LS_KEY(get().siteId)) } catch { /* ignore */ }
    get().loadMission(get().site)
  },
  exportMission() {
    const s = get()
    return JSON.stringify({ site: s.siteId, habitat: s.habitat, stops: s.stops, relays: s.relays, radio: s.radio, walk: s.walk,
      suit: s.suit, algorithm: s.algorithm, astarWeight: s.astarWeight, startUtc: s.startUtc, returnToHab: s.returnToHab, rover: s.rover }, null, 2)
  },
  importMission(text) {
    const m = JSON.parse(text)
    if (m.site && m.site !== get().siteId) throw new Error(`This plan is for site "${m.site}"`)
    const pick = ['habitat', 'stops', 'relays', 'radio', 'walk', 'suit', 'algorithm', 'astarWeight', 'startUtc', 'returnToHab', 'rover']
    const patch = {}
    for (const k of pick) if (m[k] !== undefined) patch[k] = m[k]
    set(patch)
  },
}))

// Derived helpers --------------------------------------------------------------
export const missionBody = (s) => ({
  habitat: { lon: s.habitat.lon, lat: s.habitat.lat },
  stops: s.stops.map(({ id, name, lon, lat, dwell_min, kind, tasks }) => ({ id, name, lon, lat, dwell_min, kind, tasks })),
  return_to_habitat: s.returnToHab,
  algorithm: s.algorithm,
  astar_weight: s.astarWeight,
  walk: s.walk,
  suit: s.suit,
  radio: { ...s.radio, relays: s.relays.map(({ lon, lat, height_m, id }) => ({ lon, lat, height_m, name: id })) },
  start_utc: s.startUtc,
  sep_active: s.sepActive,
  ...(s.cmeDrill ? { cme_arrivals: [{ arrival: s.cmeDrill, glancing: false, cme: 'DRILL' }] } : {}),
  rover: { enabled: !!s.rover?.enabled, dropoff: s.rover?.enabled ? s.rover.dropoff || null : null },
  crew: (s.crew || []).filter((n) => n && n.trim()).slice(0, 4),
})

// Where the walking loop starts and ends: the hab, or PR-2 parked at its drop-off.
export const havenName = (plan) => (plan?.rover?.enabled ? plan.rover.name || 'the rover' : 'the hab')

// Every place the crew can walk home to: the hab, PR-2 parked at its drop-off, and any caches (feature A1, B4).
export function havensList(s) {
  const out = [{ lon: s.habitat.lon, lat: s.habitat.lat, name: 'Hab' }]
  const drop = s.rover?.enabled ? (s.rover.dropoff || s.plan?.rover?.dropoff) : null
  if (drop) out.push({ lon: drop.lon, lat: drop.lat, name: 'PR-2' })
  for (const c of s.caches || []) out.push({ lon: c.lon, lat: c.lat, name: c.name || c.id })
  return out
}
export const havensParam = (list) => list.map((h) => `${h.lon.toFixed(7)},${h.lat.toFixed(7)},${(h.name || '').replace(/[,;]/g, ' ')}`).join(';')
