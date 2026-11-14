import React, { useEffect, useRef, useState } from 'react'
import L from 'leaflet'
import { Crosshair, Home, Maximize, MousePointer2, Plus, RadioTower, Ruler } from 'lucide-react'
import { havensList, havensParam, useStore } from '../store.js'
import { api, obsString, walkParams } from '../api.js'
import { FlowLayer, rampCss } from './map/flowLayer.js'
import { CanvasOverlay, decodeMinutes, paintEnvelope } from './map/envelopeLayer.js'
import { earthView, sendCommand } from '../lib/live.js'
import { AP_COLORS } from './panels/SmartPanel.jsx'
import { MARS_R, bearingDeg, compass, distanceM, interp } from '../lib/geo.js'
import { fmtDist, fmtLonLat } from '../lib/format.js'
import { chemBarsHtml } from './ChemBars.jsx'

// Leaflet's Web-Mercator CRS with the Mars radius, so the scale bar and distances are Martian.
const MarsCRS = L.extend({}, L.CRS.EPSG3857, { R: MARS_R })

// Leaflet 1.9.4's GridLayer.redraw() takes the map zoom without rounding it. The map snaps to quarter zooms, so a
// layer whose URL changes (setUrl -> redraw: walk-back after moving the hab, hazard after a limit, radio after a
// relay, the shadow time slider) asked for tiles at z = 14.75 and got HTTP 422. Round it the way _setView does.
L.GridLayer.include({
  redraw() {
    if (this._map) {
      this._removeAllTiles()
      const tileZoom = this._clampZoom(Math.round(this._map.getZoom()))
      if (tileZoom !== this._tileZoom) {
        this._tileZoom = tileZoom
        this._updateLevels()
      }
      this._update()
    }
    return this
  },
})

// JPL's mosaics (like its rover tracks) are in the rover team's own map frame. The site build measured that
// frame against our USGS DTM (data-use item D6): the mosaic shows a feature (dx, dy) metres from where our terrain
// has it. Draw its tiles shifted back, so imagery, terrain layers, routes and tracks line up.
const ShiftedTileLayer = L.TileLayer.extend({
  _mpp(z) { return (2 * Math.PI * MARS_R * Math.cos(((this.options.lat0 || 0) * Math.PI) / 180)) / (256 * 2 ** z) },
  _getTilePos(coords) {
    const p = L.TileLayer.prototype._getTilePos.call(this, coords)
    const sh = this.options.shiftM
    if (!sh) return p
    const mpp = this._mpp(coords.z)
    return p.add(L.point(-sh[0] / mpp, sh[1] / mpp))
  },
  _getTiledPixelBounds(center) { // load the extra tiles the shift pulls into view
    const b = L.TileLayer.prototype._getTiledPixelBounds.call(this, center)
    const sh = this.options.shiftM
    if (!sh) return b
    const mpp = this._mpp(this._tileZoom)
    const pad = L.point(Math.abs(sh[0]) / mpp + 4, Math.abs(sh[1]) / mpp + 4)
    return L.bounds(b.min.subtract(pad), b.max.add(pad))
  },
})

const SVG = {
  home: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/><path d="M9.5 21v-6h5v6"/></svg>',
  shield: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>',
  radio: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M4.9 16.1a10 10 0 0 1 0-8.2"/><path d="M19.1 7.9a10 10 0 0 1 0 8.2"/><path d="M8 13.4a4 4 0 0 1 0-2.8"/><path d="M16 10.6a4 4 0 0 1 0 2.8"/><circle cx="12" cy="12" r="1.6"/><path d="M12 14v8"/></svg>',
  rover: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="8" width="16" height="6" rx="1.5"/><circle cx="6" cy="18" r="2"/><circle cx="12" cy="18" r="2"/><circle cx="18" cy="18" r="2"/><path d="M15 8V4h3"/></svg>',
  refuge: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><path d="M3 20h18L14 6l-3 5-2-2z"/></svg>',
}

const pinIcon = (n, sel) => L.divIcon({ className: '', html: `<div class="pin ${sel ? 'sel' : ''}"><b>${n}</b></div>`, iconSize: [30, 30], iconAnchor: [15, 34] })
const habIcon = L.divIcon({ className: '', html: `<div class="hab-icon">${SVG.home}</div>`, iconSize: [38, 38], iconAnchor: [19, 19] })
const prIcon = (manual) => L.divIcon({ className: '', html: `<div class="pr-icon ${manual ? 'manual' : ''}">PR-2</div>`, iconSize: [44, 24], iconAnchor: [22, 12] })
const mini = (kind, svg) => L.divIcon({ className: '', html: `<div class="mini-icon ${kind}">${svg}</div>`, iconSize: [26, 26], iconAnchor: [13, 13] })
const RING_COLORS = { 15: '#2ecc71', 30: '#9be15d', 45: '#f4e04d', 60: '#f7a541', 90: '#f0643c', 120: '#d62f4b' }

function useLatest(value) {
  const r = useRef(value)
  r.current = value
  return r
}

// Tools that other panels add (emergency drills, caches, sketching ...): id -> hint
export const extraHints = {}

