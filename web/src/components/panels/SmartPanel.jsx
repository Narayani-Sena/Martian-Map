import React, { useState } from 'react'
import { Flag, Gem, Plane as Helicopter, PenLine, Scale, Sparkles, Trash2, TriangleAlert } from 'lucide-react'
import { api } from '../../api.js'
import { missionBody, useStore } from '../../store.js'
import { openPlanDoc } from '../../lib/docs.js'
import { fmtDist, fmtDur, fmtNum } from '../../lib/format.js'

// The map that learns and asks (feature C1-C4) and Beat the planner (G3).

export const AP_COLORS = { safe: '#3ccf3c', balanced: '#4fd1ff', bold: '#ff8a3d' }

function PlanForMe() {
  const ap = useStore((s) => s.autoplan)
  const preview = useStore((s) => s.apPreview)
  const plan = useStore((s) => s.plan)
  const set = useStore((s) => s.set)
  const [budget, setBudget] = useState(240)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    const s = useStore.getState()
    const b = missionBody(s)
    try {
      set({ autoplan: await api.autoplan(s.siteId, { habitat: b.habitat, stops: b.stops, walk: b.walk, suit: b.suit, start_utc: b.start_utc, suit_budget_min: budget, user_suit_min: plan ? plan.totals.suit_s / 60 : null }), apPreview: 'balanced' })
    } catch (e) { s.notify(`Plan it for me: ${e.message}`, 'error') }
    setBusy(false)
  }
  const use = (v) => {
    const s = useStore.getState()
    s.set({ stops: v.stops.map((st, i) => ({ id: st.id && !st.id.startsWith('AP') ? st.id : `S${i + 1}`, name: st.name, kind: st.kind || 'custom', lon: st.lon, lat: st.lat, dwell_min: st.dwell_min, tasks: st.tasks || [], science: st.science })), autoplan: null, apPreview: null })
    s.notify(`${v.name} EVA loaded: ${v.stops.length} stops`, 'ok')
  }
  return (
    <div className="section">
      <h3><span><Sparkles size={11} style={{ verticalAlign: -1 }} /> Plan it for me</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>Give a time in suits: get three EVAs that collect the most science inside the margins, stops in the best order. Each one is then planned for real (routes, suit, GO / NO-GO).</p>
        <label className="field"><span>Time in suits <b>{fmtDur(budget * 60)}</b></span><input type="range" min="90" max="420" step="10" value={budget} onChange={(e) => setBudget(+e.target.value)} /></label>
        <button className="btn sm primary" disabled={busy} onClick={run}>{busy ? 'Searching every order…' : 'Plan it for me'}</button>
        {ap && (
          <>
            {ap.same_time && (
              <p className="hint">At your own {Math.round(ap.same_time.user_suit_min)} min in suits the planner finds <b>{fmtNum(ap.same_time.planner_science, 2)}</b> science against your <b>{fmtNum(ap.same_time.user_science, 2)}</b> ({fmtNum(ap.same_time.planner_science / Math.max(0.01, ap.same_time.user_science), 1)}×).</p>
            )}
            {ap.variants.map((v) => (
              <div key={v.id} className={`ap-card ${preview === v.id ? 'on' : ''}`} style={{ '--c': AP_COLORS[v.id] }} onMouseEnter={() => set({ apPreview: v.id })}>
                <div className="row between"><b>{v.name}</b><span className={`tag ${v.plan?.go ? 'ok' : 'bad'}`}>{v.plan ? (v.plan.go ? 'GO' : 'NO-GO') : '—'}</span></div>
                <div className="ap-stats">
                  <span><b>{fmtNum(v.science, 2)}</b> science</span>
                  <span><b>{v.stops.length}</b> stops</span>
                  <span><b>{v.plan?.suit_min ? Math.round(v.plan.suit_min) : Math.round(v.est_suit_min)}</b> min suited</span>
                  {v.plan?.min_margin_min != null && <span><b>{Math.round(v.plan.min_margin_min)}</b> min margin</span>}
                </div>
                <div className="hint" style={{ margin: '3px 0 6px' }}>{v.stops.map((s) => s.name).join(' → ')} · walk-back ≤ {v.wb_limit_min} min</div>
                <button className="btn sm" disabled={!v.stops.length} onClick={() => use(v)}>Use this EVA</button>
              </div>
            ))}
          </>
        )}
      </div>
    </div>
  )
}

