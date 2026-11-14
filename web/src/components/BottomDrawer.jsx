import React, { useMemo, useState } from 'react'
import { ChevronDown, ChevronUp, Clock, FlaskConical, GitCompareArrows, Mountain, Route, Square, Table2, Volume2, Wind } from 'lucide-react'
import { useStore } from '../store.js'
import { api, walkParams } from '../api.js'
import XYChart, { Legend } from './charts/XYChart.jsx'
import { fmtDist, fmtDur, fmtNum } from '../lib/format.js'
import { hms } from '../lib/mars24.js'

const HAZARD_COLORS = ['transparent', '#fab219', '#ec835a', '#d03b3b', '#9b30c8']
const HAZARD_NAMES = ['Easy', 'Moderate', 'Difficult', 'Hazardous', 'No-go']
const COMMS_COLORS = ['#d03b3b', '#fab219', 'transparent']
const COMMS_NAMES = ['Dead zone', 'Marginal', 'Line of sight']
const SERIES = ['var(--series-1)', 'var(--series-2)', 'var(--series-3)', 'var(--series-4)']

function Empty({ text }) {
  return <div className="row" style={{ height: '100%', justifyContent: 'center', color: 'var(--muted)' }}>{text}</div>
}

function stopMarkers(profile) {
  const out = []
  for (let i = 1; i < profile.leg.length; i++) {
    if (profile.leg[i] !== profile.leg[i - 1]) out.push({ x: profile.d[i] / 1000, label: String(profile.leg[i]) })
  }
  return out
}

function ProfileTab() {
  const plan = useStore((s) => s.plan)
  const hoverD = useStore((s) => s.hoverD)
  const set = useStore((s) => s.set)
  const [table, setTable] = useState(false)
  if (!plan) return <Empty text="Plan an EVA to see its elevation profile." />
  const p = plan.profile
  const x = p.d.map((d) => d / 1000)
  const t = plan.totals
  return (
    <div style={{ display: 'grid', gridTemplateRows: 'auto 1fr', height: '100%', gap: 6 }}>
      <div className="row between">
        <div>
          <span className="chart-title">Elevation along the route</span>{' '}
          <span className="chart-sub">{fmtDist(t.dist_m)} · +{fmtNum(t.ascent_m)} m / −{fmtNum(t.descent_m)} m · steepest {t.max_slope}° · hover to sync the map</span>
        </div>
        <div className="row">
          <Legend items={[...HAZARD_NAMES.slice(1).map((n, i) => ({ label: n, color: HAZARD_COLORS[i + 1], swatch: true })), { label: 'No radio LOS', color: COMMS_COLORS[0], swatch: true }]} />
          <button className={`btn sm ${table ? 'on' : ''}`} onClick={() => setTable(!table)}><Table2 size={13} /> Table</button>
        </div>
      </div>
      {table ? (
        <div className="scroll" style={{ overflow: 'auto' }}>
          <table className="table-view">
            <thead><tr><th>Distance</th><th>Elevation (m)</th><th>Slope (°)</th><th>Grade</th><th>T+</th><th>Walk-back</th><th>Hazard</th><th>Radio</th></tr></thead>
            <tbody>
              {p.d.filter((_, i) => i % Math.max(1, Math.round(p.d.length / 120)) === 0).map((d, k) => {
                const i = p.d.indexOf(d)
                return (
                  <tr key={k}><td>{fmtDist(d)}</td><td>{p.z[i].toFixed(1)}</td><td>{p.slope[i]}</td><td>{(p.grade[i] * 100).toFixed(0)} %</td>
                    <td>{fmtDur(p.t[i])}</td><td>{p.walkback_min[i] ?? '—'} min</td><td>{HAZARD_NAMES[p.hazard[i]]}</td><td>{COMMS_NAMES[p.comms[i]]}</td></tr>
                )
              })}
            </tbody>
          </table>
        </div>
      ) : (
        <XYChart
          x={x}
          series={[{ id: 'z', color: 'var(--series-1)', values: p.z, area: true }]}
          yFmt={(v) => fmtNum(v)}
          xFmt={(v) => `${v.toFixed(v < 1 ? 1 : 1)} km`}
          yLabel="Elevation (m)"
          hoverX={hoverD != null ? hoverD / 1000 : null}
          onHover={(v) => set({ hoverD: v == null ? null : v * 1000 })}
          markers={stopMarkers(p)}
          strips={[
            { label: 'Hazard', values: p.hazard, colors: HAZARD_COLORS },
            { label: 'Radio', values: p.comms, colors: COMMS_COLORS },
            ...(p.sunlit ? [{ label: 'Shade', values: p.sunlit.map((v) => (v ? 0 : 1)), colors: ['transparent', '#3b4f9e'] }] : []),
            ...(p.terrain_conf ? [{ label: 'DTM', values: p.terrain_conf.map((v) => (v == null ? 0 : v < 0.3 ? 2 : v < 0.6 ? 1 : 0)), colors: ['transparent', '#fdae61', '#d7191c'] }] : []),
          ]}
          tooltip={(i) => ({
            head: `${fmtDist(p.d[i])} · T+${fmtDur(p.t[i], { short: true })}`,
            rows: [
              { label: 'Elevation', value: `${fmtNum(p.z[i], 1)} m`, color: 'var(--series-1)' },
              { label: 'Slope', value: `${p.slope[i]}°` },
              { label: 'Grade', value: `${(p.grade[i] * 100).toFixed(0)} %` },
              { label: 'Walk back', value: p.walkback_min[i] != null ? `${p.walkback_min[i]} min` : '—' },
              { label: 'Hazard', value: HAZARD_NAMES[p.hazard[i]], color: HAZARD_COLORS[p.hazard[i]] },
              { label: 'Radio', value: COMMS_NAMES[p.comms[i]], color: COMMS_COLORS[p.comms[i]] },
            ],
          })}
        />
      )}
    </div>
  )
}