export default function MapView() {
  const el = useRef(null)
  const map = useRef(null)
  const groups = useRef({})
  const tileLayers = useRef({})
  const [cursor, setCursor] = useState(null)
  const [ctx, setCtx] = useState(null)
  const [measure, setMeasure] = useState([])
  const st = useStore()
  const stRef = useLatest(st)
  const site = st.site

  // ------------------------------------------------------------------ create map
  useEffect(() => {
    const m = L.map(el.current, {
      crs: MarsCRS, zoomControl: false, attributionControl: true, minZoom: 12, maxZoom: 21, zoomSnap: 0.25,
      wheelPxPerZoomLevel: 90, preferCanvas: false,
    })
    map.current = m
    const b = L.latLngBounds(site.bounds)
    const s0 = stRef.current
    const pts = [s0.habitat, ...s0.stops].filter(Boolean).map((p) => [p.lat, p.lon])
    if (pts.length > 1) m.fitBounds(L.latLngBounds(pts).pad(0.45), { maxZoom: 18 })
    else m.fitBounds(b.pad(-0.05))
    m.setMaxBounds(b.pad(0.8))
    L.control.zoom({ position: 'bottomright' }).addTo(m)
    L.control.scale({ position: 'bottomright', metric: true, imperial: false, maxWidth: 140 }).addTo(m)
    m.attributionControl.setPrefix('Mars · R = 3,396.19 km')
    const shade = m.createPane('shade')
    shade.style.zIndex = 260
    shade.classList.add('blend-multiply')
    m.createPane('overlays').style.zIndex = 300
    m.createPane('vectors').style.zIndex = 420
    m.createPane('flow').style.zIndex = 432
    m.createPane('route').style.zIndex = 440
    for (const k of ['contours', 'traverse', 'waypoints', 'rings', 'route', 'compare', 'markers', 'measure', 'hover', 'extras', 'heli', 'suggest', 'flow', 'pathHome', 'skyfix', 'grid', 'ideas', 'envelope', 'rescue', 'caches', 'live', 'smart', 'chem', 'radar', 'radarCursor', 'views'])
      groups.current[k] = L.layerGroup().addTo(m)

    m.on('mousemove', (e) => setCursor({ lon: e.latlng.lng, lat: e.latlng.lat }))
    m.on('mouseout', () => setCursor(null))
    m.on('click', (e) => onClick(e.latlng.lng, e.latlng.lat))
    m.on('contextmenu', (e) => {
      const p = e.containerPoint
      setCtx({ x: p.x, y: p.y, lon: e.latlng.lng, lat: e.latlng.lat })
    })
    m.on('movestart', () => setCtx(null))
    return () => { m.remove(); map.current = null; tileLayers.current = {} }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [site.id])

  // ------------------------------------------------------------------ clicks
  const inspect = async (lon, lat) => {
    const s = stRef.current
    s.set({ pointInfo: { lon, lat, loading: true } })
    if (s.layers.ways_home?.on) { // lost? walk downstream: the fastest way home from here
      api.pathHome(s.siteId, { lon, lat, havens: havensParam(havensList(s)), ...walkParams(s.walk) })
        .then((ph) => useStore.getState().set({ pathHome: ph.ok ? ph : null })).catch(() => {})
    }
    try {
      const q = await api.query(s.siteId, { lon, lat, hab_lon: s.habitat.lon, hab_lat: s.habitat.lat, obs: obsString(s.habitat, s.radio, s.relays), utc: s.startUtc, ...walkParams(s.walk) })
      useStore.getState().set({ pointInfo: { lon, lat, ...q } })
    } catch (e) {
      useStore.getState().set({ pointInfo: null })
      useStore.getState().notify(e.message, 'error')
    }
  }
  const onClick = (lon, lat) => {
    const s = stRef.current
    setCtx(null)
    if (s.tool === 'add-stop') { s.addStop(lon, lat); s.set({ tool: 'select' }) }
    else if (s.tool === 'move-hab') { s.set({ habitat: { ...s.habitat, lon, lat }, tool: 'select' }) }
    else if (s.tool === 'add-relay') { s.addRelay(lon, lat); s.set({ tool: 'select' }) }
    else if (s.tool === 'tag-hazard' || s.tool === 'tag-find') { // feature C2
      const kind = s.tool === 'tag-hazard' ? 'hazard' : 'find'
      api.addTag(s.siteId, { kind, lon, lat, by: 'Console', note: kind === 'hazard' ? 'Hazard seen' : 'Worth a stop' })
        .then((r) => { useStore.getState().set({ tags: r.tags, tagKey: r.version }); useStore.getState().notify(kind === 'hazard' ? 'Hazard tagged: re-planning around it' : 'Find tagged', 'ok') })
        .catch((e) => useStore.getState().notify(e.message, 'error'))
      s.set({ tool: 'select' })
    } else if (s.tool === 'sketch') { // feature G3
      s.set({ sketch: { points: [...(s.sketch?.points || []), [lon, lat]], result: null } })
    } else if (s.tool === 'push-wp') { // feature D1: the habitat pushes a waypoint into the visor
      if (sendCommand({ type: 'waypoint', lon, lat, name: 'Habitat waypoint' })) s.notify('Waypoint sent to the helmet', 'ok')
      else s.notify('Open the habitat console first (Earth link panel)', 'error')
      s.set({ tool: 'select' })
    } else if (s.tool === 'crew') { s.startEnvelope(lon, lat, 'the crew'); s.set({ tool: 'select' }) }
    else if (s.tool === 'skyfix') { // feature B1: the helmet's skyline here, fixed against every 4 m cell
      api.skylineFix(s.siteId, { lon, lat, ...s.skyFixOpts })
        .then((r) => useStore.getState().set({ skyFix: r, panel: 'breaks' }))
        .catch((e) => useStore.getState().notify(`Skyline fix: ${e.message}`, 'error'))
    } else if (s.tool === 'measure') {
      setMeasure((m) => (m.length >= 2 ? [{ lon, lat }] : [...m, { lon, lat }]))
    } else inspect(lon, lat)
  }

  // ------------------------------------------------------------------ base maps
  useEffect(() => {
    const m = map.current
    if (!m) return
    for (const k of ['base', 'labels']) { if (tileLayers.current[k]) { m.removeLayer(tileLayers.current[k]); delete tileLayers.current[k] } }
    const bm = st.base === 'hirise' ? site.basemap : st.base === 'ctx' ? site.context_basemap : null
    const shift = site.team_dem ? { shiftM: [site.team_dem.dx_m, site.team_dem.dy_m], lat0: site.center.lat } : {}
    if (bm) {
      tileLayers.current.base = new ShiftedTileLayer(bm.proxy_url, {
        maxNativeZoom: bm.max_native_zoom, minNativeZoom: Math.min(bm.min_zoom ?? 0, 12), maxZoom: 21, attribution: bm.attribution, tms: false, className: 'basemap', ...shift,
      }).addTo(m)
    }
    if (st.vectors.labels && site.labels) {
      tileLayers.current.labels = new ShiftedTileLayer(site.labels.proxy_url, { maxNativeZoom: site.labels.max_native_zoom, maxZoom: 21, pane: 'overlayPane', zIndex: 650, ...shift }).addTo(m)
    }
  }, [st.base, st.vectors.labels, site])

  // ------------------------------------------------------------------ raster overlays
  const walkKey = JSON.stringify(walkParams(st.walk))
  const obs = obsString(st.habitat, st.radio, st.relays)
  const havensKey = havensParam(havensList(st))
  useEffect(() => {
    const m = map.current
    if (!m) return
    for (const L0 of site.layers) {
      const conf = st.layers[L0.id]
      const existing = tileLayers.current[`ov:${L0.id}`]
      if (!conf?.on) {
        if (existing) { m.removeLayer(existing); delete tileLayers.current[`ov:${L0.id}`] }
        continue
      }
      let params = {}
      if (L0.dynamic === 'walk') params = { ...walkParams(st.walk), tv: st.tagKey ? st.tagKey.length : undefined }
      if (L0.dynamic === 'walkback') params = { hab_lon: st.habitat.lon.toFixed(7), hab_lat: st.habitat.lat.toFixed(7), ...walkParams(st.walk) }
      if (L0.dynamic === 'comms') params = { obs, tgt: st.radio.suit_antenna_m }
      if (L0.dynamic === 'sun') params = { utc: new Date(new Date(st.startUtc).getTime() + Math.round((st.shadowT || 0) / 120) * 120000).toISOString() }
      if (L0.dynamic === 'havens') params = { havens: havensKey, ...walkParams(st.walk) }
      if (L0.dynamic === 'level') params = { level: st.lakeLevel ?? L0.default_level }
      if (L0.dynamic === 'rescue') {
        const base = (st.rover?.enabled && (st.rover.dropoff || st.plan?.rover?.dropoff)) || st.habitat
        params = { havens: havensKey, rover_lon: base.lon.toFixed(7), rover_lat: base.lat.toFixed(7), ...walkParams(st.walk) }
      }
      const url = api.tileUrl(site.id, L0.id, params)
      if (existing) {
        if (existing._url !== url) existing.setUrl(url)
        existing.setOpacity(conf.opacity)
      } else {
        const order = site.layers.findIndex((x) => x.id === L0.id)
        tileLayers.current[`ov:${L0.id}`] = L.tileLayer(url, {
          pane: L0.id === 'hillshade' ? 'shade' : 'overlays', opacity: conf.opacity, maxNativeZoom: 20, maxZoom: 21, zIndex: 10 + order,
          bounds: L.latLngBounds(site.bounds).pad(0.02),
        }).addTo(m)
      }
    }
  }, [st.layers, walkKey, obs, st.habitat, st.startUtc, st.shadowT, site, havensKey, st.lakeLevel])

  // ------------------------------------------------------------------ ways home: flowing trunks + gateways (feature A1)
  const flowOn = !!st.layers.ways_home?.on
  const flowRef = useRef(null)
  useEffect(() => {
    if (!flowOn) { useStore.getState().set({ waysHome: null, pathHome: null }); return undefined }
    const ctrl = new AbortController()
    api.waysHome(site.id, { havens: havensKey, ...walkParams(st.walk) }, ctrl.signal)
      .then((d) => useStore.getState().set({ waysHome: d }))
      .catch((e) => { if (e.name !== 'AbortError') useStore.getState().notify(`Ways home: ${e.message}`, 'error') })
    return () => ctrl.abort()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flowOn, havensKey, walkKey, site.id])
  useEffect(() => {
    const m = map.current
    const g = groups.current.flow
    g.clearLayers()
    const d = st.waysHome
    if (!m || !flowOn || !d) {
      if (flowRef.current) { m?.removeLayer(flowRef.current); flowRef.current = null }
      return
    }
    if (flowRef.current) flowRef.current.setData(d)
    else flowRef.current = new FlowLayer(d, { pane: 'flow' }).addTo(m)
    for (const gw of d.gateways || []) {
      const pct = Math.round(gw.share * 100)
      L.marker([gw.lat, gw.lon], {
        pane: 'flow', zIndexOffset: 700,
        icon: L.divIcon({ className: '', iconSize: [20, 20], iconAnchor: [10, 10], html: `<div class="gateway-dia" style="--c:${rampCss(gw.minutes)}"></div>` }),
      })
        .bindTooltip(`<b>GATEWAY ${gw.id}</b> · way home for ${pct} % of the site · ${Math.round(gw.minutes)} min out`, { permanent: true, direction: 'right', offset: [10, 0], className: 'gateway-label' })
        .bindPopup(`<b>Gateway ${gw.id}</b><br>${gw.area_ha} ha of the site (${pct} %) walk home through this point.<br>${gw.minutes} min from ${gw.haven === 'Hab' ? 'the hab' : gw.haven}.<br><span style="opacity:.75">A cache, a relay or a marker here does the most good.</span>`, { className: 'mm-popup' })
        .addTo(g)
    }
    if ((d.havens || []).length > 1) {
      for (const b of d.basins || []) {
        L.marker([b.lat, b.lon], { pane: 'flow', interactive: false, icon: L.divIcon({ className: '', iconSize: [0, 0], html: '' }) })
          .bindTooltip(`${b.name} basin · ${b.area_ha} ha (${Math.round(b.share * 100)} %)`, { permanent: true, direction: 'bottom', offset: [0, 18], className: 'basin-label' })
          .addTo(g)
      }
    }
  }, [st.waysHome, flowOn])
  useEffect(() => () => { flowRef.current = null }, [site.id])
  useEffect(() => {
    const g = groups.current.pathHome
    g.clearLayers()
    const ph = st.pathHome
    if (!ph || !flowOn) return
    const ll = ph.path.map(([lon, lat]) => [lat, lon])
    L.polyline(ll, { pane: 'route', color: '#000', weight: 9, opacity: 0.45, interactive: false }).addTo(g)
    L.polyline(ll, { pane: 'route', color: '#fff7e8', weight: 3.5, opacity: 1, dashArray: '1 9', lineCap: 'round', className: 'path-home' })
      .bindTooltip(`Lost? Walk downstream: ${ph.start_minutes} min to ${ph.haven === 'Hab' ? 'the hab' : ph.haven} along the network`, { sticky: true, className: 'mm-tip' })
      .addTo(g)
  }, [st.pathHome, flowOn])

  // ------------------------------------------------------------------ skyline fix (feature B1)
  useEffect(() => {
    const g = groups.current.skyfix
    g.clearLayers()
    const f = st.skyFix
    if (!f) return
    L.imageOverlay(f.likelihood_png, f.bounds, { pane: 'overlays', opacity: 0.75, interactive: false }).addTo(g)
    for (const a of f.fix.alternatives || []) {
      L.circleMarker([a.lat, a.lon], { pane: 'vectors', radius: 7, color: '#ffb020', weight: 2, fill: false, dashArray: '3 3' })
        .bindTooltip(`Fits less well (Δ log-likelihood ${a.dlog_lik})`, { className: 'mm-tip' }).addTo(g)
    }
    L.circle([f.fix.lat, f.fix.lon], { pane: 'route', radius: f.fix.r95_m, color: '#4fd1ff', weight: 2, fillColor: '#4fd1ff', fillOpacity: 0.12 }).addTo(g)
    L.circleMarker([f.fix.lat, f.fix.lon], { pane: 'route', radius: 6, color: '#fff', weight: 2.5, fillColor: '#4fd1ff', fillOpacity: 1 })
      .bindTooltip(`<b>Skyline fix</b> · ±${Math.round(f.fix.r95_m)} m (95 %)<br>${Math.round(f.error_m)} m from where you really are`, { className: 'mm-tip', direction: 'top' }).addTo(g)
    L.marker([f.truth.lat, f.truth.lon], { pane: 'route', icon: L.divIcon({ className: '', iconSize: [18, 18], iconAnchor: [9, 9], html: '<div class="truth-x">✕</div>' }) })
      .bindTooltip("Where you really are (the simulation's truth)", { className: 'mm-tip', direction: 'top' }).addTo(g)
  }, [st.skyFix])

  // ------------------------------------------------------------------ the shrinking world (feature A3)
  const envRef = useRef({ canvas: null, layer: null, field: null, url: null })
  useEffect(() => {
    const m = map.current
    const R = envRef.current
    const e = st.envelope
    const g = groups.current.envelope
    if (!m) return undefined
    if (!e?.data) {
      if (R.layer) { m.removeLayer(R.layer); R.layer = null }
      g.clearLayers()
      R.field = null
      R.url = null
      return undefined
    }
    let alive = true
    const draw = () => {
      if (!R.canvas) R.canvas = document.createElement('canvas')
      const n = paintEnvelope(R.canvas, R.field, e.minutes)
      if (!R.layer) R.layer = new CanvasOverlay(R.canvas, e.data.bounds, { pane: 'overlays', interactive: false, zIndex: 50 }).addTo(m)
      const area = Math.round(n * e.data.cell_ha * 10) / 10
      const share = n / Math.max(1, e.data.walkable_cells)
      if (e.area_ha !== area) useStore.getState().set((s0) => ({ envelope: s0.envelope ? { ...s0.envelope, area_ha: area, share } : null }))
    }
    if (R.url !== e.data.needed_png) {
      R.url = e.data.needed_png
      decodeMinutes(e.data.needed_png).then((f) => { if (alive) { R.field = f; draw() } })
    } else if (R.field) draw()
    g.clearLayers()
    L.marker([e.lat, e.lon], { pane: 'route', zIndexOffset: 1200, icon: L.divIcon({ className: '', iconSize: [26, 26], iconAnchor: [13, 13], html: '<div class="crew-dot">EV</div>' }) })
      .bindTooltip(`<b>Crew with a suit leak</b><br>${Math.round(e.minutes)} min of oxygen left`, { className: 'mm-tip', direction: 'top', offset: [0, -12] }).addTo(g)
    for (const h of e.data.havens) {
      const ok = h.needs_min != null && h.needs_min <= e.minutes
      L.marker([h.lat, h.lon], { pane: 'route', zIndexOffset: 1100, interactive: false, icon: L.divIcon({ className: '', iconSize: [0, 0], html: '' }) })
        .bindTooltip(`${h.name} · ${ok ? 'IN REACH' : 'LOST'} · needs ${h.needs_min != null ? Math.round(h.needs_min) : '-'} min`, { permanent: true, direction: 'top', offset: [0, -16], className: `haven-tag ${ok ? 'ok' : 'lost'}` })
        .addTo(g)
    }
    return () => { alive = false }
  }, [st.envelope?.data, st.envelope?.minutes, st.envelope?.lon])

  // ------------------------------------------------------------------ partner down (feature B3)
  useEffect(() => {
    const g = groups.current.rescue
    g.clearLayers()
    const rc = st.rescueCheck
    if (!rc || rc.worst_lon == null) return
    if (rc.carry_path?.ok) {
      const ll = rc.carry_path.path.map(([lon, lat]) => [lat, lon])
      L.polyline(ll, { pane: 'route', color: '#000', weight: 7, opacity: 0.4, interactive: false }).addTo(g)
      L.polyline(ll, { pane: 'route', color: '#ff6b6b', weight: 3, dashArray: '2 7', lineCap: 'round' })
        .bindTooltip(`Buddy carry home: ${rc.carry_path.start_minutes} min (+ airlock)`, { sticky: true, className: 'mm-tip' }).addTo(g)
    }
    L.marker([rc.worst_lat, rc.worst_lon], { pane: 'route', zIndexOffset: 1300, icon: L.divIcon({ className: '', iconSize: [30, 30], iconAnchor: [15, 15], html: '<div class="down-dot">+</div>' }) })
      .bindTooltip(`<b>EV2 down here</b> · worst point of the route<br>${rc.worst_min} min to pressure by ${rc.worst_mode}`, { className: 'mm-tip', direction: 'top', permanent: true, offset: [0, -14] }).addTo(g)
  }, [st.rescueCheck])

  // ------------------------------------------------------------------ emergency caches (feature B4)
  useEffect(() => {
    const g = groups.current.caches
    g.clearLayers()
    const icon = (t, sug) => L.divIcon({ className: '', iconSize: [26, 26], iconAnchor: [13, 13], html: `<div class="cache-icon ${sug ? 'sug' : ''}">${t}</div>` })
    for (const c of st.caches || []) {
      const mk = L.marker([c.lat, c.lon], { draggable: true, zIndexOffset: 980, icon: icon('O2') })
        .bindTooltip(`<b>${c.name}</b> · emergency oxygen cache (a haven)<br><span style="opacity:.7">Drag to move</span>`, { className: 'mm-tip', direction: 'top', offset: [0, -12] })
      mk.on('dragend', (ev) => { const p = ev.target.getLatLng(); const s0 = useStore.getState(); s0.set({ caches: s0.caches.map((x) => (x.id === c.id ? { ...x, lon: p.lng, lat: p.lat } : x)) }); s0.saveMission() })
      mk.addTo(g)
    }
    for (const c of st.cacheSuggest?.caches || []) {
      L.marker([c.lat, c.lon], { zIndexOffset: 970, icon: icon('?', true) })
        .bindTooltip(`<b>Suggested ${c.name}</b> · +${Math.round(c.gain_share * 100)} % covered<br>${c.why}`, { className: 'mm-tip', direction: 'top', offset: [0, -12] }).addTo(g)
    }
  }, [st.caches, st.cacheSuggest])

  // ------------------------------------------------------------------ live crew, Earth's view, pushed waypoint, Ask Earth (D1, D2)
  useEffect(() => {
    const g = groups.current.live
    g.clearLayers()
    const lv = st.live
    const last = lv?.connected ? lv.last : null
    if (last?.lon != null) {
      const ev = earthView(lv.history, lv.lightTimeS)
      if (ev) {
        L.marker([ev.lat, ev.lon], { pane: 'route', zIndexOffset: 1250, interactive: true, icon: L.divIcon({ className: '', iconSize: [22, 22], iconAnchor: [11, 11], html: '<div class="earth-ghost">E</div>' }) })
          .bindTooltip(`As Earth sees the crew: ${Math.round((lv.lightTimeS || 0) / 60)} min late`, { className: 'mm-tip', direction: 'top' }).addTo(g)
      }
      L.marker([last.lat, last.lon], { pane: 'route', zIndexOffset: 1260, icon: L.divIcon({ className: '', iconSize: [30, 30], iconAnchor: [15, 15], html: `<div class="live-crew"><i style="transform:rotate(${Math.round(last.heading || 0)}deg)"></i><b>EV1</b></div>` }) })
        .bindTooltip(`<b>EV1 live</b>${last.source === 'simulated' ? ' (simulated)' : ''}<br>O2 ${Math.round(last.o2_pct ?? 0)} % · margin ${Math.round(last.margin_min ?? 0)} min`, { className: 'mm-tip', direction: 'top', offset: [0, -14] }).addTo(g)
    }
    if (lv?.connected && lv.waypoint) {
      L.marker([lv.waypoint.lat, lv.waypoint.lon], { pane: 'route', zIndexOffset: 1240, icon: L.divIcon({ className: '', iconSize: [26, 26], iconAnchor: [13, 13], html: '<div class="pushed-wp">WP</div>' }) })
        .bindTooltip(`${lv.waypoint.name} · in the visor`, { className: 'mm-tip', direction: 'top', permanent: true, offset: [0, -12] }).addTo(g)
    }
    const a = st.askEarth
    if (a && a.lon != null && isFinite(a.lon)) {
      L.marker([a.lat, a.lon], { pane: 'route', zIndexOffset: 1230, icon: L.divIcon({ className: '', iconSize: [24, 24], iconAnchor: [12, 12], html: '<div class="answer-dot">A</div>' }) })
        .bindTooltip(`Earth's answer arrives here (T+${Math.round(a.tAns / 60)} min): the crew is ${a.kind === 'walk' ? 'walking' : 'at'} ${a.where}`, { className: 'mm-tip', direction: 'top', permanent: true, offset: [0, -12] }).addTo(g)
    }
    const ew = st.earthWalk // walk it on Earth (feature F3): your GPS walk, drawn on Mars
    if (ew?.track?.length > 1) L.polyline(ew.track.map(([lon, lat]) => [lat, lon]), { pane: 'route', color: '#49e3a0', weight: 3.5, opacity: 0.95 }).addTo(g)
    if (ew?.mars) {
      if (ew.acc != null && ew.acc > 6) L.circle([ew.mars.lat, ew.mars.lon], { pane: 'route', radius: ew.acc, color: '#49e3a0', weight: 1, fillOpacity: 0.08, interactive: false }).addTo(g)
      L.marker([ew.mars.lat, ew.mars.lon], { pane: 'route', zIndexOffset: 1270, icon: L.divIcon({ className: '', iconSize: [34, 34], iconAnchor: [17, 17], html: '<div class="earth-walker"><b>YOU</b></div>' }) })
        .bindTooltip(`<b>You, walking on Earth</b>${ew.sim ? ' (simulated)' : ''}${ew.wb != null ? `<br>${ew.wb.toFixed(1)} min walk back` : ''}`, { className: 'mm-tip', direction: 'top', offset: [0, -16] }).addTo(g)
    }
  }, [st.live, st.askEarth, st.earthWalk])

  // ------------------------------------------------------------------ smart planner: autoplan preview, scout flight, tags, sketch (C1-C3, G3)
  useEffect(() => {
    const g = groups.current.smart
    g.clearLayers()
    const ap = st.autoplan
    for (const v of ap?.variants || []) {
      if (!v.plan?.path || (st.apPreview && st.apPreview !== v.id)) continue
      L.polyline(v.plan.path.map(([lon, lat]) => [lat, lon]), { pane: 'route', color: AP_COLORS[v.id], weight: 4, opacity: 0.95, dashArray: '8 6' })
        .bindTooltip(`${v.name}: science ${v.science}`, { className: 'mm-tip', sticky: true }).addTo(g)
      v.stops.forEach((s0, i) => L.circleMarker([s0.lat, s0.lon], { pane: 'route', radius: 7, color: '#fff', weight: 2, fillColor: AP_COLORS[v.id], fillOpacity: 1 })
        .bindTooltip(`${i + 1}. ${s0.name} · science ${s0.score}`, { className: 'mm-tip', direction: 'top' }).addTo(g))
    }
    const sc = st.scout
    for (const r of sc?.stretches || []) L.polyline(r.path.map(([lon, lat]) => [lat, lon]), { pane: 'route', color: '#ffb020', weight: 9, opacity: 0.55 }).bindTooltip(`Uncertain ${r.kind}: ${Math.round(r.length_m)} m`, { className: 'mm-tip', sticky: true }).addTo(g)
    for (const f of sc?.flight?.flights || []) L.polyline(f.path.map(([lon, lat]) => [lat, lon]), { pane: 'route', color: '#3ad6c6', weight: 2.5, dashArray: '3 6' }).bindTooltip(`Helicopter flight: ${Math.round(f.length_m)} m, ${Math.round(f.air_s)} s in the air (simulated scouting)`, { className: 'mm-tip', sticky: true }).addTo(g)
    for (const t of st.tags || []) {
      if (t.kind === 'hazard') L.circle([t.lat, t.lon], { pane: 'route', radius: t.radius_m, color: '#ff3b30', weight: 2, fillOpacity: 0.25 }).addTo(g)
      L.marker([t.lat, t.lon], { pane: 'route', icon: L.divIcon({ className: '', iconSize: [22, 22], iconAnchor: [11, 11], html: `<div class="tag-pin ${t.kind}">${t.kind === 'hazard' ? '!' : '★'}</div>` }) })
        .bindTooltip(`<b>${t.kind === 'hazard' ? 'Hazard' : 'Find'}</b> · ${t.note || ''} · by ${t.by}`, { className: 'mm-tip', direction: 'top' }).addTo(g)
    }
    const sk = st.sketch
    if (sk?.points?.length) {
      L.polyline(sk.points.map(([lon, lat]) => [lat, lon]), { pane: 'route', color: '#ff7a3d', weight: 3.5 }).addTo(g)
      sk.points.forEach(([lon, lat]) => L.circleMarker([lat, lon], { pane: 'route', radius: 4, color: '#fff', weight: 2, fillColor: '#ff7a3d', fillOpacity: 1 }).addTo(g))
      if (sk.result?.planner) L.polyline(sk.result.planner.path.map(([lon, lat]) => [lat, lon]), { pane: 'route', color: '#4cb0ff', weight: 3, dashArray: '6 5' }).bindTooltip('A* (the planner)', { className: 'mm-tip', sticky: true }).addTo(g)
    }
  }, [st.autoplan, st.apPreview, st.scout, st.tags, st.sketch])

  // ------------------------------------------------------------------ radio grid (feature G5)
  useEffect(() => {
    const g = groups.current.grid
    g.clearLayers()
    if (!st.vectors.grid) return undefined
    let alive = true
    api.gridLines(site.id).then((d) => {
      if (!alive) return
      for (const ln of d.lines) L.polyline(ln.map(([lon, lat]) => [lat, lon]), { pane: 'vectors', color: '#fff6e8', weight: 1, opacity: 0.55, dashArray: '4 4', interactive: false }).addTo(g)
      for (const c of d.col_labels) L.tooltip({ permanent: true, direction: 'bottom', className: 'grid-label', interactive: false, offset: [0, 4] }).setLatLng([c.lat, c.lon]).setContent(c.label).addTo(g)
      for (const r of d.row_labels) L.tooltip({ permanent: true, direction: 'right', className: 'grid-label', interactive: false, offset: [4, 0] }).setLatLng([r.lat, r.lon]).setContent(r.label).addTo(g)
    }).catch(() => {})
    return () => { alive = false }
  }, [st.vectors.grid, site.id])

  // ------------------------------------------------------------------ rover chemistry at the targets (feature E2)
  useEffect(() => {
    const g = groups.current.chem
    g.clearLayers()
    if (!st.vectors.chemistry || !site.chemistry) return undefined
    let alive = true
    api.chemistry(site.id).then((d) => {
      if (!alive) return
      for (const t of d.targets) {
        const tip = `<b>${t.name}</b> · sol ${t.sol} · ${d.instrument}, ${t.n_points} point${t.n_points === 1 ? '' : 's'}${t.dist_m ? ` at ${t.dist_m.toFixed(1)} m` : ''}`
          + `<br><span style="color:${t.color}">●</span> ${t.hint} · oxides, weight %${chemBarsHtml(t)}`
          + `<span style="opacity:.7">Placed where ${d.rover || 'the rover'} stood on sol ${t.sol} (${(d.instrument || 'the laser').split(' ')[0]} reaches ~7 m)</span>`
        L.circleMarker([t.lat, t.lon], { pane: 'vectors', radius: 4.5, color: '#1a0f08', weight: 1.2, fillColor: t.color, fillOpacity: 0.95, bubblingMouseEvents: false })
          .bindTooltip(tip, { className: 'mm-tip', direction: 'top' }).addTo(g)
      }
    }).catch(() => {})
    return () => { alive = false }
  }, [st.vectors.chemistry, site])

  // ------------------------------------------------------------------ ground radar under the rover's track (feature E1)
  const radarRuns = useRef([])
  useEffect(() => {
    const g = groups.current.radar
    g.clearLayers()
    radarRuns.current = []
    if (!st.vectors.radar || !site.radar) return undefined
    let alive = true
    api.radar(site.id).then((d) => {
      if (!alive) return
      radarRuns.current = d.runs
      for (const r of d.runs) {
        const ll = r.lon.map((lon, k) => [r.lat[k], lon])
        const tip = `<b>Ground radar</b> · sol ${r.sol} (${r.utc}) · ${Math.round(r.n * d.col_m)} m<br>`
          + `<span style="opacity:.75">What lies ${Math.round(d.depth_m)} m down under ${site.rover_name}'s wheels. Click to see it.</span>`
        const open = (e) => {
          L.DomEvent.stop(e)
          let best = 0, bd = Infinity
          for (let k = 0; k < r.n; k++) {
            const dd = (r.lat[k] - e.latlng.lat) ** 2 + ((r.lon[k] - e.latlng.lng) * Math.cos(r.lat[k] * Math.PI / 180)) ** 2
            if (dd < bd) { bd = dd; best = k }
          }
          useStore.getState().set({ radarView: { run: r.run, i: best, cursor: best } })
        }
        L.polyline(ll, { pane: 'vectors', color: '#04121a', weight: 7, opacity: 0.55, interactive: false }).addTo(g)
        L.polyline(ll, { pane: 'vectors', color: '#7fe3ff', weight: 3.2, opacity: 0.95, bubblingMouseEvents: false })
          .bindTooltip(tip, { className: 'mm-tip', direction: 'top', sticky: true }).on('click', open).addTo(g)
      }
    }).catch(() => {})
    return () => { alive = false }
  }, [st.vectors.radar, site])

  // ------------------------------------------------------------------ the rover's photos where they were taken (feature E3)
  useEffect(() => {
    const g = groups.current.views
    g.clearLayers()
    if (!st.vectors.photoviews) return undefined
    let alive = true
    api.thenNow(site.id).then((d) => {
      if (!alive) return
      const R = 150 // m: length of a view cone on the map
      for (const p of d.photos) {
        const mLat = 1 / 59274.0
        const mLon = 1 / (59274.0 * Math.cos((p.lat * Math.PI) / 180))
        const pts = [[p.lat, p.lon]]
        for (let k = 0; k <= 14; k++) {
          const a = ((p.az - p.hfov / 2 + (k / 14) * p.hfov) * Math.PI) / 180
          pts.push([p.lat + Math.cos(a) * R * mLat, p.lon + Math.sin(a) * R * mLon])
        }
        const tip = `<b>${d.rover}'s ${p.camera}</b> · sol ${Math.round(p.sol)}<br>looking ${Math.round(p.az)}° ${compass(p.az)}, ${Math.round(p.hfov)}° wide, camera ${p.cam_h_m} m up`
          + `<br><img src="${p.thumb}" referrerpolicy="no-referrer" style="width:220px;border-radius:4px;margin-top:4px">`
          + `<br><span style="opacity:.7">Click to open. In the 3D console, Shift+P stands you here.</span>`
        const open = (e) => { L.DomEvent.stop(e); useStore.getState().set({ photoBox: { ...p, rover: d.rover } }) }
        L.polygon(pts, { pane: 'vectors', color: '#ffd27a', weight: 1.2, opacity: 0.9, fillColor: '#ffd27a', fillOpacity: 0.16, bubblingMouseEvents: false })
          .bindTooltip(tip, { className: 'mm-tip', direction: 'top', sticky: true }).on('click', open).addTo(g)
        L.circleMarker([p.lat, p.lon], { pane: 'vectors', radius: 4, color: '#1a1208', weight: 1.2, fillColor: '#ffd27a', fillOpacity: 1, bubblingMouseEvents: false })
          .on('click', open).addTo(g)
      }
    }).catch(() => {})
    return () => { alive = false }
  }, [st.vectors.photoviews, site])

  // the column under the radargram viewer's cursor, on the map
  useEffect(() => {
    const g = groups.current.radarCursor
    g.clearLayers()
    const v = st.radarView
    if (!v) return
    const r = radarRuns.current.find((x) => x.run === v.run)
    if (!r) return
    const k = Math.max(0, Math.min(r.n - 1, v.cursor ?? v.i))
    L.polyline(r.lon.map((lon, j) => [r.lat[j], lon]), { pane: 'vectors', color: '#ffffff', weight: 5, opacity: 0.35, interactive: false }).addTo(g)
    L.circleMarker([r.lat[k], r.lon[k]], { pane: 'vectors', radius: 7, color: '#04121a', weight: 2, fillColor: '#ffc46e', fillOpacity: 1, interactive: false }).addTo(g)
  }, [st.radarView, st.vectors.radar])

  // ------------------------------------------------------------------ Ingenuity's flights (Jezero)
  useEffect(() => {
    let alive = true
    const g = groups.current.heli
    g.clearLayers()
    if (!st.vectors.ingenuity || !(site.files || []).includes('ingenuity.geojson')) return undefined
    const pick = (n) => useStore.getState().set({ heliFlight: n, panel: 'rover' })
    fetch(api.file(site.id, 'ingenuity.geojson')).then((r) => r.json()).then((fc) => {
      if (!alive) return
      for (const f of fc.features) {
        const p = f.properties
        const sel = st.heliFlight === p.flight
        const tip = `<b>Ingenuity flight ${p.flight}</b> · sol ${p.sol}${p.earth_date ? ` (${p.earth_date})` : ''}<br>${fmtDist(p.length_m)} at up to ${p.max_alt_m} m · ${Math.round(p.duration_s)} s in the air${p.from ? `<br>${p.from} → ${p.to}` : ''}<br><span style="opacity:.7">Click for its photos</span>`
        if (p.kind === 'flight') {
          const ll = f.geometry.coordinates.map(([lon, lat]) => [lat, lon])
          L.polyline(ll, { pane: 'vectors', color: '#062a33', weight: sel ? 7 : 5, opacity: 0.45, interactive: false }).addTo(g)
          L.polyline(ll, { pane: 'vectors', color: sel ? '#ffffff' : '#3ad6c6', weight: sel ? 3.5 : 2.4, opacity: p.in_site ? 0.95 : 0.5, dashArray: '2 6', lineCap: 'round', bubblingMouseEvents: false })
            .bindTooltip(tip, { className: 'mm-tip', sticky: true }).on('click', () => pick(p.flight)).addTo(g)
        } else {
          const [lon, lat] = f.geometry.coordinates
          L.marker([lat, lon], { pane: 'vectors', icon: L.divIcon({ className: '', html: `<div class="heli-pad ${sel ? 'sel' : ''}">${p.flight}</div>`, iconSize: [22, 22], iconAnchor: [11, 11] }) })
            .bindTooltip(tip, { className: 'mm-tip', direction: 'top' }).on('click', () => pick(p.flight)).addTo(g)
        }
      }
    }).catch(() => {})
    return () => { alive = false }
  }, [st.vectors.ingenuity, st.heliFlight, site])

  // ------------------------------------------------------------------ suggested science stops
  useEffect(() => {
    const g = groups.current.suggest
    g.clearLayers()
    if (!st.vectors.suggestions || !st.suggestions) return
    for (const sg of st.suggestions) {
      L.marker([sg.lat, sg.lon], { icon: L.divIcon({ className: '', html: `<div class="sug-pin">${sg.name.slice(-1)}</div>`, iconSize: [26, 26], iconAnchor: [13, 13] }), zIndexOffset: 800 })
        .bindTooltip(`<b>Suggested: ${sg.name}</b> · science ${sg.score.toFixed(2)}<br>${sg.reasons.slice(0, 3).map((r) => `• ${r.text}`).join('<br>')}<br>${sg.walkback_min} min walk back · slope ${sg.slope}°${sg.unit ? ` · ${sg.unit.code}` : ''}<br><span style="opacity:.7">Click to add it to the route</span>`, { className: 'mm-tip', direction: 'top' })
        .on('click', () => { const s0 = useStore.getState(); s0.acceptSuggestion(sg); s0.notify(`Added ${sg.name} to the route`, 'ok') })
        .addTo(g)
    }
  }, [st.suggestions, st.vectors.suggestions])

  // ------------------------------------------------------------------ static vectors (from files)
  useEffect(() => {
    let alive = true
    const g = groups.current
    g.traverse.clearLayers()
    g.waypoints.clearLayers()
    g.contours.clearLayers()
    g.extras.clearLayers()
    const files = site.files || []
    if (st.vectors.traverse && files.includes('rover_traverse.geojson')) {
      fetch(api.file(site.id, 'rover_traverse.geojson')).then((r) => r.json()).then((fc) => {
        if (!alive) return
        L.geoJSON(fc, { pane: 'vectors', style: { color: '#000', weight: 6, opacity: 0.35 } }).addTo(g.traverse)
        L.geoJSON(fc, { pane: 'vectors', style: { color: '#ffb36b', weight: 2.5, opacity: 0.95, dashArray: '6 6' } })
          .bindTooltip(`${site.rover_name}'s actual path`, { className: 'mm-tip', sticky: true }).addTo(g.traverse)
        if (site.rover.latest_lonlat) {
          const [lon, lat] = site.rover.latest_lonlat
          L.marker([lat, lon], { icon: mini('rover', SVG.rover), pane: 'vectors' })
            .bindTooltip(`${site.rover_name} · sol ${site.rover.latest_sol} (latest)`, { className: 'mm-tip', direction: 'top' }).addTo(g.traverse)
        }
      })
    }
    if (st.vectors.waypoints && files.includes('rover_waypoints.geojson')) {
      fetch(api.file(site.id, 'rover_waypoints.geojson')).then((r) => r.json()).then((fc) => {
        if (!alive) return
        L.geoJSON(fc, {
          pane: 'vectors',
          pointToLayer: (f, ll) => L.circleMarker(ll, { radius: 4, color: '#1d0c03', weight: 1.5, fillColor: '#ffb36b', fillOpacity: 1 })
            .bindTooltip(`Sol ${f.properties.sol} · ${fmtDist(f.properties.dist_total_m)} driven`, { className: 'mm-tip', direction: 'top' }),
        }).addTo(g.waypoints)
      })
    }
    if (st.vectors.contours && files.includes('contours.geojson')) {
      fetch(api.file(site.id, 'contours.geojson')).then((r) => r.json()).then((fc) => {
        if (!alive) return
        L.geoJSON(fc, {
          pane: 'overlays', interactive: false,
          style: (f) => ({ color: f.properties.index ? '#fff6e8' : '#fff6e8', weight: f.properties.index ? 1.3 : 0.6, opacity: f.properties.index ? 0.7 : 0.35 }),
        }).addTo(g.contours)
      })
    }
    for (const ex of site.rover.extras || []) {
      if (!st.vectors.traverse) continue
      fetch(api.file(site.id, `extra_${ex.id}.geojson`)).then((r) => r.json()).then((fc) => {
        if (!alive) return
        L.geoJSON(fc, {
          pane: 'vectors',
          style: { color: '#9ef0ff', weight: 1.8, opacity: 0.85, dashArray: '2 5' },
          pointToLayer: (f, ll) => L.circleMarker(ll, { radius: 5, color: '#062a33', weight: 1.5, fillColor: '#9ef0ff', fillOpacity: 1 }),
          onEachFeature: (f, layer) => layer.bindTooltip(`${ex.name}: ${Object.values(f.properties || {}).filter(Boolean).slice(0, 3).join(' · ')}`, { className: 'mm-tip' }),
        }).addTo(g.extras)
      }).catch(() => {})
    }
    return () => { alive = false }
  }, [st.vectors.traverse, st.vectors.waypoints, st.vectors.contours, site])

  // ------------------------------------------------------------------ route, rings, compare
  useEffect(() => {
    const g = groups.current
    g.route.clearLayers()
    g.rings.clearLayers()
    const plan = st.plan
    if (!plan) return
    if (st.vectors.rings && plan.rings) {
      for (const f of plan.rings.features) {
        const min = f.properties.minutes
        const lines = f.geometry.coordinates.map((line) => line.map(([lon, lat]) => [lat, lon]))
        L.polyline(lines, { pane: 'vectors', color: '#000', weight: 4, opacity: 0.35, interactive: false }).addTo(g.rings)
        const pl = L.polyline(lines, { pane: 'vectors', color: RING_COLORS[min] || '#fff', weight: 2, opacity: 0.95, dashArray: min % 30 === 0 ? null : '4 5' }).addTo(g.rings)
        pl.bindTooltip(`${min} min walk back to ${plan.rover?.enabled ? `${plan.rover.name} (parked)` : 'the hab'}`, { className: 'mm-tip', sticky: true })
        const longest = lines.reduce((a, b) => (b.length > a.length ? b : a), [])
        if (longest.length > 10) {
          L.tooltip({ permanent: true, direction: 'center', className: 'ring-label', interactive: false })
            .setLatLng(longest[Math.floor(longest.length * 0.3)]).setContent(`${min}′`).addTo(g.rings)
        }
      }
    }
    if (st.vectors.route && plan.rover?.enabled) {
      for (const leg of plan.rover.legs) {  // PR-2 drives: dark casing, green dashes
        const ll = leg.path.map(([lon, lat]) => [lat, lon])
        L.polyline(ll, { pane: 'route', color: '#061224', weight: 8, opacity: 0.5, lineJoin: 'round', interactive: false }).addTo(g.route)
        L.polyline(ll, { pane: 'route', color: '#4ade80', weight: 3.5, opacity: 1, dashArray: '9 7', lineJoin: 'round' })
          .bindTooltip(`${plan.rover.name} drive · ${leg.from} → ${leg.to}: ${fmtDist(leg.dist_m)}, ${Math.round(leg.time_s / 60)} min in the cab · steepest ${leg.max_slope}°`, { className: 'mm-tip', sticky: true })
          .addTo(g.route)
      }
    }
    if (st.vectors.route) {
      plan.legs.forEach((leg, i) => {
        const ll = leg.path.map(([lon, lat]) => [lat, lon])
        L.polyline(ll, { pane: 'route', color: '#061224', weight: 8, opacity: 0.55, lineJoin: 'round', interactive: false }).addTo(g.route)
        const core = L.polyline(ll, { pane: 'route', color: '#4cb0ff', weight: 3.5, opacity: 1, lineJoin: 'round' }).addTo(g.route)
        core.bindTooltip(`${leg.from} → ${leg.to}: ${fmtDist(leg.dist_m)}, ${Math.round(leg.time_s / 60)} min, heading ${Math.round(leg.bearing_deg)}° ${compass(leg.bearing_deg)}`, { className: 'mm-tip', sticky: true })
        // direction chevron at the middle of each leg
        const mid = Math.floor(ll.length / 2)
        if (ll.length > 3) {
          const a = ll[mid - 1]
          const b = ll[Math.min(ll.length - 1, mid + 1)]
          const ang = bearingDeg({ lat: a[0], lon: a[1] }, { lat: b[0], lon: b[1] })
          L.marker(ll[mid], { pane: 'route', interactive: false, icon: L.divIcon({ className: '', iconSize: [18, 18], iconAnchor: [9, 9], html: `<div style="transform:rotate(${ang}deg);width:18px;height:18px;display:grid;place-items:center"><svg width="14" height="14" viewBox="0 0 24 24"><path d="M12 3 20 19 12 15 4 19z" fill="#fff" stroke="#061224" stroke-width="2"/></svg></div>` }) }).addTo(g.route)
        }
        void i
      })
    }
  }, [st.plan, st.vectors.route, st.vectors.rings])

  useEffect(() => {
    const g = groups.current
    g.compare.clearLayers()
    const c = st.compare
    if (!c?.show) return
    for (const r of c.results) {
      if (!r.ok) continue
      const ll = r.path.map(([lon, lat]) => [lat, lon])
      const color = r.engine === 'astar' ? '#4fd1ff' : '#ff5fa2'
      L.polyline(ll, { pane: 'route', color: '#000', weight: 7, opacity: 0.4, interactive: false }).addTo(g.compare)
      L.polyline(ll, { pane: 'route', color, weight: 3, opacity: 1, dashArray: r.engine === 'astar' ? null : '7 6' })
        .bindTooltip(`${r.engine === 'astar' ? 'A* (ours)' : 'Dijkstra (MCP)'}: ${Math.round(r.time_s / 60)} min, ${fmtDist(r.dist_m)}`, { className: 'mm-tip', sticky: true })
        .addTo(g.compare)
    }
  }, [st.compare])

  // ------------------------------------------------------------------ markers
  useEffect(() => {
    const g = groups.current.markers
    g.clearLayers()
    const riding = st.rover?.enabled
    const drop = riding ? (st.rover.dropoff || st.plan?.rover?.dropoff) : null
    if (drop) {  // PR-2 parked at the drop-off: drag to place it by hand
      const mk = L.marker([drop.lat, drop.lon], { icon: prIcon(!!st.rover.dropoff), draggable: true, zIndexOffset: 950 })
        .bindTooltip(`<b>PR-2 drop-off</b> (${st.rover.dropoff ? 'placed by hand' : 'automatic'})<br>Suitport egress here · storm shelter and radio relay while parked<br><span style="opacity:.7">Drag to move</span>`, { className: 'mm-tip', direction: 'top', offset: [0, -12] })
      mk.on('dragend', (e) => { const p = e.target.getLatLng(); const s0 = useStore.getState(); s0.set({ rover: { ...s0.rover, dropoff: { lon: p.lng, lat: p.lat } } }) })
      mk.addTo(g)
    }
    if (st.vectors.shelters) {
      for (const sh of site.shelters || []) {
        if (riding && sh.kind === 'rover') continue  // it is out at the drop-off
        L.marker([sh.lat, sh.lon], { icon: mini('shelter', SVG.shield), pane: 'vectors' })
          .bindTooltip(`<b>${sh.name}</b><br>${sh.note || ''}`, { className: 'mm-tip', direction: 'top' }).addTo(g)
      }
    }
    if (st.vectors.refuges) {
      for (const rf of site.refuges || []) {
        L.marker([rf.lat, rf.lon], { icon: mini('refuge', SVG.refuge), pane: 'vectors' })
          .bindTooltip(`Terrain refuge: blocks ${(rf.shield * 100).toFixed(0)} % of cosmic-ray dose (partial shelter only)`, { className: 'mm-tip', direction: 'top' }).addTo(g)
      }
    }
    if (st.vectors.relays) {
      for (const r of st.relays) {
        const mk = L.marker([r.lat, r.lon], { icon: mini('relay', SVG.radio), draggable: true, pane: 'vectors' })
          .bindTooltip(`Relay ${r.id} · ${r.height_m} m mast (drag to move)`, { className: 'mm-tip', direction: 'top' })
        mk.on('dragend', (e) => { const p = e.target.getLatLng(); useStore.getState().updateRelay(r.id, { lon: p.lng, lat: p.lat }) })
        mk.addTo(g)
      }
    }
    if (st.vectors.stops) {
      const hab = L.marker([st.habitat.lat, st.habitat.lon], { icon: habIcon, draggable: true, zIndexOffset: 900 })
        .bindTooltip(`<b>${st.habitat.name || 'Habitat'}</b><br>Radio mast ${st.radio.habitat_mast_m} m · primary radiation shelter<br><span style="opacity:.7">Drag to move</span>`, { className: 'mm-tip', direction: 'top', offset: [0, -18] })
      hab.on('dragend', (e) => { const p = e.target.getLatLng(); useStore.getState().set({ habitat: { ...useStore.getState().habitat, lon: p.lng, lat: p.lat } }) })
      hab.addTo(g)
      st.stops.forEach((sp, i) => {
        const mk = L.marker([sp.lat, sp.lon], { icon: pinIcon(i + 1, st.selectedStop === sp.id), draggable: true, zIndexOffset: 1000 })
          .bindTooltip(`<b>${i + 1}. ${sp.name}</b><br>${sp.dwell_min} min · ${(sp.tasks || []).slice(0, 2).join(', ')}`, { className: 'mm-tip', direction: 'top', offset: [0, -30] })
        mk.on('dragend', (e) => { const p = e.target.getLatLng(); useStore.getState().updateStop(sp.id, { lon: p.lng, lat: p.lat }) })
        mk.on('click', () => useStore.getState().set({ selectedStop: sp.id, panel: 'mission' }))
        mk.addTo(g)
      })
    }
  }, [st.stops, st.habitat, st.relays, st.selectedStop, st.vectors.stops, st.vectors.shelters, st.vectors.refuges, st.vectors.relays, st.radio, site, st.rover, st.plan?.rover?.dropoff])

  // ------------------------------------------------------------------ hover sync with charts
  useEffect(() => {
    const g = groups.current.hover
    g.clearLayers()
    const p = st.plan?.profile
    if (!p || st.hoverD == null) return
    const lon = interp(p.d, p.lon, st.hoverD)
    const lat = interp(p.d, p.lat, st.hoverD)
    L.marker([lat, lon], { icon: L.divIcon({ className: '', html: '<div class="hover-dot"></div>', iconSize: [14, 14], iconAnchor: [7, 7] }), interactive: false, zIndexOffset: 2000 }).addTo(g)
  }, [st.hoverD, st.plan])

  // ------------------------------------------------------------------ measure tool
  useEffect(() => {
    const g = groups.current.measure
    g.clearLayers()
    if (st.tool !== 'measure') return
    measure.forEach((p) => L.circleMarker([p.lat, p.lon], { radius: 5, color: '#fff', fillColor: '#ffb020', fillOpacity: 1, weight: 2 }).addTo(g))
    if (measure.length === 2) {
      const [a, b] = measure
      const d = distanceM(a, b)
      const brg = bearingDeg(a, b)
      L.polyline([[a.lat, a.lon], [b.lat, b.lon]], { color: '#ffb020', weight: 2.5, dashArray: '6 4' })
        .bindTooltip(`${fmtDist(d)} · ${Math.round(brg)}° ${compass(brg)}`, { permanent: true, className: 'mm-tip', direction: 'center' }).addTo(g)
    }
  }, [measure, st.tool])
  useEffect(() => { if (st.tool !== 'measure') setMeasure([]) }, [st.tool])

  // ------------------------------------------------------------------ fly to focus
  useEffect(() => {
    if (st.focus && map.current) map.current.flyTo([st.focus.lat, st.focus.lon], Math.max(map.current.getZoom(), 17), { duration: 0.8 })
  }, [st.focus])

  // ------------------------------------------------------------------ cursor readout (throttled terrain query)
  const [readout, setReadout] = useState(null)
  useEffect(() => {
    if (!cursor) return
    const ctrl = new AbortController()
    const t = setTimeout(() => {
      api.query(site.id, { lon: cursor.lon, lat: cursor.lat }, ctrl.signal).then((q) => setReadout(q)).catch(() => {})
    }, 120)
    return () => { clearTimeout(t); ctrl.abort() }
  }, [cursor, site.id])

  const tools = [
    { id: 'select', icon: MousePointer2, label: 'Inspect' },
    { id: 'add-stop', icon: Plus, label: 'Add stop' },
    { id: 'move-hab', icon: Home, label: 'Move hab' },
    { id: 'add-relay', icon: RadioTower, label: 'Relay' },
    { id: 'measure', icon: Ruler, label: 'Measure' },
  ]
  const hints = { 'add-stop': 'Click to place a new stop', 'move-hab': 'Click to move the habitat', 'add-relay': 'Click to place a radio relay', measure: 'Click two points to measure distance and bearing',
    skyfix: 'Click where you really stand: the helmet fixes its position from the skyline there',
    crew: 'Click where the crew is when the leak starts', 'push-wp': 'Click where the helmet should go: the waypoint appears in the visor',
    'tag-hazard': 'Click the hazard: routing will keep 6 m clear of it', 'tag-find': 'Click the find: it becomes a candidate stop',
    sketch: 'Click points along your route, then Score it in the Smart planner', ...extraHints }

  return (
    <>
      <div ref={el} style={{ position: 'absolute', inset: 0, cursor: st.tool === 'select' ? '' : 'crosshair' }} />
      <div className="map-toolbar" role="toolbar" aria-label="Map tools">
        {tools.map(({ id, icon: Icon, label }) => (
          <button key={id} className={`btn sm ${st.tool === id ? 'on' : ''}`} onClick={() => st.set({ tool: st.tool === id && id !== 'select' ? 'select' : id })} title={label}>
            <Icon size={14} /> {label}
          </button>
        ))}
        <button className="btn sm" onClick={() => map.current?.flyToBounds(L.latLngBounds(site.bounds).pad(-0.05), { duration: 0.7 })} title="Fit the site"><Maximize size={14} /></button>
      </div>
      {hints[st.tool] && <div className="tool-hint">{hints[st.tool]} · Esc to cancel</div>}
      <KeyHandler />
      {cursor && (
        <div className="statusbar">
          <span>{fmtLonLat(cursor.lon, cursor.lat)}</span>
          {readout?.inside && (
            <>
              <span>elev <b>{readout.elev?.toFixed(1)} m</b></span>
              <span>slope <b>{readout.slope?.toFixed(1)}°</b></span>
              <span>rough <b>{readout.rough?.toFixed(2)} m</b></span>
              <span>shield <b>{((readout.shield || 0) * 100).toFixed(1)} %</b></span>
            </>
          )}
          <span>dist to hab <b>{fmtDist(distanceM(cursor, st.habitat))}</b></span>
        </div>
      )}
      {ctx && (
        <div className="ctx-menu" style={{ left: ctx.x, top: ctx.y }} onMouseLeave={() => setCtx(null)}>
          <div className="ctx-head">{fmtLonLat(ctx.lon, ctx.lat)}</div>
          <button onClick={() => { st.addStop(ctx.lon, ctx.lat); setCtx(null) }}><Plus size={14} /> Add stop here</button>
          <button onClick={() => { st.set({ habitat: { ...st.habitat, lon: ctx.lon, lat: ctx.lat } }); setCtx(null) }}><Home size={14} /> Move habitat here</button>
          <button onClick={() => { st.addRelay(ctx.lon, ctx.lat); setCtx(null) }}><RadioTower size={14} /> Place radio relay here</button>
          <button onClick={() => { inspect(ctx.lon, ctx.lat); setCtx(null) }}><Crosshair size={14} /> Inspect this point</button>
          <button onClick={() => { navigator.clipboard?.writeText(`${ctx.lat.toFixed(6)}, ${ctx.lon.toFixed(6)}`); st.notify('Coordinates copied', 'ok'); setCtx(null) }}><Ruler size={14} /> Copy coordinates</button>
        </div>
      )}
    </>
  )
}

function KeyHandler() {
  useEffect(() => {
    const onKey = (e) => {
      if (e.key === 'Escape') useStore.getState().set({ tool: 'select' })
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])
  return null
}
