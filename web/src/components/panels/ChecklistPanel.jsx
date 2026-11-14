import React, { useEffect, useState } from 'react'
import { Award, Box, Download, Printer } from 'lucide-react'
import { UI_CHATTER, missionBody, useStore, useStoreExcept } from '../../store.js'
import { buildChecklist } from '../checklist.js'
import { openPlanDoc } from '../../lib/docs.js'
import { fmtDist, fmtDur, fmtUtc } from '../../lib/format.js'

async function openTraverseSheet() {
  const state = useStore.getState()
  if (!state.site) return
  const win = window.open('', '_blank')
  try {
    const r = await fetch(`/api/sites/${state.site.id}/traverse-sheet`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(missionBody(state)),
    })
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    const html = await r.text()
    if (win) { win.document.open(); win.document.write(html); win.document.close(); return }
    // pop-up blocked: hand the sheet over as a file instead
    const a = document.createElement('a')
    a.href = URL.createObjectURL(new Blob([html], { type: 'text/html' }))
    a.download = `traverse_sheet_${state.site.id}.html`
    a.click()
    setTimeout(() => URL.revokeObjectURL(a.href), 5000)
    state.notify('Pop-up blocked: the traverse sheet was downloaded instead.', 'info')
  } catch (e) {
    if (win) win.close()
    state.notify(`Traverse sheet failed: ${e.message}`, 'error')
  }
}

