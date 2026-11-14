import React from 'react'
import { AlertTriangle, CheckCircle2, Info, MapPin, OctagonX, Radio, Sun, X } from 'lucide-react'
import { useStore } from '../store.js'
import { compass } from '../lib/geo.js'
import { fmtDist, fmtDur, fmtLonLat, fmtNum } from '../lib/format.js'
import { hms } from '../lib/mars24.js'
import { api } from '../api.js'
import ChemBars from './ChemBars.jsx'

const HAZ = ['Easy', 'Moderate', 'Difficult', 'Hazardous', 'No-go']
const HAZ_TAG = ['ok', 'warn', 'warn', 'bad', 'bad']
const COMMS = ['Dead zone', 'Marginal', 'Line of sight']

function IssueIcon({ level }) {
  if (level === 'ok') return <CheckCircle2 size={15} color="var(--good-ink)" />
  if (level === 'nogo') return <OctagonX size={15} color="var(--critical-ink)" />
  if (level === 'caution' || level === 'nogo-soft') return <AlertTriangle size={15} color="var(--warning)" />
  return <Info size={15} color="var(--text-2)" />
}

const fmtWhen = (iso) => {
  const d = new Date(iso)
  return `${d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' })} ${d.toISOString().slice(11, 16)} UTC`
}
const relH = (s) => `${s >= 0 ? 'T+' : 'T−'}${fmtDur(Math.abs(s), { short: true })}`

// DONKI's predicted CME arrivals at Mars against the suited window (data-use item D1).
function SpaceWeatherCheck({ sw }) {
  const set = useStore((s) => s.set)
  const drill = useStore((s) => s.cmeDrill)
  const startUtc = useStore((s) => s.startUtc)
  if (!sw) return null
  // CME drill: pretend DONKI forecasts a full hit 90 min into the EVA, pinned to the clock so a new start can clear it
  const drillBtn = (
    <button className={`btn sm ${drill ? 'on' : ''}`} style={{ marginTop: 8 }}
      onClick={() => set({ cmeDrill: drill ? null : new Date(new Date(startUtc).getTime() + 90 * 60000).toISOString() })}
      title="What if DONKI forecast a full-hit CME at Mars 90 minutes into the EVA? The plan turns NO-GO and offers the first clear start.">
      {drill ? 'End CME drill' : 'CME drill'}
    </button>
  )
  if (!sw.checked) {
    return <><p className="hint">{sw.source === 'off' ? 'Space weather check is off for this plan.' : 'Space weather not checked: NASA DONKI is unreachable and nothing is cached.'}</p>{drillBtn}</>
  }
  const near = sw.arrivals.filter((a) => a.overlap)
  return (
    <div className="card" style={{ marginTop: 8 }}>
      <div className="row between">
        <b style={{ fontSize: 12.5 }}><Sun size={13} style={{ verticalAlign: -2 }} /> CME forecasts at Mars</b>
        <span className="tag">{sw.source === 'live' ? 'DONKI live' : sw.source === 'cache' ? `DONKI cache${sw.cache_age_min != null ? ` · ${Math.round(sw.cache_age_min)} min old` : ''}` : drill ? 'CME drill' : 'what-if'}</span>
      </div>
      {near.length === 0 ? (
        <p className="hint" style={{ margin: '6px 0 0' }}>No predicted arrival within ±{sw.uncertainty_h} h of the time in suits{sw.arrivals.length ? ` (${sw.arrivals.length} within two sols)` : ''}.</p>
      ) : (
        <ul className="issues" style={{ marginTop: 6 }}>
          {near.map((a, i) => (
            <li key={i}><IssueIcon level={a.level} /><span>{a.glancing ? 'Glancing blow' : 'Full hit'} forecast {fmtWhen(a.arrival)} ({relH(a.t_rel_s)}){a.overlap === 'inside' ? ', during the EVA' : `, ±${sw.uncertainty_h} h window overlaps the EVA`}{a.speed_kms ? ` · ${Math.round(a.speed_kms)} km/s` : ''}</span></li>
          ))}
        </ul>
      )}
      {sw.suggested && (
        <button className="btn sm primary" style={{ marginTop: 8 }} onClick={() => set({ startUtc: sw.suggested.start_utc })}
          title="Move the EVA start to the first time whose suited window clears every arrival window and still ends 30 min before sunset">
          Start sol {sw.suggested.mission_sol} at {hms(sw.suggested.start_ltst, false)} LTST ({sw.suggested.delay_h >= 0 ? '+' : ''}{Math.round(sw.suggested.delay_h)} h)
        </button>
      )}
      <p className="hint" style={{ margin: '6px 0 0' }}>WSA-ENLIL arrival forecasts miss by about 10 h at Earth, so each arrival counts as a ±{sw.uncertainty_h} h window.{drill ? ' Drill on: the DONKI forecasts are replaced by one pretend arrival.' : ''}</p>
      {drillBtn}
    </div>
  )
}

