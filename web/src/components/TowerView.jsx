import React, { useEffect, useMemo, useRef, useState } from 'react'
import { Layers3, MousePointerClick, Shrink, Expand } from 'lucide-react'
import { api, obsString, qs, walkParams } from '../api.js'
import { havensList, havensParam, useStore } from '../store.js'
import { makeGrid } from '../lib/geo.js'
import { fmtLonLat, fmtNum } from '../lib/format.js'

// Layer tower (feature A2): the brief asks for "a layered, integrated view", so show it literally. Every sheet
// is a real layer of this site, stacked with its mission and instrument; they lift off into a tower and fall
// back into one surface. The data core is a needle through the stack with the value at each layer.

const KIND_COLOR = {
  OPTICAL: '#ffcf9e', TOPOGRAPHIC: '#9fe3a5', THERMAL: '#ff9a6b', SPECTRAL: '#9ec5ff', GEOLOGY: '#e7c6ff',
  'DERIVED · HAZARD': '#ffd75e', 'DERIVED · SCIENCE': '#ff8fd0', 'INTEGRATED · THE PLAN': '#fff1d6',
}
const HAZ = ['easy', 'moderate', 'difficult', 'hazardous', 'no-go']

function coreValue(id, q, site) {
  if (!q) return '…'
  if (!q.inside) return 'outside the site'
  if (id === 'optical') return `${site.basemap?.name?.match(/\(([^)]+)\)/)?.[1] || '25 cm'} pixels`
  if (id === 'elevation') return `${fmtNum(q.elev, 1)} m`
  if (id === 'thermal') return q.thermal != null ? `night IR ${fmtNum(q.thermal, 0)} (rel.)` : '—'
  if (id.startsWith('crism_')) {
    const c = q.crism?.[id.slice(6)]
    return c ? (c.dominant && c.strength > 0.25 ? `${c.dominant} · ${fmtNum(c.strength * 100)} %` : 'no strong signal') : '—'
  }
  if (id === 'geology') return q.geology ? `${q.geology.code} · ${q.geology.name}` : '—'
  if (id === 'hazard') return `slope ${fmtNum(q.slope, 1)}°${q.slope_unc != null ? ` ± ${fmtNum(q.slope_unc, 1)}°` : ''} · sand ${fmtNum((q.sand || 0) * 100)} % · ${HAZ[q.hazard] || ''}`
  if (id === 'science') return q.science != null ? `score ${fmtNum(q.science, 2)}${q.science_info?.reasons?.[0] ? ` · ${q.science_info.reasons[0].kind}` : ''}` : '—'
  if (id === 'ways_home') return q.walkback_min != null ? `${fmtNum(q.walkback_min, 1)} min home · walkable` : 'no way home'
  return '—'
}

