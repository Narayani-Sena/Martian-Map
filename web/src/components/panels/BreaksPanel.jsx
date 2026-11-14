import React, { useState } from 'react'
import { Compass, FileWarning, Grid3x3, LocateFixed } from 'lucide-react'
import { api } from '../../api.js'
import { useStore } from '../../store.js'
import { openPlanDoc } from '../../lib/docs.js'
import { fmtNum } from '../../lib/format.js'
import EmergencySection from './EmergencySection.jsx'

// "When it breaks" (feature B): every other planner assumes the plan holds. This panel is about the moments it
// does not: no GPS, a dead visor, a leak, a crew member down.

function SkylineStrip({ az, observed, stored, features }) {
  if (!observed?.length) return null
  const W = 300
  const H = 92
  const all = [...observed, ...(stored || [])]
  const top = Math.max(6, Math.ceil(Math.max(...all) + 1))
  const lo = Math.min(-2, Math.floor(Math.min(...all)))
  const X = (a) => (a / 360) * W
  const Y = (e) => H - 16 - ((e - lo) / (top - lo)) * (H - 26)
  const line = (arr) => [...arr, arr[0]].map((e, i) => `${X(i < arr.length ? az[i] : 360).toFixed(1)},${Y(e).toFixed(1)}`).join(' ')
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="sky-strip" aria-label="Skyline: what the helmet sees against the stored skyline at the fix">
      <rect x="0" y="0" width={W} height={H - 16} className="sky-bg" />
      {stored && <polygon points={`0,${H - 16} ${line(stored)} ${W},${H - 16}`} className="sky-stored" />}
      <polyline points={line(observed)} className="sky-obs" />
      {observed.map((e, i) => <circle key={i} cx={X(az[i])} cy={Y(e)} r="2.2" className="sky-dot" />)}
      {(features || []).map((f) => (
        <g key={f.name}>
          <line x1={X(f.az)} x2={X(f.az)} y1="4" y2={H - 16} className="sky-feat" />
          <text x={Math.min(W - 70, X(f.az) + 3)} y="12" className="sky-feat-t">{f.name.split(' (')[0]} · {f.dist_km} km</text>
        </g>
      ))}
      {['N', 'E', 'S', 'W'].map((l, k) => <text key={l} x={k * W / 4 + 2} y={H - 3} className="sky-ax">{l}</text>)}
      <text x={W - 2} y={H - 3} textAnchor="end" className="sky-ax">{top}° max</text>
    </svg>
  )
}