function Segments({ events, total }) {
  const colorOf = (k) => (k === 'walk' ? 'var(--series-1)' : k === 'stop' ? 'var(--series-2)' : k === 'drive' ? '#2f9e5b' : 'var(--series-3)')
  const [hover, setHover] = useState(null)
  return (
    <div style={{ position: 'relative' }}>
      <div style={{ display: 'flex', gap: 2, height: 28 }}>
        {events.map((e, i) => {
          const share = (e.t1 - e.t0) / total
          const pct = share * 100
          return (
            <div key={i} tabIndex={0} onPointerEnter={() => setHover(i)} onPointerLeave={() => setHover(null)} onFocus={() => setHover(i)} onBlur={() => setHover(null)}
              aria-label={`${e.name}: ${fmtDur(e.t1 - e.t0)}`}
              style={{ flex: `${pct} 0 0`, background: colorOf(e.kind), borderRadius: 4, minWidth: 2, display: 'flex', alignItems: 'center', padding: '0 6px', overflow: 'hidden', opacity: hover == null || hover === i ? 1 : 0.6, cursor: 'default' }}>
              {pct > 9 && <span style={{ color: '#fff', fontSize: 10.5, fontWeight: 650, whiteSpace: 'nowrap' }}>{e.kind === 'walk' ? fmtDur(e.t1 - e.t0, { short: true }) : e.kind === 'drive' ? `PR-2 ${fmtDur(e.t1 - e.t0, { short: true })}` : e.name.replace('(airlock)', '').replace(/\s*\(PR-2\)/, '').trim()}</span>}
            </div>
          )
        })}
      </div>
      {hover != null && (
        <div className="tooltip" style={{ top: 34, left: `${Math.min(80, (events[hover].t0 / total) * 100)}%` }}>
          <div className="t-head">{hms(events[hover].t0_ltst, false)} → {hms(events[hover].t1_ltst, false)} LTST</div>
          <div className="t-row"><i className="key" style={{ background: colorOf(events[hover].kind) }} /><span>{events[hover].name}</span><b>{fmtDur(events[hover].t1 - events[hover].t0)}</b></div>
          {events[hover].dist_m != null && <div className="t-row"><i /><span>Distance</span><b>{fmtDist(events[hover].dist_m)}</b></div>}
        </div>
      )}
    </div>
  )
}