const confWord = (v) => (v >= 0.6 ? 'high' : v >= 0.3 ? 'medium' : 'low')
function ConfTag({ v }) {
  return <span className={`tag ${v >= 0.6 ? 'ok' : v >= 0.3 ? 'warn' : 'bad'}`}>{confWord(v)} ({fmtNum(v * 100)} %)</span>
}

// Terrain sunrise/sunset where the EVA ends, and the stretches walked in terrain shadow (data-use item D4).
function SunCheck({ plan }) {
  const t = plan.totals
  const shade = plan.sun?.shade || []
  if (!t.terrain_sunset_ltst) return null
  return (
    <div className="section">
      <h3>Sun over the terrain</h3>
      <div className="card">
        <div className="row between" style={{ fontSize: 12 }}>
          <span>At {plan.sun?.haven_name === 'Hab' ? 'the hab' : plan.sun?.haven_name}: sun up <b className="mono">{hms(t.terrain_sunrise_ltst, false)}</b> → <b className="mono">{hms(t.terrain_sunset_ltst, false)}</b></span>
          <span className="muted mono">flat {hms(t.sunrise_ltst, false)}–{hms(t.sunset_ltst, false)}</span>
        </div>
        <p className="hint" style={{ margin: '6px 0 0' }}>
          {shade.length ? `${fmtNum(t.shade_min)} min of the walk in terrain shadow (${shade.length} stretch${shade.length > 1 ? 'es' : ''}); the heater adds ${fmtNum(t.shade_heater_wh)} Wh.` : 'No terrain shadow on the route at these times.'}
          {' '}The sunset rule uses the real horizon at the end point.
        </p>
      </div>
    </div>
  )
}

