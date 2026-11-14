import React, { useEffect, useRef, useState } from 'react'
import { Activity, HeartPulse, Package, Pause, Play, Wind } from 'lucide-react'
import { api, walkParams } from '../../api.js'
import { havensList, havensParam, missionBody, useStore } from '../../store.js'
import { fmtDist, fmtNum } from '../../lib/format.js'

// The shrinking world (feature A3), partner down (B3) and caches at the gateways (B4).

function ShrinkingWorld() {
  const env = useStore((s) => s.envelope)
  const tool = useStore((s) => s.tool)
  const set = useStore((s) => s.set)
  const [playing, setPlaying] = useState(false)
  const timer = useRef(null)
  const start = () => {
    const s = useStore.getState()
    const st = s.stops.find((x) => x.id === s.selectedStop) || s.stops[1] || s.stops[0]
    if (!st) { s.notify('Add a stop first, or place the crew on the map', 'info'); return }
    s.startEnvelope(st.lon, st.lat, st.name)
  }
  useEffect(() => {
    if (!playing) { clearInterval(timer.current); return undefined }
    timer.current = setInterval(() => {
      const e = useStore.getState().envelope
      if (!e) return
      const next = Math.max(0, e.minutes - 0.5)
      useStore.getState().set({ envelope: { ...e, minutes: next } })
      if (next <= 0) setPlaying(false)
    }, 60)
    return () => clearInterval(timer.current)
  }, [playing])
  const d = env?.data
  // what is in reach at the current minutes (counted client-side from the decoded field)
  const inReach = d ? d.havens.filter((h) => h.needs_min != null && h.needs_min <= env.minutes) : []
  return (
    <div className="section">
      <h3><span><Wind size={11} style={{ verticalAlign: -1 }} /> Suit leak: the shrinking world</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>With a leak, everywhere the crew can still walk to <i>and</i> get home from (at the return factor, keeping the reserve) tightens as the oxygen drops, and the havens drop out one by one. On a normal EVA the suit carries about twice what the walk uses, so this edge only shows when something fails.</p>
        <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
          <button className="btn sm primary" onClick={start}>Leak at a stop</button>
          <button className={`btn sm ${tool === 'crew' ? 'on' : ''}`} onClick={() => set({ tool: tool === 'crew' ? 'select' : 'crew' })}>Place the crew</button>
          {env && <button className="btn sm" onClick={() => { setPlaying(false); set({ envelope: null }) }}>End drill</button>}
        </div>
        {env && !d && <p className="hint">Tracing every way out and back from {env.name || 'the crew'}…</p>}
        {d && (
          <>
            <label className="field" style={{ marginTop: 8 }}>
              <span>Oxygen left (at the return-walk rate) <b>{Math.round(env.minutes)} min</b></span>
              <input type="range" min="0" max={Math.ceil(d.egress_minutes)} step="1" value={env.minutes} onChange={(e) => { setPlaying(false); set({ envelope: { ...env, minutes: +e.target.value } }) }} />
            </label>
            <div className="row" style={{ gap: 6 }}>
              <button className="btn sm" onClick={() => setPlaying((p) => !p)}>{playing ? <><Pause size={13} /> Pause</> : <><Play size={13} /> Let it leak</>}</button>
              <span className="hint" style={{ margin: 0 }}>Full suit at egress: {fmtNum(d.egress_minutes)} min</span>
            </div>
            <div className="wh-stats">
              <div><b>{fmtNum(env.area_ha ?? 0)} ha</b><span>still in reach</span></div>
              <div><b>{fmtNum((env.share ?? 0) * 100)} %</b><span>of the walkable site</span></div>
              <div><b>{inReach.length}/{d.havens.length}</b><span>havens in reach</span></div>
            </div>
            <div className="card" style={{ marginTop: 8, padding: '4px 10px' }}>
              {d.havens.map((h) => {
                const ok = h.needs_min != null && h.needs_min <= env.minutes
                return (
                  <div key={h.name} className="row between" style={{ fontSize: 12, padding: '3px 0' }}>
                    <span><span className={`tag ${ok ? 'ok' : 'bad'}`} style={{ marginRight: 6 }}>{ok ? 'IN REACH' : 'LOST'}</span>{h.name}</span>
                    <span className="mono muted">{h.walk_min != null ? `${fmtNum(h.walk_min)} min walk · needs ${fmtNum(h.needs_min)}` : 'no way'}</span>
                  </div>
                )
              })}
            </div>
            <p className="hint">Return factor ×{d.return_factor}, reserve {d.reserve_min} min. Below {fmtNum(Math.min(...d.havens.map((h) => h.needs_min ?? Infinity)))} min no haven is in reach.</p>
          </>
        )}
      </div>
    </div>
  )
}