function TimelineTab() {
  const plan = useStore((s) => s.plan)
  if (!plan) return <Empty text="Plan an EVA to see its timeline." />
  const { events, sim, totals } = plan
  const tmin = sim.t.map((t) => t / 60)
  const stopBands = events.filter((e) => e.kind === 'stop').map((e) => ({ x0: e.t0 / 60, x1: e.t1 / 60, color: 'rgba(217, 89, 38, 0.10)' }))
  // predicted CME arrival windows at Mars (DONKI, +/- uncertainty), clipped to the EVA
  const cme = (plan.space_weather?.arrivals || []).filter((a) => a.t1_rel_s > 0 && a.t0_rel_s < totals.total_s)
  const cmeBands = cme.map((a) => ({ x0: Math.max(0, a.t0_rel_s) / 60, x1: Math.min(totals.total_s, a.t1_rel_s) / 60, color: a.glancing ? 'rgba(250, 178, 25, 0.14)' : 'rgba(208, 59, 59, 0.16)' }))
  // terrain shadow while the sun is up (from the suit simulation's 30 s steps)
  const shadeBands = []
  if (sim.shade) {
    let i0 = null
    sim.shade.forEach((v, i) => {
      if (v && i0 == null) i0 = i
      if ((!v || i === sim.shade.length - 1) && i0 != null) { shadeBands.push({ x0: tmin[i0], x1: tmin[i], color: 'rgba(59, 79, 158, 0.22)' }); i0 = null }
    })
  }
  const bands = [...cmeBands, ...shadeBands, ...stopBands]
  const tip = (label, arr, unit) => (i) => ({ head: `T+${fmtDur(sim.t[i], { short: true })} · ${hms(sim.ltst[i], false)} LTST`, rows: [{ label, value: `${arr[i]}${unit}`, color: 'var(--series-1)' }] })
  return (
    <div style={{ display: 'grid', gridTemplateRows: 'auto auto 1fr', height: '100%', gap: 8 }}>
      <div className="row between">
        <div>
          <span className="chart-title">EVA timeline</span>{' '}
          <span className="chart-sub">{hms(totals.start_ltst, false)} → {hms(events[events.length - 1].t1_ltst, false)} LTST · {totals.rover ? `${fmtDur(totals.total_s)} · ${fmtDur(totals.suit_s)} suited` : `${fmtDur(totals.total_s)} suited`} · sunset {totals.terrain_sunset_ltst ? `${hms(totals.terrain_sunset_ltst, false)} behind the terrain (flat ${hms(totals.sunset_ltst, false)})` : totals.sunset_ltst ? hms(totals.sunset_ltst, false) : '—'}{totals.shade_min > 0 ? ` · ${fmtNum(totals.shade_min)} min in terrain shadow` : ''}</span>
        </div>
        <Legend items={[{ label: 'Walking', color: 'var(--series-1)', swatch: true }, { label: 'Working at stop', color: 'var(--series-2)', swatch: true }, { label: totals.rover ? 'Airlock / suitport' : 'Airlock', color: 'var(--series-3)', swatch: true }, ...(totals.rover ? [{ label: 'PR-2 drive', color: '#2f9e5b', swatch: true }] : []), ...(cme.length ? [{ label: `CME window (±${plan.space_weather.uncertainty_h} h)`, color: 'rgba(208, 59, 59, 0.55)', swatch: true }] : []), ...(shadeBands.length ? [{ label: 'Terrain shadow', color: 'rgba(59, 79, 158, 0.6)', swatch: true }] : [])]} />
      </div>
      <Segments events={events} total={totals.total_s} />
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 18, minHeight: 0 }}>
        <div style={{ display: 'grid', gridTemplateRows: 'auto 1fr', minHeight: 0 }}>
          <div className="chart-sub">Sun elevation (°)</div>
          <XYChart x={tmin} series={[{ id: 'sun', color: 'var(--series-1)', values: sim.sun_elev, area: true }]} bands={bands}
            xFmt={(v) => `${Math.round(v)}m`} yFmt={(v) => `${v}°`} yLabel="Sun elevation" minY={0}
            thresholds={[{ y: 0, color: 'var(--axis)' }]} tooltip={tip('Sun elevation', sim.sun_elev, '°')} />
        </div>
        <div style={{ display: 'grid', gridTemplateRows: 'auto 1fr', minHeight: 0 }}>
          <div className="chart-sub">Air temperature at 1.5 m (°C, climatology)</div>
          <XYChart x={tmin} series={[{ id: 'air', color: 'var(--series-1)', values: sim.air_c }]} bands={bands}
            xFmt={(v) => `${Math.round(v)}m`} yFmt={(v) => `${v}°`} yLabel="Air temperature" tooltip={tip('Air', sim.air_c, ' °C')} />
        </div>
      </div>
    </div>
  )
}

