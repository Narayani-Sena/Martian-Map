import React, { useRef, useState } from 'react'
import { ArrowDown, ArrowUp, Download, Home, MapPin, Plus, RadioTower, RotateCcw, Trash2, Upload, GitCompareArrows, Crosshair, Truck, Sparkles } from 'lucide-react'
import { UI_CHATTER, useStore, useStoreExcept } from '../../store.js'
import { api, walkParams } from '../../api.js'
import { SOL_MS, hms, ltst, marsTime, utcForLtst } from '../../lib/mars24.js'
import { fmtDist, fmtDur, fmtUtc } from '../../lib/format.js'

function nextLtst(lon, target) {
  const now = Date.now()
  let t = utcForLtst(new Date(now), lon, target)
  if (t.getTime() < now) t = utcForLtst(new Date(now + SOL_MS), lon, target)
  return t
}

function StopEditor({ stop }) {
  const update = useStore((s) => s.updateStop)
  const ev = useStore((s) => s.plan?.events?.find((e) => e.kind === 'stop' && e.id === stop.id))
  return (
    <div className="card" style={{ marginTop: 6, background: '#10161f' }} onClick={(e) => e.stopPropagation()}>
      <label className="field">
        <span>Name</span>
        <input type="text" value={stop.name} onChange={(e) => update(stop.id, { name: e.target.value })} />
      </label>
      <label className="field">
        <span>Time at stop <b>{stop.dwell_min} min</b></span>
        <input type="range" min="5" max="90" step="5" value={stop.dwell_min} onChange={(e) => update(stop.id, { dwell_min: +e.target.value })} />
      </label>
      <label className="field">
        <span>Tasks (one per line)</span>
        <textarea rows={3} value={(stop.tasks || []).join('\n')} onChange={(e) => update(stop.id, { tasks: e.target.value.split('\n') })} />
      </label>
      {stop.science && <p className="hint" style={{ lineHeight: 1.5 }}>{stop.science}</p>}
      {ev?.light && <p className="hint" style={{ lineHeight: 1.5 }}><b>Light:</b> {ev.light.note}.</p>}
      {ev?.science?.reasons?.length > 0 && (
        <ul className="reasons" style={{ margin: '4px 0 0', paddingLeft: 16, fontSize: 11.5, color: 'var(--text-2)' }}>
          {ev.science.reasons.map((r, k) => <li key={k}>{r.text}</li>)}
        </ul>
      )}
      {ev?.scouted && <p className="hint">Seen from the air by Ingenuity: flight {ev.scouted.flight}, sol {ev.scouted.sol} ({ev.scouted.earth_date}).</p>}
      <p className="hint mono">{Math.abs(stop.lat).toFixed(5)}°S {stop.lon.toFixed(5)}°E</p>
    </div>
  )
}

// Science stops inside the safe walk-back range (data-use item D3).
function SuggestStops() {
  const s = useStoreExcept(UI_CHATTER)
  const [n, setN] = useState(3)
  const [limit, setLimit] = useState(35)
  const parked = s.plan?.rover?.enabled ? s.plan.rover.dropoff : null
  const run = async () => {
    s.set({ suggestLoading: true })
    try {
      const r = await api.suggestStops(s.siteId, {
        habitat: { lon: s.habitat.lon, lat: s.habitat.lat }, haven: parked ? { lon: parked.lon, lat: parked.lat } : null,
        stops: s.stops.map(({ lon, lat }) => ({ lon, lat })), walk: walkParams(s.walk), n, max_walkback_min: limit,
      })
      useStore.getState().set({ suggestions: r.suggestions, suggestLoading: false })
      if (!r.suggestions.length) useStore.getState().notify('No science stop inside that walk-back range', 'info')
    } catch (e) {
      useStore.getState().set({ suggestLoading: false })
      useStore.getState().notify(e.message, 'error')
    }
  }
  return (
    <div className="section">
      <h3>Science stops</h3>
      <div className="row">
        <button className="btn primary grow" onClick={run} disabled={s.suggestLoading}><Sparkles size={14} /> {s.suggestLoading ? 'Searching…' : 'Suggest stops'}</button>
        <select value={n} onChange={(e) => setN(+e.target.value)} aria-label="How many stops to suggest" style={{ width: 64 }}>
          {[2, 3, 4, 5, 6].map((k) => <option key={k} value={k}>{k}</option>)}
        </select>
      </div>
      <label className="field" style={{ marginTop: 8 }}>
        <span>At most <b>{limit} min</b> walk back to {parked ? 'PR-2 (parked)' : 'the hab'}</span>
        <input type="range" min="10" max="60" step="5" value={limit} onChange={(e) => setLimit(+e.target.value)} />
      </label>
      {s.suggestions?.map((sg) => (
        <div key={sg.id} className="card sug-card" style={{ marginTop: 6 }}>
          <div className="row between"><b>{sg.name}</b><span className="tag">science {sg.score.toFixed(2)}</span></div>
          <div className="stop-meta">{sg.walkback_min} min back · slope {sg.slope}°{sg.unit ? ` · ${sg.unit.code} ${sg.unit.name}` : ''}{sg.scouted ? ` · Ingenuity flight ${sg.scouted.flight}` : ''}</div>
          <ul className="reasons">{sg.reasons.map((r, k) => <li key={k}>{r.text}</li>)}</ul>
          <div className="row" style={{ marginTop: 6 }}>
            <button className="btn sm primary" onClick={() => { s.acceptSuggestion(sg); s.notify(`Added ${sg.name} to the route`, 'ok') }}><Plus size={13} /> Add to route</button>
            <button className="btn sm" onClick={() => s.set({ focus: { lon: sg.lon, lat: sg.lat, t: Date.now() } })}><Crosshair size={13} /> Show</button>
          </div>
        </div>
      ))}
      {s.suggestions?.length > 0 && <button className="btn sm ghost" style={{ marginTop: 6 }} onClick={() => s.set({ suggestions: null })}>Clear suggestions</button>}
      <p className="hint">Picks the strongest places on the Science opportunity layer (CRISM minerals, map-unit contacts, ridges and hollows, rover sample sites) that are safe to reach: inside the walk-back limit, no hazardous ground, 150 m or more from the other stops.</p>
    </div>
  )
}