export default function TowerView() {
  const site = useStore((s) => s.site)
  const plan = useStore((s) => s.plan)
  const stops = useStore((s) => s.stops)
  const habitat = useStore((s) => s.habitat)
  const walk = useStore((s) => s.walk)
  const radio = useStore((s) => s.radio)
  const relays = useStore((s) => s.relays)
  const selectedStop = useStore((s) => s.selectedStop)
  const havensKey = useStore((s) => havensParam(havensList(s)))
  const stageRef = useRef(null)
  const [box, setBox] = useState({ w: 1200, h: 800 })
  const [sheets, setSheets] = useState([])
  const [loaded, setLoaded] = useState(0)
  const [spread, setSpread] = useState(0)
  const [yaw, setYaw] = useState(-45)
  const [tilt, setTilt] = useState(56)
  const [gapK, setGapK] = useState(1)
  const [core, setCore] = useState(null)
  const [coreQ, setCoreQ] = useState(null)
  const [hover, setHover] = useState(null)
  const drag = useRef(null)

  const g1 = useMemo(() => makeGrid(site.grid), [site])
  const toFrac = (lon, lat) => {
    const [x, y] = g1.toXY(lon, lat)
    return [(x - g1.x_min) / (g1.width * g1.res), (g1.y_max - y) / (g1.height * g1.res)]
  }
  const fromFrac = (fx, fy) => g1.toLonLat(g1.x_min + fx * g1.width * g1.res, g1.y_max - fy * g1.height * g1.res)

  // stage size
  useEffect(() => {
    const el = stageRef.current
    const ro = new ResizeObserver(() => setBox({ w: el.clientWidth, h: el.clientHeight }))
    ro.observe(el)
    setBox({ w: el.clientWidth, h: el.clientHeight })
    return () => ro.disconnect()
  }, [])

  // the sheets, their pictures (preloaded so the lift-off starts with every sheet drawn)
  const params = { havens: havensKey, ...walkParams(walk) }
  const urlFor = (id) => `/api/sites/${site.id}/tower/${id}.jpg?${qs({ size: 1024, ...params })}`
  useEffect(() => {
    let alive = true
    setSpread(0)
    setLoaded(0)
    fetch(`/api/sites/${site.id}/tower`).then((r) => r.json()).then((d) => {
      if (!alive) return
      const list = Array.isArray(d?.sheets) ? d.sheets : []
      setSheets(list)
      let n = 0
      list.forEach((sh) => {
        const img = new Image()
        img.onload = img.onerror = () => { n += 1; if (alive) setLoaded(n) }
        img.src = urlFor(sh.id)
      })
    }).catch(() => {})
    return () => { alive = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [site.id, havensKey, JSON.stringify(walkParams(walk))])
  const ready = sheets.length > 0 && loaded >= sheets.length
  useEffect(() => {
    if (!ready) return undefined
    const t = setTimeout(() => setSpread(1), 450) // lift-off
    return () => clearTimeout(t)
  }, [ready])

  // the data core: the selected stop, else the first stop, else the hab
  useEffect(() => {
    if (core) return
    const st = stops.find((x) => x.id === selectedStop) || stops[0]
    const p = st || habitat
    if (p) setCore({ lon: p.lon, lat: p.lat, name: st?.name || 'Hab' })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stops, habitat])
  useEffect(() => {
    if (!core) return undefined
    const ctrl = new AbortController()
    setCoreQ(null)
    api.query(site.id, { lon: core.lon, lat: core.lat, hab_lon: habitat.lon, hab_lat: habitat.lat, obs: obsString(habitat, radio, relays), ...walkParams(walk) }, ctrl.signal)
      .then(setCoreQ).catch(() => {})
    return () => ctrl.abort()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [core, site.id])

  const N = sheets.length || 1
  const S = Math.max(220, Math.min(box.h / 1.85, box.w * 0.34))
  const gap = S * 0.15 * gapK
  const zOf = (i) => (spread ? (i - (N - 1) / 2) * gap : (i - (N - 1) / 2) * 0.6)
  const bill = `rotateZ(${-yaw}deg) rotateX(${-tilt}deg)`

  // drag to turn and tilt; a click (no drag) on a sheet moves the data core there
  const onDown = (e) => { drag.current = { x: e.clientX, y: e.clientY, yaw, tilt, moved: false } }
  const onMove = (e) => {
    const d = drag.current
    if (!d) return
    const dx = e.clientX - d.x
    const dy = e.clientY - d.y
    if (Math.abs(dx) + Math.abs(dy) > 4) d.moved = true
    if (d.moved) {
      setYaw(d.yaw + dx * 0.3)
      setTilt(Math.max(30, Math.min(72, d.tilt - dy * 0.15)))
    }
  }
  const onUp = () => { setTimeout(() => { drag.current = null }, 0) }
  const onSheetClick = (e) => {
    if (drag.current?.moved || !spread) return
    if (!e.target.classList.contains('tower-sheet')) return
    const fx = e.nativeEvent.offsetX / S
    const fy = e.nativeEvent.offsetY / S
    if (fx < 0 || fy < 0 || fx > 1 || fy > 1) return
    const [lon, lat] = fromFrac(fx, fy)
    setCore({ lon, lat, name: null })
  }
  const onWheel = (e) => setGapK((k) => Math.max(0.45, Math.min(1.8, k * (e.deltaY > 0 ? 0.92 : 1.08))))

  const cf = core ? toFrac(core.lon, core.lat) : null
  const [pts, setPts] = useState([])
  useEffect(() => {
    let raf
    let last = ''
    const tick = () => {
      raf = requestAnimationFrame(tick)
      const st = stageRef.current
      if (!st) return
      const o = st.getBoundingClientRect()
      const els = [...st.querySelectorAll('.core-anchor')].sort((a, b) => +a.dataset.i - +b.dataset.i)
      const next = els.map((e) => { const r = e.getBoundingClientRect(); return { x: Math.round((r.left + r.right) / 2 - o.left), y: Math.round((r.top + r.bottom) / 2 - o.top) } })
      const key = next.map((p) => `${p.x},${p.y}`).join(' ')
      if (key !== last) { last = key; setPts(next) }
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [])
  const route = plan?.legs?.flatMap((L) => L.path) || []
  const routeD = route.map(([lon, lat], i) => { const [fx, fy] = toFrac(lon, lat); return `${i ? 'L' : 'M'}${(fx * 1000).toFixed(1)},${(fy * 1000).toFixed(1)}` }).join(' ')

  return (
    <div className="tower-stage" ref={stageRef} onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp} onPointerLeave={onUp} onWheel={onWheel}>
      <div className="tower-head">
        <div className="tower-title"><Layers3 size={18} /> LAYER TOWER</div>
        <div className="tower-sub">{site.name} — every sheet is real data from this project</div>
      </div>
      {!ready && <div className="tower-loading">Lifting {sheets.length || ''} layers off the terrain… {loaded}/{sheets.length || '…'}</div>}
      <div className="tower-scene" style={{ width: S, height: S, marginLeft: -S / 2, marginTop: -S / 2, transform: `rotateX(${tilt}deg) rotateZ(${yaw}deg)` }}>
        {sheets.map((sh, i) => {
          const col = KIND_COLOR[sh.kind] || '#fff'
          const top = i === N - 1
          return (
            <div key={sh.id} className={`tower-sheet ${hover === i ? 'hover' : ''}`} onClick={onSheetClick}
              onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover(null)}
              style={{ backgroundImage: `url(${urlFor(sh.id)})`, transform: `translateZ(${zOf(i)}px)`, transitionDelay: `${(spread ? i : N - 1 - i) * 90}ms`, '--c': col, opacity: ready ? 1 : 0 }}>
              {top && routeD && (
                <svg className="tower-route" viewBox="0 0 1000 1000" preserveAspectRatio="none">
                  <path d={routeD} />
                  {stops.map((st) => { const [fx, fy] = toFrac(st.lon, st.lat); return <circle key={st.id} cx={fx * 1000} cy={fy * 1000} r="9" /> })}
                  {habitat && (() => { const [fx, fy] = toFrac(habitat.lon, habitat.lat); return <rect x={fx * 1000 - 10} y={fy * 1000 - 10} width="20" height="20" /> })()}
                </svg>
              )}
              <div className="tower-label" style={{ transform: bill, opacity: spread ? 1 : 0, transitionDelay: `${(spread ? i * 90 + 500 : 0)}ms` }}>
                <div>
                  <i style={{ background: col }} />
                  <b style={{ color: col }}>{sh.kind}</b>
                  <span>{sh.line}</span>
                </div>
              </div>
              {cf && <div className="core-anchor" data-i={i} style={{ left: `${cf[0] * 100}%`, top: `${cf[1] * 100}%` }} />}
            </div>
          )
        })}
      </div>
      {cf && pts.length === N && (
        <div className="tower-overlay" style={{ opacity: spread ? 1 : 0 }}>
          <svg>
            <polyline points={pts.map((p) => `${p.x},${p.y}`).join(' ')} className="core-line-glow" />
            <polyline points={pts.map((p) => `${p.x},${p.y}`).join(' ')} className="core-line" />
            {pts.map((p, i) => <circle key={i} cx={p.x} cy={p.y} r="5.5" className="core-dot2" style={{ stroke: KIND_COLOR[sheets[i]?.kind] || '#fff' }} />)}
          </svg>
          {pts.map((p, i) => (
            <div key={i} className={`core-val2 ${p.x > box.w * 0.4 ? 'left' : ''}`} style={{ left: p.x, top: p.y }}>
              <i style={{ background: KIND_COLOR[sheets[i]?.kind] || '#fff' }} />{coreValue(sheets[i].id, coreQ, site)}
            </div>
          ))}
          <div className="core-head2" style={{ left: pts[N - 1].x, top: pts[N - 1].y }}>DATA CORE · {core?.name || fmtLonLat(core.lon, core.lat, 4)} · one point, read through every layer</div>
        </div>
      )}
      <div className="tower-tools">
        <button className="btn sm" onClick={() => setSpread(spread ? 0 : 1)}>{spread ? <><Shrink size={14} /> Fall into one surface</> : <><Expand size={14} /> Pull the layers apart</>}</button>
        <button className="btn sm" onClick={() => { setYaw(-45); setTilt(56); setGapK(1) }}>Reset view</button>
        <span className="hint" style={{ margin: 0 }}><MousePointerClick size={13} style={{ verticalAlign: -2 }} /> Click a sheet to move the data core · drag to turn · wheel to spread</span>
      </div>
      <div className="tower-foot">The challenge asks for “a layered, integrated view”. Pull the layers apart to see where each one comes from, then let them fall into one surface: the plan stands on all of them.</div>
    </div>
  )
}