function ConsumablesTab() {
  const plan = useStore((s) => s.plan)
  const [table, setTable] = useState(false)
  const data = useMemo(() => {
    if (!plan) return null
    const s = plan.sim
    return {
      x: s.t.map((t) => t / 60),
      series: [
        { id: 'o2', name: 'O₂', color: SERIES[0], values: s.o2_pct },
        { id: 'batt', name: 'Battery', color: SERIES[1], values: s.battery_pct },
        { id: 'co2', name: 'CO₂ scrubber', color: SERIES[2], values: s.co2_pct.map((v) => 100 - v) },
        { id: 'water', name: 'Cooling water', color: SERIES[3], values: s.water_pct },
      ],
    }
  }, [plan])
  if (!plan) return <Empty text="Plan an EVA to simulate the suit." />
  const s = plan.sim
  const t = plan.totals
  const stopBands = plan.events.filter((e) => e.kind === 'stop').map((e) => ({ x0: e.t0 / 60, x1: e.t1 / 60, color: 'rgba(217, 89, 38, 0.10)' }))
  const minIdx = s.margin_min.indexOf(Math.min(...s.margin_min.filter((v, i) => s.state[i] !== 'airlock')))
  return (
    <div style={{ display: 'grid', gridTemplateRows: 'auto 1fr', height: '100%', gap: 6 }}>
      <div className="row between">
        <div>
          <span className="chart-title">Suit consumables</span>{' '}
          <span className="chart-sub">limiting: {t.limiting} · worst return margin {fmtDur(t.min_margin_min * 60)} at T+{fmtDur(t.min_margin_t, { short: true })}</span>
        </div>
        <div className="row">
          <Legend items={data.series.map((d) => ({ label: d.name, color: d.color }))} />
          <button className={`btn sm ${table ? 'on' : ''}`} onClick={() => setTable(!table)}><Table2 size={13} /> Table</button>
        </div>
      </div>
      {table ? (
        <div className="scroll" style={{ overflow: 'auto' }}>
          <table className="table-view">
            <thead><tr><th>T+</th><th>LTST</th><th>State</th><th>Metabolic</th>{data.series.map((d) => <th key={d.id}>{d.name} %</th>)}<th>Needed to return</th><th>Margin</th></tr></thead>
            <tbody>
              {s.t.filter((_, i) => i % 10 === 0).map((tt, k) => {
                const i = k * 10
                return (
                  <tr key={i}><td>{fmtDur(tt, { short: true })}</td><td>{hms(s.ltst[i], false)}</td><td>{s.state[i]}</td><td>{s.met_w[i]} W</td>
                    {data.series.map((d) => <td key={d.id}>{d.values[i].toFixed(0)}</td>)}<td>{s.need_min[i]} min</td><td>{s.margin_min[i]} min</td></tr>
                )
              })}
            </tbody>
          </table>
        </div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 18, minHeight: 0 }}>
          <div style={{ display: 'grid', gridTemplateRows: 'auto 1fr', minHeight: 0 }}>
            <div className="chart-sub">Remaining (%)</div>
            <XYChart x={data.x} series={data.series} yDomain={[0, 105]} yTicks={[0, 25, 50, 75, 100]} bands={stopBands} endLabels
              xFmt={(v) => `${Math.round(v)}m`} yFmt={(v) => `${v}`} yLabel="Consumables remaining"
              tooltip={(i) => ({ head: `T+${fmtDur(s.t[i], { short: true })} · ${s.state[i]} · ${s.met_w[i]} W`, rows: data.series.map((d) => ({ label: d.name, value: `${d.values[i].toFixed(0)} %`, color: d.color })) })} />
          </div>
          <div style={{ display: 'grid', gridTemplateRows: 'auto 1fr', minHeight: 0 }}>
            <div className="chart-sub">Return margin (min): time left on the limiting consumable − time needed to walk back</div>
            <XYChart x={data.x} series={[{ id: 'm', color: 'var(--series-1)', values: s.margin_min, area: true, areaBase: 0 }]} bands={stopBands}
              thresholds={[{ y: 0, color: 'var(--critical)', label: 'Turn-back line' }]} minY={0}
              markers={minIdx >= 0 ? [{ x: data.x[minIdx], label: '!', fill: 'var(--warning)' }] : []}
              xFmt={(v) => `${Math.round(v)}m`} yFmt={(v) => fmtNum(v)} yLabel="Return margin"
              tooltip={(i) => ({ head: `T+${fmtDur(s.t[i], { short: true })}`, rows: [
                { label: 'Margin', value: `${s.margin_min[i]} min`, color: 'var(--series-1)' },
                { label: 'Limiting supply lasts', value: `${s.limit_min[i]} min` },
                { label: 'Needed to return', value: `${s.need_min[i]} min` },
              ] })} />
          </div>
        </div>
      )}
    </div>
  )
}

