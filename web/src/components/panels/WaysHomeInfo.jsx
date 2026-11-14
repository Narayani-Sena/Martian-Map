import React from 'react'
import { useStore } from '../../store.js'
import { fmtNum } from '../../lib/format.js'
import { rampCss } from '../map/flowLayer.js'

// Ways home (feature A1): the numbers behind the network, the gateways and (with PR-2 or caches) the basins.
export default function WaysHomeInfo() {
  const d = useStore((s) => s.waysHome)
  const set = useStore((s) => s.set)
  if (!d) return <p className="hint">Tracing the fastest walk home from every 4 m of the site…</p>
  const multi = (d.havens || []).length > 1
  return (
    <div style={{ marginTop: 8 }}>
      <div className="wh-stats">
        <div><b>{d.gateways.length}</b><span>gateways</span></div>
        <div><b>{fmtNum(d.max_minutes)}′</b><span>farthest home</span></div>
        <div><b>{fmtNum(d.nogo_fraction * 100)} %</b><span>no way home</span></div>
      </div>
      {d.gateways.length > 0 && (
        <div className="card" style={{ marginTop: 8, padding: '4px 10px' }}>
          {d.gateways.map((g) => (
            <div key={g.id} className="wh-gw" onClick={() => set({ focus: { lon: g.lon, lat: g.lat, t: Date.now() } })} title="Fly there">
              <i style={{ background: rampCss(g.minutes) }} />
              <b style={{ width: 70 }}>Gateway {g.id}</b>
              <span className="grow">way home for <b>{Math.round(g.share * 100)} %</b> · {fmtNum(g.area_ha)} ha</span>
              <span className="mono muted">{Math.round(g.minutes)}′</span>
            </div>
          ))}
        </div>
      )}
      {multi && (
        <div className="card" style={{ marginTop: 8, padding: '6px 10px' }}>
          <div className="muted" style={{ fontSize: 10.5, textTransform: 'uppercase', letterSpacing: '0.08em', marginBottom: 4 }}>Basins: each cell walks to its nearest haven</div>
          {d.basins.map((b) => (
            <div key={b.name} className="row between" style={{ fontSize: 12, padding: '2px 0' }}>
              <span><i style={{ display: 'inline-block', width: 9, height: 9, borderRadius: 2, marginRight: 6, background: `rgb(${b.rgb.join(',')})` }} />{b.name}</span>
              <span className="mono">{fmtNum(b.area_ha)} ha · {Math.round(b.share * 100)} %</span>
            </div>
          ))}
        </div>
      )}
      <p className="hint" style={{ marginTop: 8 }}>
        Every planner draws one route; this draws the safety structure of the whole terrain. A gateway is where many ways home merge: a cache, a relay or a marker there does the most good. Click the map to see your own way home (“lost? walk downstream”).
      </p>
    </div>
  )
}
