import React, { useEffect, useMemo, useRef, useState } from 'react'
import { Download, Footprints, MessageSquareText, Radio, Satellite, Send, Waypoints } from 'lucide-react'
import { useStore } from '../../store.js'
import { interp, makeGrid } from '../../lib/geo.js'
import { api } from '../../api.js'
import { fmtDur, fmtNum } from '../../lib/format.js'
import { connectConsole, disconnectConsole, earthView, sendCommand, startSimHelmet, stopSimHelmet } from '../../lib/live.js'

// The interplanetary map (feature A5), Ask Earth (D2) and the live habitat console (D1).

const DAY = 86400000
const fmtDay = (ms) => new Date(ms).toISOString().slice(5, 16).replace('T', ' ')

function Orrery() {
  const o = useStore((s) => s.orrery)
  const [dt, setDt] = useState(0) // days from now for the CME fronts
  if (!o) return <p className="hint">Placing the planets…</p>
  const S = 150 / 1.75 // px per AU
  const P = ([x, y]) => [x * S, -y * S]
  const now = new Date(o.utc).getTime()
  const when = now + dt * DAY
  const path = (pts) => pts.map((p, i) => `${i ? 'L' : 'M'}${P(p)[0].toFixed(1)},${P(p)[1].toFixed(1)}`).join(' ')
  const [ex, ey] = P(o.earth)
  const [mx, my] = P(o.mars)
  const pulse = Math.max(1.2, o.light_time_min / 3.5)
  const cmes = o.cmes.map((c) => {
    const t21 = new Date(c.t21_5).getTime()
    const sec = (when - t21) / 1000
    if (sec < 0) return null
    const front = 21.5 * 0.00465 + (c.speed_kms * sec) / 149597870.7
    if (front > 2.0) return null
    const a0 = ((c.lon_ecliptic - c.half_angle) * Math.PI) / 180
    const a1 = ((c.lon_ecliptic + c.half_angle) * Math.PI) / 180
    const r = front * S
    const d = `M0,0 L${(Math.cos(a0) * r).toFixed(1)},${(-Math.sin(a0) * r).toFixed(1)} A${r.toFixed(1)},${r.toFixed(1)} 0 0 0 ${(Math.cos(a1) * r).toFixed(1)},${(-Math.sin(a1) * r).toFixed(1)} Z`
    return { ...c, d, front }
  }).filter(Boolean)
  const marsHit = o.cmes.some((c) => c.mars?.arrival && Math.abs(new Date(c.mars.arrival).getTime() - when) <= 12 * 3600000)
  return (
    <>
      <svg viewBox="-160 -160 320 320" className="orrery" aria-label="Sun, Earth and Mars with the recent CMEs">
        <defs>
          <radialGradient id="sunG"><stop offset="0" stopColor="#fff7d6" /><stop offset="0.5" stopColor="#ffcf4a" /><stop offset="1" stopColor="#ff8a00" stopOpacity="0" /></radialGradient>
        </defs>
        <path d={path(o.earth_orbit)} className="orb-path" />
        <path d={path(o.mars_orbit)} className="orb-path mars" />
        {cmes.map((c) => <path key={c.id} d={c.d} className={`cme ${c.toward_mars ? 'mars' : ''}`}><title>{`CME ${c.id} · ${Math.round(c.speed_kms)} km/s · ±${c.half_angle}°${c.mars ? ` · DONKI: reaches Mars ${c.mars.arrival}` : ''}`}</title></path>)}
        <circle r="12" fill="url(#sunG)" />
        <circle r="4" fill="#fff3c4" />
        <line x1={ex} y1={ey} x2={mx} y2={my} className="lt-line" />
        <circle r="2.6" className="lt-pulse">
          <animateMotion dur={`${pulse}s`} repeatCount="indefinite" path={`M${ex},${ey} L${mx},${my}`} />
        </circle>
        <circle cx={ex} cy={ey} r="5" className="pl earth" /><text x={ex + 8} y={ey + 4} className="pl-t">Earth</text>
        {marsHit && <circle cx={mx} cy={my} r="11" className="mars-hit" />}
        <circle cx={mx} cy={my} r="4.5" className="pl mars" /><text x={mx + 8} y={my + 4} className="pl-t">Mars</text>
        <text x="-155" y="-145" className="pl-t dim">{fmtDay(when)} UTC</text>
      </svg>
      <label className="field" style={{ marginTop: 4 }}>
        <span>CME fronts {dt === 0 ? 'now' : dt < 0 ? `${fmtNum(-dt, 1)} days ago` : `in ${fmtNum(dt, 1)} days`} {marsHit && <b style={{ color: 'var(--critical-ink)' }}>· a CME at Mars (±12 h)</b>}</span>
        <input type="range" min="-8" max="3" step="0.1" value={dt} onChange={(e) => setDt(+e.target.value)} />
      </label>
      <div className="wh-stats">
        <div><b>{fmtNum(o.light_time_min, 1)}′</b><span>light, one way</span></div>
        <div><b>{fmtNum(o.earth_mars_au, 2)} AU</b><span>Earth–Mars</span></div>
        <div><b>{o.cmes.length}</b><span>CMEs, 10 days</span></div>
      </div>
      <p className="hint">The pulse is a radio signal crossing at the speed of light. In {o.next_min_light_min.in_days} days it takes only {fmtNum(o.next_min_light_min.minutes, 1)} min; in {o.next_max_light_min.in_days} days, near conjunction, {fmtNum(o.next_max_light_min.minutes, 1)} min. Red cones are CMEs heading Mars' way (NASA DONKI, WSA-ENLIL inputs).</p>
    </>
  )
}