function CompareTab() {
  const plan = useStore((s) => s.plan)
  const st = useStore()
  const [leg, setLeg] = useState(0)
  if (!plan) return <Empty text="Plan an EVA first, then compare path-finding algorithms on any leg." />
  const pts = [st.habitat, ...st.stops, ...(st.returnToHab ? [st.habitat] : [])]
  const run = async () => {
    st.set({ compareLoading: true })
    try {
      const res = await api.route(st.siteId, { a: pts[leg], b: pts[leg + 1], walk: walkParams(st.walk), engines: ['astar', 'dijkstra'], astar_weight: st.astarWeight })
      st.set({ compare: { ...res, leg, show: true }, compareLoading: false })
    } catch (e) {
      st.set({ compareLoading: false })
      st.notify(e.message, 'error')
    }
  }
  const res = st.compare?.leg === leg ? st.compare.results : null
  const rows = [
    ['Walking time (same directional model)', (r) => fmtDur(r.time_s)],
    ['Distance', (r) => fmtDist(r.dist_m)],
    ['Climb / descent', (r) => `+${r.ascent_m} / −${r.descent_m} m`],
    ['Steepest cell', (r) => `${r.max_slope}°`],
    ['Cells expanded', (r) => fmtNum(r.expansions)],
    ['Compute time', (r) => `${fmtNum(r.compute_ms)} ms`],
  ]
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '300px 1fr', gap: 18, height: '100%' }}>
      <div>
        <div className="chart-title">Algorithm comparison</div>
        <p className="chart-sub" style={{ lineHeight: 1.5 }}>Runs our hand-written A* (direction-aware costs) and scikit-image's MCP Dijkstra (cost per cell) on the same 2 m grid, then scores both paths with the same walking model.</p>
        <div className="row" style={{ marginTop: 8 }}>
          <select className="input" value={leg} onChange={(e) => setLeg(+e.target.value)} style={{ background: '#0b1017', border: '1px solid var(--line-2)', borderRadius: 8, padding: 6 }}>
            {plan.legs.map((L, i) => <option key={i} value={i}>{L.from} → {L.to}</option>)}
          </select>
          <button className="btn primary" onClick={run} disabled={st.compareLoading}><FlaskConical size={14} /> {st.compareLoading ? 'Running…' : 'Run'}</button>
        </div>
        {st.compare && (
          <label className="row" style={{ marginTop: 10, gap: 6, fontSize: 12, color: 'var(--text-2)' }}>
            <input type="checkbox" checked={!!st.compare.show} onChange={(e) => st.set({ compare: { ...st.compare, show: e.target.checked } })} /> Show both paths on the map
          </label>
        )}
        <Legend items={[{ label: 'A* (ours)', color: '#4fd1ff' }, { label: 'Dijkstra (MCP)', color: '#ff5fa2' }]} />
      </div>
      <div className="scroll" style={{ overflow: 'auto' }}>
        {res ? (
          <table className="table-view">
            <thead><tr><th>Metric</th>{res.map((r) => <th key={r.engine}>{r.engine === 'astar' ? 'A* (ours)' : 'Dijkstra (MCP)'}</th>)}</tr></thead>
            <tbody>
              {rows.map(([label, f]) => <tr key={label}><td>{label}</td>{res.map((r) => <td key={r.engine}>{r.ok ? f(r) : 'no route'}</td>)}</tr>)}
            </tbody>
          </table>
        ) : <Empty text="Pick a leg and press Run." />}
        {res && res.every((r) => r.ok) && (
          <p className="hint" style={{ marginTop: 10 }}>
            {(() => {
              const a = res.find((r) => r.engine === 'astar')
              const d = res.find((r) => r.engine === 'dijkstra')
              const diff = d.time_s - a.time_s
              return diff > 1
                ? `A*'s route is ${fmtDur(diff)} (${((diff / d.time_s) * 100).toFixed(1)} %) faster to walk, because it plans uphill and downhill separately.`
                : 'Both engines found routes of about the same walking time on this leg.'
            })()}
          </p>
        )}
      </div>
    </div>
  )
}