function PartnerDown() {
  const rc = useStore((s) => s.rescueCheck)
  const plan = useStore((s) => s.plan)
  const layers = useStore((s) => s.layers)
  const setLayer = useStore((s) => s.setLayer)
  const set = useStore((s) => s.set)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    const s = useStore.getState()
    try { set({ rescueCheck: await api.rescue(s.siteId, missionBody(s)) }) } catch (e) { s.notify(`Partner down: ${e.message}`, 'error') }
    setBusy(false)
  }
  return (
    <div className="section">
      <h3><span><HeartPulse size={11} style={{ verticalAlign: -1 }} /> Partner down: minutes to pressure</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>If EV2 is hurt, how long until they are back in pressure? Carried home by EV1 (a third of walking speed, slopes under 14°), or PR-2 driving out to the nearest drivable ground to meet them. The check finds the worst point of the planned route.</p>
        <div className="row" style={{ gap: 6 }}>
          <button className="btn sm primary" disabled={!plan || busy} onClick={run}>{busy ? 'Checking the route…' : 'EV2 down drill'}</button>
          <button className={`btn sm ${layers.rescue?.on ? 'on' : ''}`} onClick={() => setLayer('rescue', { on: !layers.rescue?.on })}>Rescue-time layer</button>
          {rc && <button className="btn sm" onClick={() => set({ rescueCheck: null })}>Clear</button>}
        </div>
        {rc && rc.worst_min != null && (
          <>
            <div className="wh-stats">
              <div><b style={{ color: rc.level === 'ok' ? 'var(--good-ink)' : 'var(--warning)' }}>{fmtNum(rc.worst_min)}′</b><span>worst on route</span></div>
              <div><b>{rc.worst_mode === 'PR-2 rescue' ? 'PR-2' : 'carry'}</b><span>fastest there</span></div>
              <div><b>{fmtNum((rc.carry_ok_share || 0) * 100)} %</b><span>site carriable</span></div>
            </div>
            <p className="hint">{rc.level === 'ok' ? 'GO' : 'CAUTION'}: the worst point is {fmtNum(rc.worst_min)} min from pressure (limit {rc.limit_min}). {rc.carry_path?.ok ? `Carrying from there would take ${fmtNum(rc.carry_path.start_minutes)} min (dotted red).` : 'A carry home from there is not possible on gentle slopes.'}</p>
          </>
        )}
      </div>
    </div>
  )
}