function AskEarth() {
  const o = useStore((s) => s.orrery)
  const plan = useStore((s) => s.plan)
  const ask = useStore((s) => s.askEarth)
  const set = useStore((s) => s.set)
  const [think, setThink] = useState(10)
  const [stopIdx, setStopIdx] = useState(0)
  const stops = plan ? plan.events.filter((e) => e.kind === 'stop') : []
  if (!o || !plan) return <p className="hint">Plan an EVA to ask Earth from one of its stops.</p>
  const run = () => {
    const ev = stops[stopIdx] || plan.events[0]
    const tAsk = ev.t0 + 5 * 60
    const tAns = tAsk + 2 * o.light_time_s + think * 60
    const p = plan.profile
    const where = plan.events.find((e) => tAns >= e.t0 && tAns < e.t1)
    set({ askEarth: { tAsk, tAns, from: ev.name, where: where ? where.name : 'back inside', kind: where?.kind, lon: interp(p.t, p.lon, tAns), lat: interp(p.t, p.lat, tAns), think, lt: o.light_time_s, leftStop: tAns > ev.t1 } })
  }
  return (
    <>
      <div className="row" style={{ gap: 6 }}>
        <select value={stopIdx} onChange={(e) => setStopIdx(+e.target.value)} style={{ flex: 1 }} className="site-select">
          {stops.map((e, i) => <option key={i} value={i}>Ask from {e.name}</option>)}
        </select>
        <button className="btn sm primary" onClick={run}><Send size={13} /> Ask Earth</button>
      </div>
      <label className="field" style={{ marginTop: 6 }}><span>Thinking time on Earth <b>{think} min</b></span><input type="range" min="0" max="60" step="5" value={think} onChange={(e) => setThink(+e.target.value)} /></label>
      {ask && (
        <div className="card" style={{ marginTop: 6 }}>
          <div className="row between" style={{ fontSize: 12 }}><span>Asked at {ask.from}</span><b className="mono">T+{fmtDur(ask.tAsk, { short: true })}</b></div>
          <div className="row between" style={{ fontSize: 12 }}><span>Answer arrives</span><b className="mono">T+{fmtDur(ask.tAns, { short: true })}</b></div>
          <p className="hint" style={{ margin: '6px 0 0' }}>{fmtNum(ask.lt / 60, 1)} min there, {ask.think} min thinking, {fmtNum(ask.lt / 60, 1)} min back: <b>{fmtDur(ask.tAns - ask.tAsk)}</b>. By then the crew is {ask.kind === 'walk' ? 'walking' : ask.kind === 'stop' ? 'at' : 'in'} <b>{ask.where}</b>{ask.leftStop ? `, already gone from ${ask.from}` : ''} (marked on the map). Earth can advise, not direct: the habitat runs the EVA. NASA's BASALT field tests worked with 5 and 15 min delays.</p>
        </div>
      )}
    </>
  )
}