// Pace notes and the strip map (feature D3): each leg unrolled as a straight strip, like a rally co-driver's roll or
// an Apollo cuff card. The walker's left is the top edge. Hovering the strip moves the marker on the map.
const NOTE_COLORS = { turn: '#4fd1ff', boulder: '#ff8a3d', climb: '#f2f2f2', descent: '#f2f2f2', hazard: '#d03b3b', sand: '#e0c070', radio: '#ff5fa2', shade: '#9aa3b8', note: '#cfd6e0' }

function legSamples(p, i) {
  const idx = []
  for (let k = 0; k < p.leg.length; k++) if (p.leg[k] === i && !(p.working && p.working[k])) idx.push(k)
  return idx
}

function noteParts(n) {
  return n.text.replace(/^\d+ m: /, '').split(', then ').map((t) => {
    let m = t.match(/^(left|right) (\d+)°/)
    if (m) return { kind: 'turn', side: m[1], deg: +m[2], text: t }
    m = t.match(/([\d.]+) m boulder (left|right)/)
    if (m) return { kind: 'boulder', side: m[2], size: +m[1], text: t }
    m = t.match(/^(\d+)° (up|down)/)
    if (m) return { kind: m[2] === 'up' ? 'climb' : 'descent', deg: +m[1], text: t }
    const kind = /radio/.test(t) ? 'radio' : /shadow/.test(t) ? 'shade' : /sand/.test(t) ? 'sand' : /hazard/.test(t) ? 'hazard' : 'note'
    return { kind, text: t }
  })
}

const spoken = (text) => text.replace(/(\d+(?:\.\d+)?) m\b/g, '$1 metres').replace(/°/g, ' degrees')

