import React, { useEffect, useRef, useState } from 'react'
import { Waves } from 'lucide-react'
import { useStore } from '../../store.js'
import { fmtNum } from '../../lib/format.js'

// Flood the crater (feature A4): a water level slider, the published levels as presets, and how deep the water
// stood over the hab and every stop.
export default function LakeControl({ layer }) {
  const site = useStore((s) => s.site)
  const level = useStore((s) => s.lakeLevel) ?? layer.default_level
  const set = useStore((s) => s.set)
  const [v, setV] = useState(level)
  const [st, setSt] = useState(null)
  const t = useRef(null)
  useEffect(() => setV(level), [level])
  const commit = (x) => {
    setV(x)
    clearTimeout(t.current)
    t.current = setTimeout(() => set({ lakeLevel: x }), 250)
  }
  useEffect(() => {
    let alive = true
    fetch(`/api/sites/${site.id}/lake?level=${level}`).then((r) => r.json()).then((d) => { if (alive) setSt(d) }).catch(() => {})
    return () => { alive = false }
  }, [level, site.id])
  const lo = Math.floor((site.elev_min ?? level - 100) - 20)
  const hi = Math.ceil(Math.max(site.elev_max ?? level + 50, ...(layer.levels || []).map((l) => l.elev)) + 20)
  return (
    <div style={{ marginTop: 6 }}>
      <label className="field">
        <span><Waves size={12} style={{ verticalAlign: -2 }} /> Lake level <b className="mono">{fmtNum(v)} m</b></span>
        <input type="range" min={lo} max={hi} step="1" value={v} onChange={(e) => commit(+e.target.value)} />
      </label>
      {(layer.levels || []).length > 0 && (
        <div className="row" style={{ gap: 4, flexWrap: 'wrap' }}>
          {layer.levels.map((l) => (
            <button key={l.elev} className={`btn sm ${level === l.elev ? 'on' : ''}`} title={l.name} onClick={() => commit(l.elev)}>{fmtNum(l.elev)} m</button>
          ))}
        </div>
      )}
      {st && (
        <>
          <div className="wh-stats">
            <div><b>{fmtNum(st.share_under * 100)} %</b><span>under water</span></div>
            <div><b>{fmtNum(st.max_depth_m)} m</b><span>deepest</span></div>
            <div><b>{fmtNum(st.points[0]?.depth_m > 0 ? st.points[0].depth_m : 0)} m</b><span>over the hab</span></div>
          </div>
          <div className="card" style={{ marginTop: 6, padding: '4px 10px' }}>
            {st.points.slice(1).map((p) => (
              <div key={p.name} className="row between" style={{ fontSize: 12, padding: '2px 0' }}>
                <span>{p.name}</span><span className="mono">{p.depth_m > 0 ? `${fmtNum(p.depth_m)} m of water` : `${fmtNum(-p.depth_m)} m above the shore`}</span>
              </div>
            ))}
          </div>
          {(layer.levels || []).find((l) => l.elev === level) && <p className="hint">{layer.levels.find((l) => l.elev === level).name}.</p>}
        </>
      )}
    </div>
  )
}