// Touch the map (feature F2): the site as a block you can hold, route raised, for a 3D printer or a phone in AR.
async function downloadModel(fmt, exaggeration) {
  const state = useStore.getState()
  if (!state.site || !state.plan) return
  const b = missionBody(state)
  const body = {
    route: state.plan.legs.flatMap((L) => L.path), stops: b.stops.map((s) => [s.lon, s.lat]),
    habitat: [b.habitat.lon, b.habitat.lat], exaggeration,
  }
  try {
    const r = await fetch(`/api/sites/${state.site.id}/export/${fmt}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    const blob = await r.blob()
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `martian_map_${state.site.id}.${fmt}`
    a.click()
    setTimeout(() => URL.revokeObjectURL(a.href), 5000)
    state.notify(`${fmt.toUpperCase()} saved: ${(blob.size / 1e6).toFixed(1)} MB`, 'ok')
  } catch (e) {
    state.notify(`3D export failed: ${e.message}`, 'error')
  }
}

function TouchTheMap() {
  const [ex, setEx] = useState(1.5)
  return (
    <div className="section">
      <h3><span><Box size={11} style={{ verticalAlign: -1 }} /> Touch the map</span></h3>
      <div className="card">
        <p className="hint" style={{ marginTop: 0 }}>The site as a block you can hold: the route raised as a ridge, the stops as bumps and the habitat as a pad. STL for a 3D printer (150 mm wide, closed and ready to slice); GLB for 3D viewers and phone AR (40 cm on a table, with the route painted on the HiRISE colour).</p>
        <label className="field"><span>Height exaggeration <b>×{ex.toFixed(1)}</b></span><input type="range" min="1" max="3" step="0.5" value={ex} onChange={(e) => setEx(+e.target.value)} /></label>
        <div className="row" style={{ gap: 6 }}>
          <button className="btn sm primary" onClick={() => downloadModel('stl', ex)}><Download size={13} /> 3D print (STL)</button>
          <button className="btn sm" onClick={() => downloadModel('glb', ex)}><Download size={13} /> 3D / AR model (GLB)</button>
        </div>
      </div>
    </div>
  )
}

// Mission patch (feature G1): drawn by the server from this EVA's route, with the site, the sol and the crew.
function MissionPatch() {
  const plan = useStore((s) => s.plan)
  const crew = useStore((s) => s.crew) || ['EV1', 'EV2']
  const siteId = useStore((s) => s.siteId)
  const set = useStore((s) => s.set)
  const [svg, setSvg] = useState('')
  const crewKey = crew.join('|')
  useEffect(() => {
    if (!plan) return undefined
    let off = false
    const timer = setTimeout(() => {
      const st = useStore.getState()
      const b = missionBody(st)
      const legs = plan.legs
      const t = plan.totals
      fetch(`/api/sites/${st.siteId}/patch.svg`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          route: legs.flatMap((L) => L.path), stops: legs.slice(0, -1).map((L) => L.path[L.path.length - 1]),
          habitat: [b.habitat.lon, b.habitat.lat], crew: b.crew, sol: t.mission_sol, dist_km: t.dist_m / 1000,
          suit_min: (t.suit_s ?? t.total_s) / 60,
        }),
      }).then((r) => (r.ok ? r.text() : Promise.reject(new Error(`HTTP ${r.status}`))))
        .then((text) => { if (!off) setSvg(text) })
        .catch(() => { if (!off) setSvg('') })
    }, 250)
    return () => { off = true; clearTimeout(timer) }
  }, [plan, crewKey])
  const save = () => {
    const a = document.createElement('a')
    a.href = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }))
    a.download = `eva_patch_${siteId}.svg`
    a.click()
    setTimeout(() => URL.revokeObjectURL(a.href), 5000)
  }
  return (
    <div className="section">
      <h3><span><Award size={11} style={{ verticalAlign: -1 }} /> Mission patch</span></h3>
      <div className="card patch-card">
        <div className="patch-svg" dangerouslySetInnerHTML={{ __html: svg }} aria-hidden={!svg} />
        <div>
          <p className="hint" style={{ marginTop: 0 }}>Drawn from this EVA's own route, with the site, the sol and the crew. It is printed on the traverse sheet too.</p>
          <label className="field"><span>Crew names</span>
            <input className="txt" value={crew.join(', ')} placeholder="EV1, EV2" maxLength={60}
              onChange={(e) => set({ crew: e.target.value.split(',').map((n) => n.trimStart()).slice(0, 4) })}
              onBlur={() => useStore.getState().saveMission()} />
          </label>
          <button className="btn sm" onClick={save} disabled={!svg} style={{ marginTop: 6 }}><Download size={13} /> Save the patch (SVG)</button>
        </div>
      </div>
    </div>
  )
}

export default function ChecklistPanel() {
  const state = useStoreExcept(UI_CHATTER)
  const cl = buildChecklist(state.plan, state)
  if (!cl) return <div className="muted">Plan an EVA to generate its cuff checklist.</div>
  const t = cl.totals
  return (
    <>
      <div className="section">
        <div className="row between">
          <div>
            <div style={{ fontWeight: 700 }}>EVA-1 · {state.site.short_name}</div>
            <div className="muted" style={{ fontSize: 11.5 }}>Sol {t.mission_sol} · {fmtUtc(t.start_utc)} · {fmtDist(t.dist_m)} · {fmtDur(t.total_s)}</div>
          </div>
          <button className="btn primary" onClick={() => window.print()}><Printer size={14} /> Print</button>
          <button className="btn" onClick={openTraverseSheet} title="Apollo-style photomap with stations, times and tasks">Traverse sheet</button>
          <button className="btn" onClick={() => openPlanDoc('postcards', 'arrival_postcards', 'postcards')} title="For each stop: the view a few steps before arriving, rendered from the terrain for the arrival sun, beside the rover's own photo">Postcards</button>
        </div>
      </div>
      <MissionPatch />
      <TouchTheMap />
      <div className="section">
        <h3>Flight rules</h3>
        <ul className="issues">{cl.rules.map((r, i) => <li key={i}><span className="mono" style={{ color: 'var(--accent)' }}>{i + 1}</span><span>{r}</span></li>)}</ul>
      </div>
      <div className="section">
        <h3>Timeline</h3>
        {cl.rows.map((r, i) => (
          <div key={i} className="card" style={{ padding: '8px 10px', borderLeft: `3px solid ${r.kind === 'walk' ? 'var(--series-1)' : r.kind === 'stop' ? 'var(--series-2)' : r.kind === 'drive' ? '#2f9e5b' : 'var(--series-3)'}` }}>
            <div className="row between">
              <b style={{ fontSize: 12 }}>{r.title}</b>
              <span className="mono muted" style={{ fontSize: 11 }}>{r.t} · {r.ltst}</span>
            </div>
            {r.lines.map((l, k) => <div key={k} className="dim" style={{ fontSize: 11.5 }}>□ {l}</div>)}
          </div>
        ))}
      </div>
    </>
  )
}