export default function MissionPanel() {
  const s = useStoreExcept(UI_CHATTER)
  const fileRef = useRef(null)
  const plan = s.plan
  const legs = plan?.legs || []
  const lon = s.site.center.lon
  const start = s.startUtc ? new Date(s.startUtc) : null
  const startLtst = start ? ltst(marsTime(start), lon) : null

  const setStart = (target) => s.set({ startUtc: nextLtst(lon, target).toISOString() })

  const onImport = async (e) => {
    const f = e.target.files?.[0]
    if (!f) return
    try {
      s.importMission(await f.text())
      s.notify('Mission imported', 'ok')
    } catch (err) {
      s.notify(`Import failed: ${err.message}`, 'error')
    }
    e.target.value = ''
  }
  const onExport = () => {
    const blob = new Blob([s.exportMission()], { type: 'application/json' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `eva-plan-${s.siteId}.json`
    a.click()
    URL.revokeObjectURL(a.href)
  }

  return (
    <>
      <div className="section">
        <h3>Route</h3>
        <div className={`stop-item ${s.tool === 'move-hab' ? 'sel' : ''}`} onClick={() => s.set({ focus: { ...s.habitat, t: Date.now() } })}>
          <div className="stop-badge hab"><Home size={14} /></div>
          <div className="grow">
            <div style={{ fontWeight: 650 }}>{s.habitat.name || 'Habitat'}</div>
            <div className="stop-meta">{s.rover.enabled ? 'Start · board PR-2 and drive out' : `Start · egress ${s.suit.airlock_min ?? 15} min`}</div>
          </div>
          <button className={`btn sm ${s.tool === 'move-hab' ? 'on' : ''}`} onClick={(e) => { e.stopPropagation(); s.set({ tool: s.tool === 'move-hab' ? 'select' : 'move-hab' }) }} title="Click the map to move the habitat">
            <Crosshair size={13} /> Move
          </button>
        </div>
        {s.rover.enabled && (
          <div className="stop-item" style={{ marginTop: 6, cursor: 'default' }}>
            <div className="stop-badge pr"><Truck size={14} /></div>
            <div className="grow">
              <div style={{ fontWeight: 650 }}>PR-2 drop-off</div>
              <div className="stop-meta">{plan?.rover?.enabled ? `${fmtDist(plan.rover.legs[0].dist_m)} · ${fmtDur(plan.rover.legs[0].time_s)} drive · suitport ${plan.rover.suitport_min} min` : 'drive out…'}</div>
            </div>
          </div>
        )}
        <div style={{ height: 6 }} />
        {s.stops.map((st, i) => {
          const leg = legs[i]
          const sel = s.selectedStop === st.id
          return (
            <div key={st.id} style={{ marginTop: 6 }}>
              <div className={`stop-item ${sel ? 'sel' : ''}`} onClick={() => s.set({ selectedStop: sel ? null : st.id, focus: { lon: st.lon, lat: st.lat, t: Date.now() } })}>
                <div className="stop-badge">{i + 1}</div>
                <div className="grow">
                  <div style={{ fontWeight: 650, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{st.name}</div>
                  <div className="stop-meta">
                    {leg ? `${fmtDist(leg.dist_m)} · ${fmtDur(leg.time_s)} walk · ` : ''}{st.dwell_min} min work
                  </div>
                </div>
                <div className="row" style={{ gap: 2 }} onClick={(e) => e.stopPropagation()}>
                  <button className="btn ghost icon" disabled={i === 0} onClick={() => s.moveStop(st.id, -1)} aria-label="Move up"><ArrowUp size={14} /></button>
                  <button className="btn ghost icon" disabled={i === s.stops.length - 1} onClick={() => s.moveStop(st.id, 1)} aria-label="Move down"><ArrowDown size={14} /></button>
                  <button className="btn ghost icon danger" onClick={() => s.removeStop(st.id)} aria-label="Delete stop"><Trash2 size={14} /></button>
                </div>
              </div>
              {sel && <StopEditor stop={st} />}
            </div>
          )
        })}
        {(s.returnToHab || s.rover.enabled) && (
          <div className="stop-item" style={{ marginTop: 6, cursor: 'default' }}>
            <div className={`stop-badge ${s.rover.enabled ? 'pr' : 'hab'}`}>{s.rover.enabled ? <Truck size={14} /> : <Home size={14} />}</div>
            <div className="grow">
              <div style={{ fontWeight: 650 }}>{s.rover.enabled ? 'Back to PR-2, drive home' : 'Return to habitat'}</div>
              <div className="stop-meta">{legs[s.stops.length] ? `${fmtDist(legs[s.stops.length].dist_m)} · ${fmtDur(legs[s.stops.length].time_s)}` : '—'}
                {plan?.rover?.enabled ? ` walk · ${fmtDist(plan.rover.legs[1].dist_m)} · ${fmtDur(plan.rover.legs[1].time_s)} drive` : ''}</div>
            </div>
          </div>
        )}
        <div className="row" style={{ marginTop: 10 }}>
          <button className={`btn grow ${s.tool === 'add-stop' ? 'on' : 'primary'}`} onClick={() => s.set({ tool: s.tool === 'add-stop' ? 'select' : 'add-stop' })}>
            <Plus size={14} /> {s.tool === 'add-stop' ? 'Click the map to place…' : 'Add stop'}
          </button>
          <label className="row" style={{ gap: 6, fontSize: 12, color: 'var(--text-2)', cursor: 'pointer' }}>
            <input type="checkbox" checked={s.returnToHab} onChange={(e) => s.set({ returnToHab: e.target.checked })} /> Return
          </label>
        </div>
        <p className="hint">Tip: drag pins on the map, or right-click anywhere for more actions.</p>
      </div>

      <SuggestStops />

      <div className="section">
        <h3>Pressurized rover PR-2</h3>
        <label className="row" style={{ gap: 8, fontSize: 12.5, cursor: 'pointer' }}>
          <input type="checkbox" checked={s.rover.enabled} onChange={(e) => s.set({ rover: { ...s.rover, enabled: e.target.checked } })} />
          Drive out in PR-2 and walk from a drop-off
        </label>
        {s.rover.enabled && (
          <div className="card" style={{ marginTop: 8 }}>
            <div className="row between">
              <span>Drop-off <b>{s.rover.dropoff ? 'placed by hand' : 'automatic'}</b></span>
              <button className="btn sm" disabled={!s.rover.dropoff} onClick={() => s.set({ rover: { ...s.rover, dropoff: null } })} title="Let the planner choose a level, drivable spot that keeps the walking short">Auto-place</button>
            </div>
            {plan?.rover?.enabled && (
              <div className="stop-meta" style={{ marginTop: 6 }}>
                Drive {fmtDist(plan.totals.drive_m)} · {fmtDur(plan.totals.drive_s)} in the cab · {fmtDur(plan.totals.suit_s)} in suits
              </div>
            )}
            <p className="hint">Drag the PR-2 pin on the map to park somewhere else. PR-2 keeps to slopes under {plan?.rover?.drive?.max_slope ?? 20}°,
              drives around boulders of {plan?.rover?.limits?.boulder_max_m ?? 1} m and more, and cruises at {((plan?.rover?.drive?.flat_speed ?? 2) * 3.6).toFixed(0)} km/h.
              The crew rides in shirt-sleeves (no suit consumables), uses the suitports, and the parked rover is the safe haven for the walk-back rule and a radio relay.</p>
          </div>
        )}
      </div>

      <div className="section">
        <h3>Path-finding</h3>
        <div className="seg small" style={{ width: '100%' }}>
          <button className={s.algorithm === 'astar' ? 'on' : ''} style={{ flex: 1 }} onClick={() => s.set({ algorithm: 'astar' })}>A* (ours, Python)</button>
          <button className={s.algorithm === 'dijkstra' ? 'on' : ''} style={{ flex: 1 }} onClick={() => s.set({ algorithm: 'dijkstra' })}>Dijkstra (scikit-image)</button>
        </div>
        {s.algorithm === 'astar' && (
          <label className="field" style={{ marginTop: 10 }}>
            <span>Heuristic weight ε <b>{s.astarWeight.toFixed(2)}</b></span>
            <input type="range" min="1" max="2" step="0.05" value={s.astarWeight} onChange={(e) => s.set({ astarWeight: +e.target.value })} />
            <p className="hint">1.00 = guaranteed optimal. Higher = explores fewer cells; the route is at most ε× slower than optimal.</p>
          </label>
        )}
        <p className="hint">
          {s.algorithm === 'astar'
            ? 'Our A* knows the direction of travel: walking uphill costs more than walking down.'
            : 'MCP Dijkstra (C) only knows a cost per cell, so it treats uphill and downhill the same.'}
        </p>
        <button className="btn sm" style={{ marginTop: 6 }} onClick={() => s.set({ drawer: 'compare' })}><GitCompareArrows size={13} /> Compare both on a leg</button>
      </div>

      <div className="section">
        <h3>EVA start</h3>
        <div className="card">
          <div className="row between">
            <div>
              <div className="mono" style={{ fontSize: 16, fontWeight: 600 }}>{startLtst != null ? hms(startLtst, false) : '—'} <span className="muted" style={{ fontSize: 11 }}>LTST</span></div>
              <div className="muted mono" style={{ fontSize: 11 }}>{fmtUtc(s.startUtc)}</div>
            </div>
            {plan && <span className="tag">Sol {plan.totals.mission_sol}</span>}
          </div>
          <div className="row wrap" style={{ marginTop: 8, gap: 4 }}>
            {[7, 9, 11, 13, 15].map((h) => (
              <button key={h} className="btn sm" onClick={() => setStart(h)}>{String(h).padStart(2, '0')}:00</button>
            ))}
          </div>
          <p className="hint">Next sol at that local true solar time. The plan checks daylight, temperature-driven heater load and sunset.</p>
        </div>
      </div>

      <div className="section">
        <h3>Radio relays <span className="tag">{s.relays.length}</span></h3>
        {s.relays.map((r) => (
          <div key={r.id} className="stop-item" style={{ marginTop: 6 }} onClick={() => s.set({ focus: { lon: r.lon, lat: r.lat, t: Date.now() } })}>
            <div className="stop-badge" style={{ background: 'var(--cyan)' }}><RadioTower size={14} /></div>
            <div className="grow">
              <div style={{ fontWeight: 650 }}>{r.id}</div>
              <div className="stop-meta">mast {r.height_m} m</div>
            </div>
            <button className="btn ghost icon danger" onClick={(e) => { e.stopPropagation(); s.removeRelay(r.id) }} aria-label="Remove relay"><Trash2 size={14} /></button>
          </div>
        ))}
        <button className={`btn sm ${s.tool === 'add-relay' ? 'on' : ''}`} style={{ marginTop: 8 }} onClick={() => s.set({ tool: s.tool === 'add-relay' ? 'select' : 'add-relay' })}>
          <MapPin size={13} /> {s.tool === 'add-relay' ? 'Click the map…' : 'Place a relay'}
        </button>
        <p className="hint">Relays extend radio line of sight into dead zones (turn on the “Radio line of sight” layer).</p>
      </div>

      <div className="section">
        <h3>Mission file</h3>
        <div className="row wrap">
          <button className="btn sm" onClick={onExport}><Download size={13} /> Export</button>
          <button className="btn sm" onClick={() => fileRef.current?.click()}><Upload size={13} /> Import</button>
          <button className="btn sm danger" onClick={() => s.resetMission()}><RotateCcw size={13} /> Reset</button>
          <input ref={fileRef} type="file" accept="application/json" hidden onChange={onImport} />
        </div>
      </div>
    </>
  )
}