function ScoutFirst() {
  const sc = useStore((s) => s.scout)
  const plan = useStore((s) => s.plan)
  const set = useStore((s) => s.set)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    const s = useStore.getState()
    try { set({ scout: await api.scout(s.siteId, missionBody(s)) }) } catch (e) { s.notify(`Scout first: ${e.message}`, 'error') }
    setBusy(false)
  }
  return (
    <div className="section">
      <h3><span><Helicopter size={11} style={{ verticalAlign: -1 }} /> Scout first</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>Where does GO rest on shaky data (the two terrain models disagree, or the sand clues do)? Fly a helicopter over those stretches first, as Ingenuity scouted Seitah for Perseverance's drivers in 2021.</p>
        <div className="row" style={{ gap: 6 }}>
          <button className="btn sm primary" disabled={!plan || busy} onClick={run}>{busy ? 'Planning the flight…' : 'Find the shaky stretches'}</button>
          {sc && <button className="btn sm" onClick={() => set({ scout: null })}>Clear</button>}
        </div>
        {sc && (
          sc.stretches.length === 0 ? <p className="hint">Nothing to scout: the whole route stands on data both models agree on.</p> : (
            <>
              <div className="wh-stats">
                <div><b>{sc.stretches.length}</b><span>stretches</span></div>
                <div><b>{fmtDist(sc.stretches.reduce((a, x) => a + x.length_m, 0))}</b><span>uncertain</span></div>
                <div><b>{sc.flight.flights.length}</b><span>flights · {fmtDist(sc.flight.total_m)}</span></div>
              </div>
              <p className="hint">Margin range {fmtNum(sc.before.margin_range_min[0])}–{fmtNum(sc.before.margin_range_min[1])} min before, {fmtNum(sc.after.margin_range_min[0])}–{fmtNum(sc.after.margin_range_min[1])} after; uncertain terrain on the route {fmtDist(sc.before.terrain_low_m || 0)} → 0 m. <b>The flight's result is simulated</b> (a perfect look inside the camera's swath, {fmtNum(sc.flight.swath_half_m * 2)} m wide at {sc.flight.altitude_m} m up).</p>
            </>
          )
        )}
      </div>
    </div>
  )
}