function Caches() {
  const sug = useStore((s) => s.cacheSuggest)
  const caches = useStore((s) => s.caches)
  const plan = useStore((s) => s.plan)
  const set = useStore((s) => s.set)
  const [k, setK] = useState(3)
  const [budget, setBudget] = useState(30)
  const [onRoute, setOnRoute] = useState(false)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    const s = useStore.getState()
    const route = onRoute && plan ? plan.legs.flatMap((L) => L.path) : null
    try {
      set({ cacheSuggest: await api.caches(s.siteId, { habitat: { lon: s.habitat.lon, lat: s.habitat.lat }, havens: havensParam(havensList({ ...s, caches: [] })), walk: s.walk, k, budget_min: budget, route }) })
    } catch (e) { s.notify(`Caches: ${e.message}`, 'error') }
    setBusy(false)
  }
  const place = () => {
    set({ caches: sug.caches.map((c, i) => ({ id: `C${i + 1}`, name: c.name, lon: c.lon, lat: c.lat })), cacheSuggest: null })
    const s = useStore.getState()
    if (!s.layers.ways_home?.on) s.setLayer('ways_home', { on: true })
    s.notify('Caches placed: the ways-home network re-flows into one basin per haven', 'ok')
    s.saveMission()
  }
  return (
    <div className="section">
      <h3><span><Package size={11} style={{ verticalAlign: -1 }} /> Emergency caches at the gateways</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>Plan the infrastructure, not only the walk. Where do a few emergency oxygen bottles do the most good? Apollo's purge system gave about 30 minutes: these sites put the most ground within that walk of a haven.</p>
        <label className="field"><span>Caches <b>{k}</b></span><input type="range" min="1" max="6" value={k} onChange={(e) => setK(+e.target.value)} /></label>
        <label className="field"><span>Emergency walk budget <b>{budget} min</b></span><input type="range" min="10" max="60" step="5" value={budget} onChange={(e) => setBudget(+e.target.value)} /></label>
        <label className="row" style={{ gap: 6, fontSize: 12 }}><input type="checkbox" checked={onRoute} onChange={(e) => setOnRoute(e.target.checked)} disabled={!plan} /> Cover the planned route (else the whole site)</label>
        <div className="row" style={{ gap: 6, marginTop: 6 }}>
          <button className="btn sm primary" disabled={busy} onClick={run}>{busy ? 'Testing gateways…' : 'Find cache sites'}</button>
          {caches.length > 0 && <button className="btn sm" onClick={() => set({ caches: [] })}>Remove {caches.length} cache{caches.length > 1 ? 's' : ''}</button>}
        </div>
        {sug && (
          <>
            <div className="wh-stats">
              <div><b>{fmtNum(sug.coverage_before * 100)} %</b><span>covered now</span></div>
              <div><b style={{ color: 'var(--good-ink)' }}>{fmtNum(sug.coverage_after * 100)} %</b><span>with caches</span></div>
              <div><b>{sug.caches.length}</b><span>caches</span></div>
            </div>
            <div className="card" style={{ marginTop: 8, padding: '4px 10px' }}>
              {sug.caches.map((c) => (
                <div key={c.name} className="wh-gw" onClick={() => set({ focus: { lon: c.lon, lat: c.lat, t: Date.now() } })}>
                  <i style={{ background: '#ffc440' }} /><b style={{ width: 62 }}>{c.name}</b>
                  <span className="grow">+{fmtNum(c.gain_share * 100)} % · {c.why}</span>
                  <span className="mono muted">{Math.round(c.minutes_from_home)}′</span>
                </div>
              ))}
            </div>
            <button className="btn sm primary" style={{ marginTop: 8 }} onClick={place}>Place these caches</button>
            <p className="hint">{sug.objective === 'route' ? 'Share of the route' : 'Share of the walkable site'} within {sug.budget_min} min of a haven. Placed caches become havens: the ways-home network splits into basins.</p>
          </>
        )}
        {caches.length > 0 && !sug && <p className="hint">{caches.map((c) => c.name).join(', ')} placed (drag them on the map).</p>}
      </div>
    </div>
  )
}

export default function EmergencySection() {
  return (
    <>
      <ShrinkingWorld />
      <PartnerDown />
      <Caches />
      <p className="hint" style={{ margin: '-4px 0 10px' }}><Activity size={12} style={{ verticalAlign: -2 }} /> The drills in the helmet (suit leak, CO₂, EV2 down, dark visor) run in the Godot console.</p>
    </>
  )
}