function StripTab() {
  const plan = useStore((s) => s.plan)
  const hoverD = useStore((s) => s.hoverD)
  const set = useStore((s) => s.set)
  const [leg, setLeg] = useState(0)
  const [speaking, setSpeaking] = useState(false)
  const notes = plan?.pace_notes
  const p = plan?.profile
  const i = notes?.length ? Math.min(leg, notes.length - 1) : 0
  const geo = useMemo(() => {
    if (!p || !notes?.length) return null
    const idx = legSamples(p, i)
    if (idx.length < 2) return null
    const d0 = p.d[idx[0]]
    const len = Math.max(1, p.d[idx[idx.length - 1]] - d0)
    const pct = (d) => Math.min(100, Math.max(0, (d / len) * 100))
    const bands = { hazard: [], radio: [], shade: [] }
    for (let j = 0; j < idx.length - 1; j++) {
      const k = idx[j]
      const a = pct(p.d[k] - d0)
      const w = Math.max(0.15, pct(p.d[idx[j + 1]] - d0) - a)
      if (p.hazard[k] > 0) bands.hazard.push({ a, w, c: HAZARD_COLORS[p.hazard[k]] })
      if (p.comms[k] < 2) bands.radio.push({ a, w, c: p.comms[k] === 0 ? '#d03b3b' : '#fab219' })
      if (p.sunlit && !p.sunlit[k]) bands.shade.push({ a, w })
    }
    const step = len > 900 ? 200 : len > 400 ? 100 : 50
    const ticks = []
    for (let d = 0; d <= len + 0.1; d += step) ticks.push(d)
    return { d0, len, pct, bands, ticks }
  }, [p, notes, i])
  if (!plan || !notes?.length) return <Empty text="Plan an EVA to unroll its route as a strip with pace notes." />
  const pn = notes[i]
  const say = () => {
    const synth = window.speechSynthesis
    if (!synth) { useStore.getState().notify('This browser cannot speak', 'info'); return }
    synth.cancel()
    if (speaking) { setSpeaking(false); return }
    const lines = [`${pn.from} to ${pn.to}, ${Math.round(pn.dist_m)} metres.`, ...pn.notes.map((n) => spoken(n.text))]
    lines.forEach((t, k) => {
      const u = new SpeechSynthesisUtterance(t)
      u.rate = 1.05
      if (k === lines.length - 1) { u.onend = () => setSpeaking(false); u.onerror = () => setSpeaking(false) }
      synth.speak(u)
    })
    setSpeaking(true)
  }
  const hoverPct = geo && hoverD != null && hoverD >= geo.d0 && hoverD <= geo.d0 + geo.len ? geo.pct(hoverD - geo.d0) : null
  const onMove = (e) => {
    const r = e.currentTarget.getBoundingClientRect()
    set({ hoverD: geo.d0 + Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)) * geo.len })
  }
  return (
    <div className="strip-tab">
      <div className="strip-main">
        <div className="row between" style={{ gap: 8, flexWrap: 'wrap' }}>
          <div>
            <span className="chart-title">Strip map</span>{' '}
            <span className="chart-sub">{fmtDist(pn.dist_m)} unrolled · your left is the top edge · hover to find a spot on the map</span>
          </div>
          <div className="row" style={{ gap: 6 }}>
            <select className="input" value={i} onChange={(e) => { window.speechSynthesis?.cancel(); setSpeaking(false); setLeg(+e.target.value) }} aria-label="Leg">
              {notes.map((L, k) => <option key={k} value={k}>{k + 1}. {L.from} → {L.to}</option>)}
            </select>
            <button className={`btn sm ${speaking ? 'on' : ''}`} onClick={say} title="Read the pace notes aloud">
              {speaking ? <Square size={12} /> : <Volume2 size={13} />} {speaking ? 'Stop' : 'Co-driver'}
            </button>
          </div>
        </div>
        {geo ? (
          <div className="strip" onMouseMove={onMove} onMouseLeave={() => set({ hoverD: null })} role="img"
            aria-label={`Strip map of ${pn.from} to ${pn.to}: ${pn.notes.length} pace notes`}>
            <span className="strip-lab" style={{ top: 2 }}>RADIO</span>
            <span className="strip-lab" style={{ top: 15 }}>SHADE</span>
            <div className="strip-band" style={{ top: 4, height: 7 }}>{geo.bands.radio.map((b, k) => <i key={k} style={{ left: `${b.a}%`, width: `${b.w}%`, background: b.c }} />)}</div>
            <div className="strip-band" style={{ top: 17, height: 7 }}>{geo.bands.shade.map((b, k) => <i key={k} style={{ left: `${b.a}%`, width: `${b.w}%`, background: '#5b6478' }} />)}</div>
            <div className="strip-road">{geo.bands.hazard.map((b, k) => <i key={k} style={{ left: `${b.a}%`, width: `${b.w}%`, background: b.c }} />)}</div>
            {pn.notes.map((n, k) => {
              const left = geo.pct(n.d)
              const parts = noteParts(n)
              // badges of notes close together alternate between two heights so their numbers stay readable
              const low = k > 0 && left - geo.pct(pn.notes[k - 1].d) < 4.5 && k % 2 === 1
              return (
                <React.Fragment key={k}>
                  <span className="strip-tick" style={{ left: `${left}%`, borderColor: NOTE_COLORS[parts[0].kind] }} />
                  <span className={`strip-num ${low ? 'low' : ''}`} style={{ left: `${left}%` }}>{k + 1}</span>
                  {parts.filter((q) => q.kind === 'boulder').map((q, m) => (
                    <span key={`b${m}`} className="strip-boulder" title={q.text}
                      style={{ left: `${left}%`, top: q.side === 'left' ? 31 : 82, width: 6 + Math.min(10, q.size * 2), height: 6 + Math.min(10, q.size * 2) }} />
                  ))}
                  {parts.filter((q) => q.kind === 'turn').map((q, m) => (
                    <span key={`t${m}`} className="strip-turn" style={{ left: `${left}%` }} title={q.text}>{q.side === 'left' ? '↰' : '↱'}<small>{q.deg}°</small></span>
                  ))}
                  {parts.filter((q) => q.kind === 'climb' || q.kind === 'descent').map((q, m) => (
                    <span key={`c${m}`} className="strip-turn" style={{ left: `${left}%` }} title={q.text}>{q.kind === 'climb' ? '▲' : '▼'}<small>{q.deg}°</small></span>
                  ))}
                </React.Fragment>
              )
            })}
            {geo.ticks.map((d) => <span key={d} className="strip-axis" style={{ left: `${geo.pct(d)}%` }}>{d} m</span>)}
            {hoverPct != null && <span className="strip-hover" style={{ left: `${hoverPct}%` }} />}
          </div>
        ) : <Empty text="This leg is too short for a strip." />}
        <Legend items={[{ label: 'Boulder (size to scale)', color: '#ff8a3d' }, { label: 'Turn', color: '#4fd1ff' }, { label: 'Radio shadow', color: '#d03b3b' }, { label: 'Terrain shadow', color: '#5b6478' }, { label: 'Hazardous ground', color: HAZARD_COLORS[3] }]} />
      </div>
      <ol className="strip-notes scroll" aria-label="Pace notes">
        {pn.notes.length === 0 && <li className="muted">A clean leg: no notes.</li>}
        {pn.notes.map((n, k) => (
          <li key={k} onMouseEnter={() => set({ hoverD: geo ? geo.d0 + n.d : null })} onMouseLeave={() => set({ hoverD: null })}>
            <b>{k + 1}</b>
            <span>{n.text}</span>
          </li>
        ))}
      </ol>
    </div>
  )
}