function CrewTags() {
  const tags = useStore((s) => s.tags)
  const tool = useStore((s) => s.tool)
  const set = useStore((s) => s.set)
  const del = async (id) => {
    const s = useStore.getState()
    try { const r = await api.deleteTag(s.siteId, id); s.set({ tags: r.tags, tagKey: r.version }) } catch (e) { s.notify(e.message, 'error') }
  }
  return (
    <div className="section">
      <h3><span><Flag size={11} style={{ verticalAlign: -1 }} /> Crew-tagged map</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>Look at a spot and press once. A <b>hazard</b> closes a 6 m disc of ground: the route is planned again and the next EVA inherits it. A <b>find</b> becomes a candidate stop for Plan it for me. The helmet tags with one key.</p>
        <div className="row" style={{ gap: 6 }}>
          <button className={`btn sm ${tool === 'tag-hazard' ? 'on' : ''}`} onClick={() => set({ tool: tool === 'tag-hazard' ? 'select' : 'tag-hazard' })}><TriangleAlert size={13} /> Tag a hazard</button>
          <button className={`btn sm ${tool === 'tag-find' ? 'on' : ''}`} onClick={() => set({ tool: tool === 'tag-find' ? 'select' : 'tag-find' })}><Gem size={13} /> Tag a find</button>
        </div>
        {tags.length > 0 && (
          <div className="card" style={{ marginTop: 8, padding: '4px 10px' }}>
            {tags.map((t) => (
              <div key={t.id} className="row between" style={{ fontSize: 12, padding: '3px 0' }}>
                <span><span className={`tag ${t.kind === 'hazard' ? 'bad' : 'ok'}`} style={{ marginRight: 6 }}>{t.kind.toUpperCase()}</span>{t.note || t.id} <span className="muted">· {t.by}</span></span>
                <button className="btn ghost icon" onClick={() => del(t.id)} aria-label="Remove the tag"><Trash2 size={13} /></button>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

function CostOfARock() {
  const plan = useStore((s) => s.plan)
  const sm = plan?.samples
  return (
    <div className="section">
      <h3><span><Scale size={11} style={{ verticalAlign: -1 }} /> The cost of a rock</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>Samples add mass as the EVA goes on, so each one has a price in minutes of margin: the suit works harder carrying it home.</p>
        {sm?.per_stop?.length ? (
          <div className="card" style={{ padding: '4px 10px' }}>
            {sm.per_stop.map((r) => (
              <div key={r.id || r.stop} className="row between" style={{ fontSize: 12, padding: '3px 0' }}>
                <span>{r.stop} · {fmtNum(r.kg, 1)} kg</span><span className="mono">−{fmtNum(r.margin_cost_min, 1)} min · carried {Math.round(r.carried_min)} min</span>
              </div>
            ))}
          </div>
        ) : <p className="hint">Plan an EVA to price its samples.</p>}
        <div className="row" style={{ gap: 6, marginTop: 8 }}>
          <button className="btn sm primary" disabled={!plan} onClick={() => {
            const s = useStore.getState()
            const hist = s.live?.history || []
            const track = hist.filter((h) => h.lon != null && h.eva_t != null).map((h) => [h.eva_t, h.lon, h.lat])
            openPlanDoc('debrief', 'eva_debrief', 'debrief', track.length > 1 ? { track } : {})
          }}>EVA debrief and sample passports</button>
        </div>
        <p className="hint">The debrief puts the walk as flown (recorded by the live link) against the plan, the time at each station, and a passport for every sample: place, grid square, map unit, mineral signal, time, sun, mass, its price and the voice note (type it on the stop in Mission plan).</p>
      </div>
    </div>
  )
}

function BeatThePlanner() {
  const sk = useStore((s) => s.sketch)
  const tool = useStore((s) => s.tool)
  const set = useStore((s) => s.set)
  const score = async () => {
    const s = useStore.getState()
    if ((s.sketch?.points || []).length < 2) { s.notify('Click at least two points on the map', 'info'); return }
    try { set({ sketch: { ...s.sketch, result: await api.scoreRoute(s.siteId, { points: s.sketch.points, walk: s.walk }) }, tool: 'select' }) } catch (e) { s.notify(e.message, 'error') }
  }
  const r = sk?.result
  return (
    <div className="section">
      <h3><span><PenLine size={11} style={{ verticalAlign: -1 }} /> Beat the planner</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>Sketch your own route on the map. It is scored with the same walking model as the planner and raced against A* between the same ends.</p>
        <div className="row" style={{ gap: 6 }}>
          <button className={`btn sm ${tool === 'sketch' ? 'on' : ''}`} onClick={() => set({ tool: tool === 'sketch' ? 'select' : 'sketch', sketch: tool === 'sketch' ? sk : { points: [], result: null } })}>{tool === 'sketch' ? `Drawing… ${sk?.points?.length || 0} points` : 'Draw a route'}</button>
          <button className="btn sm primary" disabled={(sk?.points || []).length < 2} onClick={score}>Score it</button>
          {sk && <button className="btn sm" onClick={() => set({ sketch: null, tool: 'select' })}>Clear</button>}
        </div>
        {r && (
          <>
            <div className="wh-stats">
              <div><b>{fmtNum(r.yours.time_s / 60, 1)}′</b><span>yours</span></div>
              <div><b>{r.planner ? `${fmtNum(r.planner.time_s / 60, 1)}′` : '—'}</b><span>A*</span></div>
              <div><b style={{ color: r.score > 1000 ? 'var(--good-ink)' : undefined }}>{r.score ?? '—'}</b><span>score</span></div>
            </div>
            <p className="hint"><b>{r.verdict}</b>. Yours: {fmtDist(r.yours.dist_m)}, climb {fmtNum(r.yours.ascent_m)} m, steepest {fmtNum(r.yours.max_slope)}°{r.yours.hazard_m > 0 ? `, ${fmtNum(r.yours.hazard_m)} m hazardous` : ''}. 1000 = the planner's time; no-go and hazardous metres cost points.</p>
          </>
        )}
      </div>
    </div>
  )
}

export default function SmartPanel() {
  return (
    <>
      <p className="hint" style={{ marginTop: 0 }}>A map that learns from the crew and asks before it guesses.</p>
      <PlanForMe />
      <ScoutFirst />
      <CrewTags />
      <CostOfARock />
      <BeatThePlanner />
    </>
  )
}