function LiveLink() {
  const live = useStore((s) => s.live)
  const siteId = useStore((s) => s.siteId)
  const plan = useStore((s) => s.plan)
  const tool = useStore((s) => s.tool)
  const set = useStore((s) => s.set)
  const [text, setText] = useState('')
  useEffect(() => () => { disconnectConsole(); stopSimHelmet() }, [siteId])
  const last = live.last
  const ev = useMemo(() => earthView(live.history, live.lightTimeS), [live.history, live.lightTimeS])
  const age = last ? (Date.now() / 1000 - last.server_t) : null
  return (
    <>
      <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
        {!live.connected
          ? <button className="btn sm primary" onClick={() => connectConsole(siteId)} disabled={live.connecting}><Radio size={13} /> {live.connecting ? 'Connecting…' : 'Open the habitat console'}</button>
          : <button className="btn sm" onClick={() => disconnectConsole()}>Close the link</button>}
        {live.connected && (live.simulating
          ? <button className="btn sm" onClick={stopSimHelmet}>Stop the simulated helmet</button>
          : <button className="btn sm" disabled={!plan} onClick={() => startSimHelmet(siteId, 20)} title="No Godot helmet? Walk the plan at x20 as if it were one">Simulate a helmet (×20)</button>)}
      </div>
      {live.connected && (
        <>
          <div className="wh-stats">
            <div><b>{live.clients?.helmet ?? 0}</b><span>helmets</span></div>
            <div><b>{last ? `${fmtNum(last.o2_pct)} %` : '—'}</b><span>EV1 oxygen</span></div>
            <div><b>{last ? `T+${fmtDur(last.eva_t, { short: true })}` : '—'}</b><span>EVA clock</span></div>
          </div>
          {last ? (
            <p className="hint">{last.source === 'simulated' ? 'Simulated helmet' : 'Helmet'}: {last.phase || '—'} · heading {fmtNum(last.heading)}° · margin {fmtNum(last.margin_min)} min · walk back {fmtNum(last.walkback_min, 1)} min{age != null && age > 5 ? ` · ${Math.round(age)} s old` : ''}. Blue ghost: the crew as Earth sees them, {fmtNum((live.lightTimeS || 0) / 60, 1)} min late{ev ? '' : ' (not yet: the link is younger than a light-time)'}.</p>
          ) : <p className="hint">Waiting for a helmet. Start the Godot console and walk (it joins by itself), or simulate one.</p>}
          <div className="row" style={{ gap: 6 }}>
            <button className={`btn sm ${tool === 'push-wp' ? 'on' : ''}`} onClick={() => set({ tool: tool === 'push-wp' ? 'select' : 'push-wp' })}><Waypoints size={13} /> Push a waypoint</button>
            {live.waypoint && <button className="btn sm" onClick={() => sendCommand({ type: 'clear_waypoint' })}>Clear it</button>}
          </div>
          <div className="row" style={{ gap: 6, marginTop: 6 }}>
            <input className="txt" value={text} onChange={(e) => setText(e.target.value)} placeholder="Message to the visor" onKeyDown={(e) => { if (e.key === 'Enter' && text.trim()) { sendCommand({ type: 'message', text }); setText('') } }} />
            <button className="btn sm" disabled={!text.trim()} onClick={() => { sendCommand({ type: 'message', text }); setText('') }}><MessageSquareText size={13} /></button>
          </div>
        </>
      )}
    </>
  )
}

// Walk it on Earth (feature F3): the EVA at full scale on a sports field. The phone's GPS moves a dot across the Mars
// site from the habitat, with the walk-back time live. Your position stays in this browser: only the matching Mars
// point goes to the planner. Or take the route home as a GPX laid over the ground where you stand.
const EARTH_M_PER_DEG = 111320
const earthOffset = (a, b) => [(b.lon - a.lon) * EARTH_M_PER_DEG * Math.cos((a.lat * Math.PI) / 180), (b.lat - a.lat) * EARTH_M_PER_DEG]
const earthAt = (a, dx, dy) => ({ lon: a.lon + dx / (EARTH_M_PER_DEG * Math.cos((a.lat * Math.PI) / 180)), lat: a.lat + dy / EARTH_M_PER_DEG })

function routeOffsets(g, plan, hab) {
  const [hx, hy] = g.toXY(hab.lon, hab.lat)
  return plan.legs.flatMap((L) => L.path).map(([lon, lat]) => { const [x, y] = g.toXY(lon, lat); return [x - hx, y - hy] })
}

