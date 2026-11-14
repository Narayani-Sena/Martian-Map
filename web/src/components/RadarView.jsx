import React, { useEffect, useRef, useState } from 'react'
import { X, ZoomIn, ZoomOut } from 'lucide-react'
import { api } from '../api.js'
import { useStore } from '../store.js'

// Under the rover's track (feature E1): what Perseverance's RIMFAX ground radar saw below the surface along one
// stretch of a sol's drive. Distance along the drive runs across, depth down. The main view shows a window of the
// run (60 m to start, wheel to zoom, drag to pan); the strip above it shows the whole run. Moving the cursor here
// moves the marker along the track on the map.
const WINDOW_M = 60
const MIN_M = 12

export default function RadarView() {
  const site = useStore((s) => s.site)
  const v = useStore((s) => s.radarView)
  const set = useStore((s) => s.set)
  const [doc, setDoc] = useState(null)
  const [view, setView] = useState(null) // { run, start, win } in columns
  const box = useRef(null)
  const drag = useRef(null)

  useEffect(() => {
    if (!v || !site?.radar || doc?.site === site.id) return undefined
    let alive = true
    api.radar(site.id).then((d) => { if (alive) setDoc({ ...d, site: site.id }) }).catch(() => {})
    return () => { alive = false }
  }, [v, site?.id, site?.radar, doc?.site])

  const r = v && doc?.site === site?.id ? doc.runs.find((x) => x.run === v.run) : null
  // a new run (or a click on the map): centre the window on the chosen column
  useEffect(() => {
    if (!r || !v) return
    const win = Math.min(r.n, Math.round(WINDOW_M / doc.col_m))
    setView((cur) => (cur && cur.run === r.run && v.i >= cur.start && v.i < cur.start + cur.win
      ? cur : { run: r.run, win, start: clampStart(v.i - win / 2, win, r.n) }))
  }, [r?.run, v?.i]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!v || !site?.radar) return null
  const close = () => set({ radarView: null })
  if (!r || !view || view.run !== r.run) {
    return <div className="radar-view"><div className="muted" style={{ padding: 8 }}>Loading the radargram…</div></div>
  }
  const n = r.n
  const colM = doc.col_m
  const { start, win } = view
  const cur = Math.max(0, Math.min(n - 1, v.cursor ?? v.i))
  const depth = doc.depth_m
  const dTicks = []
  for (let m = 0; m <= depth + 1e-6; m += depth > 8 ? 2 : 1) dTicks.push(m)
  const winM = win * colM
  const step = winM > 300 ? 50 : winM > 120 ? 20 : winM > 50 ? 10 : 5
  const x0m = start * colM
  const xTicks = []
  for (let m = Math.ceil(x0m / step) * step; m <= x0m + winM; m += step) xTicks.push(m)
  const src = api.radarRunUrl(site.id, r.run)

  const colAt = (clientX) => {
    const b = box.current?.getBoundingClientRect()
    if (!b) return cur
    const f = Math.max(0, Math.min(1, (clientX - b.left) / b.width))
    return Math.max(0, Math.min(n - 1, Math.round(start + f * (win - 1))))
  }
  const onMove = (e) => {
    if (drag.current) {
      const b = box.current.getBoundingClientRect()
      const dc = Math.round(((drag.current.x - e.clientX) / b.width) * win)
      setView({ ...view, start: clampStart(drag.current.start + dc, win, n) })
      return
    }
    const k = colAt(e.clientX)
    if (k !== cur) set({ radarView: { ...v, cursor: k } })
  }
  const zoom = (f, around = cur) => {
    const w2 = Math.max(Math.round(MIN_M / colM), Math.min(n, Math.round(win * f)))
    const frac = (around - start) / Math.max(1, win)
    setView({ ...view, win: w2, start: clampStart(around - frac * w2, w2, n) })
  }
  const onWheel = (e) => { zoom(e.deltaY > 0 ? 1.4 : 1 / 1.4, colAt(e.clientX)) }
  const onOverview = (e) => {
    const b = e.currentTarget.getBoundingClientRect()
    const k = Math.round(((e.clientX - b.left) / b.width) * (n - 1))
    setView({ ...view, start: clampStart(k - win / 2, win, n) })
    set({ radarView: { ...v, cursor: k } })
  }
  const z = r.z?.[cur]
  return (
    <div className="radar-view" role="dialog" aria-label="Ground radar under the rover's track">
      <div className="radar-head">
        <div>
          <b>Under the track</b> <span className="muted">· {site.rover_name}'s RIMFAX radar · sol {r.sol} ({r.utc}) · {Math.round(n * colM)} m</span>
        </div>
        <div className="row" style={{ gap: 2 }}>
          <button className="btn ghost icon" onClick={() => zoom(1 / 1.6)} aria-label="Zoom in" title="Zoom in (or the mouse wheel)"><ZoomIn size={13} /></button>
          <button className="btn ghost icon" onClick={() => zoom(1.6)} aria-label="Zoom out" title="Zoom out"><ZoomOut size={13} /></button>
          <button className="btn ghost icon" onClick={close} aria-label="Close"><X size={13} /></button>
        </div>
      </div>
      <div className="radar-overview" onClick={onOverview} title="The whole run: click to jump">
        <img src={src} alt="" draggable={false} />
        <i style={{ left: `${(start / n) * 100}%`, width: `${(win / n) * 100}%` }} />
        <b style={{ left: `${(cur / Math.max(1, n - 1)) * 100}%` }} />
      </div>
      <div className="radar-plot">
        <div className="radar-yaxis">
          {dTicks.map((m) => <span key={m} style={{ top: `${(m / depth) * 100}%` }}>{m} m</span>)}
        </div>
        <div className="radar-img" ref={box} onMouseMove={onMove} onWheel={onWheel}
          onMouseDown={(e) => { drag.current = { x: e.clientX, start } }}
          onMouseUp={() => { drag.current = null }} onMouseLeave={() => { drag.current = null }}>
          <img src={src} alt={`Radargram, sol ${r.sol}`} draggable={false}
            style={{ width: `${(n / win) * 100}%`, left: `${(-start / win) * 100}%` }} />
          {dTicks.slice(1, -1).map((m) => <i key={m} className="radar-grid" style={{ top: `${(m / depth) * 100}%` }} />)}
          {cur >= start && cur < start + win && <i className="radar-cursor" style={{ left: `${((cur - start) / Math.max(1, win - 1)) * 100}%` }} />}
        </div>
        <div className="radar-xaxis">
          {xTicks.map((m) => <span key={m} style={{ left: `${((m - x0m) / winM) * 100}%` }}>{m}</span>)}
          <em>m along this stretch</em>
        </div>
      </div>
      <div className="radar-foot">
        <span className="mono">{(r.d0_m + cur * colM).toFixed(0)} m into sol {r.sol}'s drive{z != null ? ` · ground at ${z.toFixed(1)} m` : ''}</span>
        <span className="muted">
          {' '}Light and dark bands are echoes of opposite sign from buried layer boundaries; the chevrons are echoes off
          buried rocks; grey means no echo. Depth assumes ε = {doc.eps_r} ({doc.v_m_per_ns.toFixed(2)} m/ns), so it is
          approximate. NASA PDS, Mars 2020 RIMFAX.
        </span>
      </div>
    </div>
  )
}

function clampStart(s, win, n) {
  return Math.max(0, Math.min(Math.max(0, n - win), Math.round(s)))
}