function SkylineFix() {
  const fix = useStore((s) => s.skyFix)
  const opts = useStore((s) => s.skyFixOpts)
  const tool = useStore((s) => s.tool)
  const siteId = useStore((s) => s.siteId)
  const set = useStore((s) => s.set)
  const [check, setCheck] = useState(null)
  const [busy, setBusy] = useState(false)
  const runCheck = async () => {
    setBusy(true)
    try { setCheck(await api.skylineCheck(siteId, { n: 200, heading_known: opts.heading_known, noise_deg: opts.noise_deg })) } catch (e) { useStore.getState().notify(e.message, 'error') }
    setBusy(false)
  }
  const f = fix?.fix
  return (
    <div className="section">
      <h3><span><LocateFixed size={11} style={{ verticalAlign: -1 }} /> No GPS: fix from the skyline</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>There is no GPS on Mars and no compass (no global magnetic field). The helmet matches the skyline it sees against the stored horizon of every 4 m cell, as Perseverance has done since 2026. Pick where you really stand: the helmet sees that skyline, with noise, and finds the best fit.</p>
        <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
          <button className={`btn sm ${tool === 'skyfix' ? 'on' : ''}`} onClick={() => set({ tool: tool === 'skyfix' ? 'select' : 'skyfix' })}><Compass size={13} /> Pick a spot</button>
          <label className="row" style={{ gap: 5, fontSize: 12 }}><input type="checkbox" checked={opts.heading_known} onChange={(e) => set({ skyFixOpts: { ...opts, heading_known: e.target.checked } })} /> Sun compass (heading known ±10°)</label>
        </div>
        <label className="field" style={{ marginTop: 6 }}>
          <span>Skyline measurement noise <b>{opts.noise_deg.toFixed(1)}°</b></span>
          <input type="range" min="0.1" max="2" step="0.1" value={opts.noise_deg} onChange={(e) => set({ skyFixOpts: { ...opts, noise_deg: +e.target.value } })} />
        </label>
        {fix && (
          <>
            <div className="wh-stats">
              <div><b>{fmtNum(fix.error_m, 0)} m</b><span>off the truth</span></div>
              <div><b>±{fmtNum(f.r95_m, 0)} m</b><span>95 % circle</span></div>
              <div><b>{f.heading_err_deg > 0 ? '+' : ''}{fmtNum(f.heading_err_deg, 1)}°</b><span>heading error</span></div>
            </div>
            <SkylineStrip az={fix.az} observed={fix.observed} stored={fix.stored_at_fix} features={fix.features} />
            <p className="hint">Dots: the skyline the helmet measured. Shaded: the stored skyline where the fix landed. {f.r95_m > 60 ? 'A featureless spot: many places look the same, so the circle is wide.' : 'A distinctive skyline: the fix is tight.'}{f.alternatives?.length ? ` ${f.alternatives.length} other places fit less well (orange rings).` : ''}</p>
          </>
        )}
        <div className="row between" style={{ marginTop: 6 }}>
          <button className="btn sm" disabled={busy} onClick={runCheck}>{busy ? 'Checking…' : 'Check over 200 random places'}</button>
          <button className={`btn sm ${useStore.getState().layers.skyline_fix?.on ? 'on' : ''}`} onClick={() => { const s = useStore.getState(); s.setLayer('skyline_fix', { on: !s.layers.skyline_fix?.on }) }}>Fix-quality layer</button>
        </div>
        {check && (
          <p className="hint">Median error <b>{check.median_m} m</b>, 90 % within {check.p90_m} m, {Math.round(check.within_20m * 100)} % within 20 m; the 95 % circle held in {Math.round(check.circle_holds * 100)} % of {check.n} tries ({check.noise_deg}° noise{check.heading_known ? ', sun compass' : ', heading unknown'}). The truth comes from the same terrain model, so real panoramas will do worse.</p>
        )}
      </div>
    </div>
  )
}

function FallbackCard() {
  const plan = useStore((s) => s.plan)
  const vectors = useStore((s) => s.vectors)
  const toggleVector = useStore((s) => s.toggleVector)
  return (
    <div className="section">
      <h3><span><FileWarning size={11} style={{ verticalAlign: -1 }} /> HUD failure: walk home with a card</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>If the visor display dies, the crew walks home on paper. For every leg the card gives the <b>shadow clock</b> (“keep your shadow at 4 o'clock”), the landmarks' clock positions, a <b>pace count</b> and the grid squares; at every station a <b>skyline sketch</b> to recognise it by.</p>
        <div className="row" style={{ gap: 6 }}>
          <button className="btn sm primary" disabled={!plan} onClick={() => openPlanDoc('fallback-card', 'fallback_card', 'fallback card')}>Open the fallback card</button>
          <button className={`btn sm ${vectors.grid ? 'on' : ''}`} onClick={() => toggleVector('grid')}><Grid3x3 size={13} /> Radio grid</button>
        </div>
        <p className="hint">The radio grid: 250 m squares, lettered west to east and numbered north to south, as on Apollo traverse maps, so a position can be said over the radio (“Kilo seven”). Inspect shows the square of any point. The visor-dark drill itself runs in the helmet (Godot console).</p>
      </div>
    </div>
  )
}

export default function BreaksPanel() {
  return (
    <>
      <p className="hint" style={{ marginTop: 0 }}>Other planners assume the plan holds. These tools are for the moments it doesn't.</p>
      <EmergencySection />
      <SkylineFix />
      <FallbackCard />
    </>
  )
}
