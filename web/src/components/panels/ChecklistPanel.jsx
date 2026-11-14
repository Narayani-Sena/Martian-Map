import React from 'react'
import { Printer } from 'lucide-react'
import { missionBody, useStore } from '../../store.js'
import { buildChecklist } from '../checklist.js'
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

export default function ChecklistPanel() {
  const state = useStore()
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
        </div>
      </div>
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