function gpxText(anchor, offsets, stops, g, hab, name) {
  const [hx, hy] = g.toXY(hab.lon, hab.lat)
  const f = (v) => v.toFixed(7)
  const esc = (t) => String(t).replace(/[<>&"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]))
  const wpts = [{ name: 'Habitat', ...anchor }, ...stops.map((s) => { const [x, y] = g.toXY(s.lon, s.lat); return { name: s.name, ...earthAt(anchor, x - hx, y - hy) } })]
  const trk = offsets.map(([dx, dy]) => { const p = earthAt(anchor, dx, dy); return `<trkpt lat="${f(p.lat)}" lon="${f(p.lon)}"/>` })
  return ['<?xml version="1.0" encoding="UTF-8"?>',
    '<gpx version="1.1" creator="Martian Map" xmlns="http://www.topografix.com/GPX/1/1">',
    `<metadata><name>${esc(name)} at full scale</name><desc>The planned Mars EVA laid over Earth at 1:1, starting where you stand.</desc></metadata>`,
    ...wpts.map((w) => `<wpt lat="${f(w.lat)}" lon="${f(w.lon)}"><name>${esc(w.name)}</name></wpt>`),
    `<trk><name>${esc(name)}</name><trkseg>`, ...trk, '</trkseg></trk>', '</gpx>', ''].join('\n')
}

function WalkOnEarth() {
  const site = useStore((s) => s.site)
  const plan = useStore((s) => s.plan)
  const ew = useStore((s) => s.earthWalk)
  const set = useStore((s) => s.set)
  const [err, setErr] = useState(null)
  const watchId = useRef(null)
  const simTimer = useRef(null)
  const lastQuery = useRef(0)
  const g = useMemo(() => (site ? makeGrid(site.grid) : null), [site])

  const onFix = (pos) => {
    const s = useStore.getState()
    const cur = s.earthWalk || {}
    const anchor = cur.anchor || pos
    const [dx, dy] = earthOffset(anchor, pos)
    const [hx, hy] = g.toXY(s.habitat.lon, s.habitat.lat)
    const [lon, lat] = g.toLonLat(hx + dx, hy + dy)
    let step = 0
    if (cur.mars) {
      const [ax, ay] = g.toXY(cur.mars.lon, cur.mars.lat)
      step = Math.hypot(hx + dx - ax, hy + dy - ay)
    }
    const noisy = pos.acc != null && pos.acc > 25 // a poor fix: show it, but don't count it as walking
    const track = [...(cur.track || []), [lon, lat]].slice(-3000)
    s.set({ earthWalk: { ...cur, on: true, anchor, mars: { lon, lat }, acc: pos.acc, track, walked: (cur.walked || 0) + (noisy ? 0 : step) } })
    const now = Date.now()
    if (now - lastQuery.current > 1800) {
      lastQuery.current = now
      api.query(s.siteId, { lon, lat, hab_lon: s.habitat.lon, hab_lat: s.habitat.lat }).then((v) => {
        const e = useStore.getState().earthWalk
        if (e) useStore.getState().set({ earthWalk: { ...e, wb: v.inside === false ? null : v.walkback_min, inside: v.inside !== false } })
      }).catch(() => {})
    }
  }

  const stop = () => {
    if (watchId.current != null) navigator.geolocation?.clearWatch(watchId.current)
    watchId.current = null
    clearInterval(simTimer.current)
    simTimer.current = null
    const e = useStore.getState().earthWalk
    if (e) set({ earthWalk: { ...e, on: false } })
  }
  useEffect(() => () => { if (watchId.current != null) navigator.geolocation?.clearWatch(watchId.current); clearInterval(simTimer.current) }, [])

  const startGps = () => {
    setErr(null)
    if (!window.isSecureContext) { setErr('Browsers only share location with secure pages: open the planner over HTTPS, or at localhost on this computer.'); return }
    if (!navigator.geolocation) { setErr('This browser has no location service.'); return }
    set({ earthWalk: { on: true, sim: false, track: [], walked: 0 } })
    watchId.current = navigator.geolocation.watchPosition(
      (p) => onFix({ lon: p.coords.longitude, lat: p.coords.latitude, acc: p.coords.accuracy }),
      (e) => { setErr(e.message || 'Location unavailable'); stop() },
      { enableHighAccuracy: true, maximumAge: 1000, timeout: 30000 })
  }

  const simulate = () => {
    if (!plan) return
    setErr(null)
    const offs = routeOffsets(g, plan, useStore.getState().habitat)
    const field = { lon: 0, lat: 0 } // a stand-in field: the simulated walk needs no real place
    const pts = []
    for (let i = 1; i < offs.length; i++) {
      const [x0, y0] = offs[i - 1]
      const [x1, y1] = offs[i]
      const n = Math.max(1, Math.round(Math.hypot(x1 - x0, y1 - y0) / 8))
      for (let k = 0; k < n; k++) pts.push([x0 + ((x1 - x0) * k) / n, y0 + ((y1 - y0) * k) / n])
    }
    set({ earthWalk: { on: true, sim: true, track: [], walked: 0, anchor: field } })
    let i = 0
    simTimer.current = setInterval(() => {
      if (i >= pts.length) { stop(); return }
      onFix({ ...earthAt(field, pts[i][0], pts[i][1]), acc: 4 })
      i += 1
    }, 200)
  }

  const saveGpx = () => {
    const s = useStore.getState()
    const go = (anchor) => {
      const text = gpxText(anchor, routeOffsets(g, plan, s.habitat), s.stops, g, s.habitat, `${site.short_name} EVA`)
      const a = document.createElement('a')
      a.href = URL.createObjectURL(new Blob([text], { type: 'application/gpx+xml' }))
      a.download = `eva_on_earth_${site.id}.gpx`
      a.click()
      setTimeout(() => URL.revokeObjectURL(a.href), 5000)
    }
    if (ew?.anchor && !ew.sim) { go(ew.anchor); return }
    if (!window.isSecureContext || !navigator.geolocation) { setErr('Location needs a secure page: open the planner over HTTPS, or at localhost on this computer.'); return }
    navigator.geolocation.getCurrentPosition((p) => go({ lon: p.coords.longitude, lat: p.coords.latitude }), (e) => setErr(e.message || 'Location unavailable'), { enableHighAccuracy: true, timeout: 20000 })
  }

  const total = plan ? plan.totals.dist_m : 0
  return (
    <>
      <p className="hint" style={{ marginTop: 0 }}>Walk the EVA at full scale on a sports field: the phone's GPS moves your dot across the site from the habitat, with the walk-back time live. Your position stays in this browser; only the matching Mars point goes to the planner.</p>
      <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
        {!ew?.on ? (
          <>
            <button className="btn sm primary" onClick={startGps} disabled={!plan}><Footprints size={13} /> Start walking</button>
            <button className="btn sm" onClick={simulate} disabled={!plan}>Simulate a walk</button>
          </>
        ) : <button className="btn sm" onClick={stop}>Stop</button>}
        <button className="btn sm" onClick={saveGpx} disabled={!plan}><Download size={13} /> Route over my neighbourhood (GPX)</button>
        {ew && !ew.on && <button className="btn sm ghost" onClick={() => set({ earthWalk: null })}>Clear</button>}
      </div>
      {err && <p className="hint" style={{ color: 'var(--warning)' }}>{err}</p>}
      {ew?.mars && (
        <div className="wh-stats" style={{ marginTop: 8 }}>
          <div><b>{fmtNum(ew.walked || 0)} m</b><span>walked{total ? ` of ${fmtNum(total)}` : ''}</span></div>
          <div><b>{ew.inside === false ? 'off site' : ew.wb != null ? `${fmtNum(ew.wb, 1)}′` : '…'}</b><span>walk back</span></div>
          <div><b>{ew.acc != null ? `±${Math.round(ew.acc)} m` : '—'}</b><span>{ew.sim ? 'simulated' : 'GPS'}</span></div>
        </div>
      )}
    </>
  )
}

export default function EarthPanel() {
  return (
    <>
      <div className="section">
        <h3><span><Satellite size={11} style={{ verticalAlign: -1 }} /> The interplanetary map</span></h3>
        <div className="card"><Orrery /></div>
      </div>
      <div className="section">
        <h3><span><Send size={11} style={{ verticalAlign: -1 }} /> Ask Earth</span></h3>
        <div className="card"><AskEarth /></div>
      </div>
      <div className="section">
        <h3><span><Radio size={11} style={{ verticalAlign: -1 }} /> Habitat and suit, live</span></h3>
        <div className="card">
          <p className="hint" style={{ marginTop: 0 }}>Earth is too far away to direct an EVA, so the habitat does. A crew member inside follows the walker live and can push a waypoint into the visor.</p>
          <LiveLink />
        </div>
      </div>
      <div className="section">
        <h3><span><Footprints size={11} style={{ verticalAlign: -1 }} /> Walk it on Earth</span></h3>
        <div className="card"><WalkOnEarth /></div>
      </div>
    </>
  )
}