// What the plan rests on that is uncertain [NASA-STD-3001 V2 10161] (data-use item D7).
function Uncertainty({ plan }) {
  const t = plan.totals
  const rc = t.route_confidence || {}
  const mc = t.margin_cases || {}
  if (!t.margin_range_min) return null
  return (
    <div className="section">
      <h3>Uncertainty</h3>
      <div className="card">
        <div className="row between" style={{ fontSize: 12 }}>
          <span>Worst return margin</span>
          <b className="mono">{fmtNum(t.margin_range_min[0])}–{fmtNum(t.margin_range_min[1])} min</b>
        </div>
        <p className="hint" style={{ margin: '4px 0 8px' }}>Planning dispersions: metabolic rate {Math.round((mc.pessimistic?.met_scale - 1) * 100)} % up and walking {Math.round((1 - mc.pessimistic?.speed_scale) * 100)} % slower, or {Math.round((1 - mc.optimistic?.met_scale) * 100)} % down and {Math.round((mc.optimistic?.speed_scale - 1) * 100)} % faster. Nominal {fmtNum(t.min_margin_min)} min.</p>
        {rc.terrain_mean != null && (
          <div className="row between" style={{ fontSize: 12 }}><span>Terrain data on the route</span><span><ConfTag v={rc.terrain_mean} /></span></div>
        )}
        {rc.terrain_low_m != null && <p className="hint" style={{ margin: '4px 0 8px' }}>{fmtDist(rc.terrain_low_m)} where our DTM and the rover team's disagree; slopes uncertain by up to ±{fmtNum(rc.slope_unc_p95_deg || 0)}° (95 %).</p>}
        {rc.sand_conf_mean != null && (
          <div className="row between" style={{ fontSize: 12 }}><span>Sand estimate on the route</span><span><ConfTag v={rc.sand_conf_mean} /></span></div>
        )}
        {rc.sand_unsure_m > 0 && <p className="hint" style={{ margin: '4px 0 0' }}>{fmtDist(rc.sand_unsure_m)} of possibly sandy ground where the clues disagree.</p>}
      </div>
    </div>
  )
}

// What lies under this point: the nearest column of Perseverance's ground radar (feature E1).
function RadarNearby({ info }) {
  const site = useStore((s) => s.site)
  const set = useStore((s) => s.set)
  const [d, setD] = React.useState(null)
  React.useEffect(() => {
    setD(null)
    if (!site?.radar || !info?.inside || info.loading) return undefined
    let alive = true
    api.radar(site.id, { lon: info.lon, lat: info.lat, within_m: 40 }).then((r) => { if (alive) setD(r) }).catch(() => {})
    return () => { alive = false }
  }, [site?.id, site?.radar, info?.lon, info?.lat, info?.inside, info?.loading])
  const n = d?.nearest
  if (!n) return null
  return (
    <div style={{ marginTop: 8, fontSize: 12 }}>
      <span className="muted">Under the ground: </span>
      {site.rover_name}'s radar passed {n.dist_m < 2 ? 'here' : `${Math.round(n.dist_m)} m away`} on sol {n.sol}.{' '}
      <button className="btn sm" onClick={() => { if (!useStore.getState().vectors.radar) useStore.getState().toggleVector('radar'); set({ radarView: { run: n.run, i: n.i, cursor: n.i } }) }}>
        See {Math.round(d.depth_m)} m down
      </button>
    </div>
  )
}

// What the rocks near this point are made of: the rover's chemistry at its closest targets (feature E2).
function ChemNearby({ info }) {
  const site = useStore((s) => s.site)
  const [d, setD] = React.useState(null)
  React.useEffect(() => {
    setD(null)
    if (!site?.chemistry || !info?.inside || info.loading) return undefined
    let alive = true
    api.chemistry(site.id, { lon: info.lon, lat: info.lat, n: 2, within_m: 60 }).then((r) => { if (alive) setD(r) }).catch(() => {})
    return () => { alive = false }
  }, [site?.id, site?.chemistry, info?.lon, info?.lat, info?.inside, info?.loading])
  if (!d || !d.targets?.length) return null
  return (
    <div style={{ marginTop: 8 }}>
      <div className="muted" style={{ fontSize: 11, marginBottom: 4 }}>What the rocks here are made of: {d.instrument}, oxides in weight %</div>
      {d.targets.map((t) => (
        <div key={`${t.name}-${t.sol}`} style={{ marginBottom: 6 }}>
          <div style={{ fontSize: 12 }}><span style={{ color: t.color }}>●</span> <b>{t.name}</b> <span className="muted">sol {t.sol} · {Math.round(t.dist_from_m)} m away · {t.hint}</span></div>
          <ChemBars t={t} />
        </div>
      ))}
      <div className="muted" style={{ fontSize: 10.5 }}>Each target sits where {d.rover || 'the rover'} stood that sol ({(d.instrument || 'the laser').split(' ')[0]} reaches about 7 m).</div>
    </div>
  )
}

function PointInfo() {
  const info = useStore((s) => s.pointInfo)
  const set = useStore((s) => s.set)
  if (!info) return null
  return (
    <div className="section">
      <h3><span><MapPin size={11} style={{ verticalAlign: -1 }} /> Point inspector</span><button className="btn ghost icon" onClick={() => set({ pointInfo: null })} aria-label="Close"><X size={13} /></button></h3>
      <div className="card">
        <div className="mono muted" style={{ fontSize: 11, marginBottom: 6 }}>{fmtLonLat(info.lon, info.lat)}</div>
        {info.loading ? <div className="muted">Reading terrain…</div> : !info.inside ? <div className="muted">Outside the mapped site.</div> : (
          <dl className="kv">
            {info.grid_ref && (<><dt>Grid square</dt><dd><b className="mono">{info.grid_ref.ref_fine}</b> <span className="muted">“{info.grid_ref.say}”</span></dd></>)}
            <dt>Elevation</dt><dd>{fmtNum(info.elev, 1)} m</dd>
            <dt>Slope</dt><dd>{fmtNum(info.slope, 1)}°</dd>
            <dt>Roughness</dt><dd>{fmtNum(info.rough, 2)} m</dd>
            <dt>Hazard class</dt><dd><span className={`tag ${HAZ_TAG[info.hazard]}`}>{HAZ[info.hazard]}</span></dd>
            <dt>Loose sand</dt><dd>{fmtNum((info.sand || 0) * 100)} %</dd>
            <dt>Walk back to hab</dt><dd>{info.walkback_min != null ? `${info.walkback_min} min` : 'unreachable'}</dd>
            <dt>Radio to hab</dt><dd>{info.comms != null ? COMMS[info.comms] : '—'}</dd>
            <dt>Terrain shielding</dt><dd>{fmtNum((info.shield || 0) * 100, 1)} %</dd>
            <dt>GCR dose rate</dt><dd>{fmtNum(info.gcr_usv_h, 1)} µSv/h</dd>
            {info.thermal != null && (<><dt>THEMIS night IR</dt><dd>{fmtNum(info.thermal, 0)}</dd></>)}
            {info.thermal_day != null && (<><dt>THEMIS day IR</dt><dd>{fmtNum(info.thermal_day, 0)}</dd></>)}
            {info.geology && (<><dt>Geologic unit</dt><dd><span style={{ display: 'inline-block', width: 9, height: 9, marginRight: 5, background: info.geology.color, verticalAlign: 0 }} />{info.geology.code} · {info.geology.name}</dd></>)}
            {info.sand_conf != null && (<><dt>Sand estimate</dt><dd><ConfTag v={info.sand_conf} /> confidence</dd></>)}
            {info.terrain_conf != null && (<><dt>Terrain data</dt><dd><ConfTag v={info.terrain_conf} /> slope ±{fmtNum(info.slope_unc || 0, 0)}°</dd></>)}
            {info.science != null && (<><dt>Science opportunity</dt><dd>{fmtNum(info.science, 2)}</dd></>)}
            {info.scouted && (<><dt>Seen from the air</dt><dd>Ingenuity flight {info.scouted.flight} · sol {info.scouted.sol}</dd></>)}
            {info.sun?.sunrise_ltst != null && (<><dt>Sun over the terrain</dt><dd>{hms(info.sun.sunrise_ltst, false)} → {hms(info.sun.sunset_ltst, false)}<span className="muted"> (flat {hms(info.sun.flat_sunrise_ltst, false)}–{hms(info.sun.flat_sunset_ltst, false)})</span></dd></>)}
          </dl>
        )}
        {info.inside && info.sand_why && (info.sand_why.for.length > 0 || info.sand_why.against.length > 0) && (
          <div className="muted" style={{ fontSize: 11, marginTop: 6 }}>Sand: {info.sand_why.for.length ? `for: ${info.sand_why.for.join(', ')}` : ''}{info.sand_why.for.length && info.sand_why.against.length ? '; ' : ''}{info.sand_why.against.length ? `against: ${info.sand_why.against.join(', ')}` : ''}</div>
        )}
        {info.inside && info.science_info?.reasons?.length > 0 && (
          <ul className="issues" style={{ marginTop: 6 }}>{info.science_info.reasons.map((r, k) => <li key={k}><Info size={13} color="var(--accent)" /><span>{r.text}</span></li>)}</ul>
        )}
        <ChemNearby info={info} />
        <RadarNearby info={info} />
        {info.inside && info.geology?.interpretation && (
          <div className="muted" style={{ fontSize: 11, marginTop: 6 }}>{info.geology.interpretation} <i>({info.geology.map}, {info.geology.scale})</i></div>
        )}
        {info.inside && info.trek_url && (
          <div style={{ fontSize: 11, marginTop: 6 }}>
            <a href={info.trek_url} target="_blank" rel="noreferrer">Open NASA Mars Trek</a>
            <span className="muted"> and search {fmtNum(info.lat, 5)}, {fmtNum(info.lon, 5)}</span>
          </div>
        )}
      </div>
    </div>
  )
}

export default function RightPanel() {
  const plan = useStore((s) => s.plan)
  const planError = useStore((s) => s.planError)
  const planLoading = useStore((s) => s.planLoading)
  const set = useStore((s) => s.set)
  const open = useStore((s) => s.summaryOpen)
  const t = plan?.totals
  return (
    <aside className={`right ${open ? 'open' : ''}`} aria-label="EVA summary">
      <div className="side-head">
        <div>
          <h2>EVA summary</h2>
          <p>{plan ? `Computed in ${fmtNum(t.compute_ms)} ms · ${t.algorithm === 'astar' ? 'A* (ours)' : 'Dijkstra'}` : planLoading ? 'Computing…' : '—'}</p>
        </div>
        <button className="btn ghost icon tablet-only" onClick={() => set({ summaryOpen: false })} aria-label="Close the EVA summary"><X size={16} /></button>
      </div>
      <div className="side-body">
        <PointInfo />
        {planError && !plan && <div className="card" style={{ borderColor: 'var(--critical)' }}><b>Can't plan this EVA</b><p className="dim" style={{ margin: '6px 0 0' }}>{planError}</p></div>}
        {planError && plan && <div className="card" style={{ borderColor: 'var(--warning)', marginBottom: 10 }}><b>Last change failed</b><p className="dim" style={{ margin: '6px 0 0' }}>{planError}</p></div>}
        {plan && (
          <>
            <div className={`hero ${t.go ? 'go' : 'nogo'}`} style={{ opacity: planLoading ? 0.6 : 1 }}>
              <div className="cap">{t.go ? 'Go for EVA' : 'No-go'}</div>
              <div className="big">{fmtDur(t.total_s)}</div>
              <div className="dim" style={{ fontSize: 12, marginTop: 4 }}>
                {hms(t.start_ltst, false)} → {hms(plan.events[plan.events.length - 1].t1_ltst, false)} LTST · sol {t.mission_sol}
              </div>
            </div>
            <div className="tiles" style={{ marginTop: 10, opacity: planLoading ? 0.6 : 1 }}>
              <div className="tile"><div className="label">Distance</div><div className="value">{fmtDist(t.dist_m)}</div><div className="sub">{plan.legs.length} legs</div></div>
              <div className="tile"><div className="label">Walking</div><div className="value">{fmtDur(t.walk_s)}</div><div className="sub">+ {fmtDur(t.stop_s)} at stops</div></div>
              <div className="tile"><div className="label">Climb</div><div className="value">{fmtNum(t.ascent_m)}<small>m</small></div><div className="sub">steepest {t.max_slope}°</div></div>
              <div className="tile"><div className="label">Farthest walk back</div><div className="value">{t.max_walkback_min}<small>min</small></div><div className="sub">{plan.rover?.enabled ? 'to PR-2 (parked)' : 'to the hab'}</div></div>
              <div className="tile"><div className="label">Radiation dose</div><div className="value">{fmtNum(t.dose_usv)}<small>µSv</small></div><div className="sub">GCR, terrain-shielded</div></div>
              <div className="tile"><div className="label">Worst return margin</div><div className="value" style={{ color: t.min_margin_min < 0 ? 'var(--critical-ink)' : undefined }}>{fmtNum(t.min_margin_min)}<small>min</small></div><div className="sub">{t.limiting}{t.margin_range_min ? ` · ${fmtNum(t.margin_range_min[0])}–${fmtNum(t.margin_range_min[1])}` : ''}</div></div>
            </div>

            <div className="section" style={{ marginTop: 16 }}>
              <h3>Go / no-go checks</h3>
              <ul className="issues">
                {plan.issues.map((i, k) => <li key={k}><IssueIcon level={i.level} /><span>{i.text}</span></li>)}
              </ul>
              <SpaceWeatherCheck sw={plan.space_weather} />
            </div>
            <SunCheck plan={plan} />
            <Uncertainty plan={plan} />

            <div className="section">
              <h3>Navigation legs</h3>
              {plan.legs.map((L, i) => (
                <div key={i} className="card" style={{ padding: '8px 10px', cursor: 'pointer' }} onClick={() => set({ focus: { lon: L.path[Math.floor(L.path.length / 2)][0], lat: L.path[Math.floor(L.path.length / 2)][1], t: Date.now() } })}>
                  <div className="row between">
                    <b style={{ fontSize: 12.5 }}>{L.from} → {L.to}</b>
                    <span className="mono" style={{ fontSize: 12 }}>{Math.round(L.bearing_deg)}° {compass(L.bearing_deg)}</span>
                  </div>
                  <div className="row between" style={{ marginTop: 3, fontSize: 11.5, color: 'var(--text-2)' }}>
                    <span>{fmtDist(L.dist_m)} · {fmtDur(L.time_s)}</span>
                    <span>+{L.ascent_m} / −{L.descent_m} m · max {L.max_slope}°</span>
                  </div>
                  {L.warnings?.length > 0 && <div className="hint" style={{ color: 'var(--warning)' }}>{L.warnings[0]}</div>}
                </div>
              ))}
            </div>

            <div className="section">
              <h3>Radio coverage</h3>
              <div className="card row between">
                <span className="row"><Radio size={14} color="var(--cyan)" /> Route out of line of sight</span>
                <b className="mono">{fmtNum(t.comms_dead_fraction * 100)} %</b>
              </div>
              <p className="hint">Site-wide from the hab mast: {fmtNum(plan.comms.clear_fraction * 100)} % clear, {fmtNum(plan.comms.dead_fraction * 100)} % dead zones.</p>
            </div>
          </>
        )}
      </div>
    </aside>
  )
}