const TABS = [
  { id: 'profile', label: 'Elevation profile', icon: Mountain, C: ProfileTab },
  { id: 'strip', label: 'Strip map', icon: Route, C: StripTab },
  { id: 'timeline', label: 'Timeline & sun', icon: Clock, C: TimelineTab },
  { id: 'consumables', label: 'Suit consumables', icon: Wind, C: ConsumablesTab },
  { id: 'compare', label: 'A* vs Dijkstra', icon: GitCompareArrows, C: CompareTab },
]

export default function BottomDrawer() {
  const drawer = useStore((s) => s.drawer)
  const set = useStore((s) => s.set)
  const T = TABS.find((t) => t.id === drawer)
  return (
    <section className="drawer" aria-label="Analysis drawer">
      <div className="drawer-tabs" role="tablist">
        {TABS.map(({ id, label, icon: Icon }) => (
          <button key={id} className={drawer === id ? 'on' : ''} onClick={() => set({ drawer: drawer === id ? null : id })} role="tab" aria-selected={drawer === id}>
            <Icon size={14} /> {label}
          </button>
        ))}
        <span className="grow" />
        <button onClick={() => set({ drawer: drawer ? null : 'profile' })} aria-label={drawer ? 'Collapse' : 'Expand'}>
          {drawer ? <ChevronDown size={16} /> : <ChevronUp size={16} />}
        </button>
      </div>
      <div className={`drawer-body ${T ? '' : 'closed'}`}>{T && <T.C />}</div>
    </section>
  )
}
