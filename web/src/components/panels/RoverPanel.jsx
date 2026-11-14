import React, { useEffect, useMemo, useState } from 'react'
import { Camera, ExternalLink, X } from 'lucide-react'
import { useStore } from '../../store.js'
import { api } from '../../api.js'
import { fmtDist } from '../../lib/format.js'

// Ingenuity's flights over the site and the photos it took on each (Jezero; data-use item D5).
function Ingenuity() {
  const site = useStore((s) => s.site)
  const flight = useStore((s) => s.heliFlight)
  const set = useStore((s) => s.set)
  const [flights, setFlights] = useState(null)
  const [imgs, setImgs] = useState(null)
  const [err, setErr] = useState(null)
  const [box, setBox] = useState(null)
  useEffect(() => { api.ingenuity(site.id).then((r) => setFlights(r.flights.filter((f) => f.in_site))).catch(() => setFlights([])) }, [site.id])
  const f = flights?.find((x) => x.flight === flight) || null
  useEffect(() => {
    if (!f) return
    setImgs(null); setErr(null)
    api.ingenuityImages(f.sol).then((r) => setImgs(r.items)).catch((e) => setErr(e.message))
  }, [f?.flight, f?.sol])
  if (!flights?.length) return null
  return (
    <div className="section">
      <h3>Ingenuity, seen from the air <span className="tag">{flights.length} flights</span></h3>
      <select value={flight ?? ''} onChange={(e) => set({ heliFlight: e.target.value ? +e.target.value : null })}>
        <option value="">Pick a flight (or click one on the map)</option>
        {flights.map((x) => <option key={x.flight} value={x.flight}>Flight {x.flight} · sol {x.sol} · {fmtDist(x.length_m)}</option>)}
      </select>
      {f && (
        <>
          <p className="hint">Flight {f.flight}, {f.earth_date}: {fmtDist(f.length_m)} at up to {f.max_alt_m} m, {Math.round(f.duration_s)} s{f.from ? `, ${f.from} → ${f.to}` : ''}. Its downward camera saw a strip about {Math.round(2.8 * f.max_alt_m)} m wide along the track.</p>
          {err && <div className="card" style={{ borderColor: 'var(--warning)' }}>Image feed unavailable: {err}</div>}
          {!imgs && !err && <div className="muted">Loading the helicopter's photos from sol {f.sol}…</div>}
          {imgs && (imgs.length === 0 ? <div className="muted">No raw images listed for sol {f.sol}.</div> : (
            <div className="photo-grid">
              {imgs.slice(0, 18).map((im) => (
                <button key={im.id} onClick={() => setBox(im)} title={im.title}>
                  <img src={im.thumb} alt={`${im.camera} sol ${im.sol}`} loading="lazy" referrerPolicy="no-referrer" onError={(e) => { if (e.currentTarget.src !== im.url) e.currentTarget.src = im.url }} />
                  <span className="cam">{im.instrument.includes('RTE') ? 'Colour' : 'Nav'}</span>
                </button>
              ))}
            </div>
          ))}
          <button className="btn sm" style={{ marginTop: 6 }} onClick={() => { const mid = flights.find((x) => x.flight === f.flight); if (mid) set({ focus: { lon: mid.path?.[0]?.[0] ?? site.center.lon, lat: mid.path?.[0]?.[1] ?? site.center.lat, t: Date.now() } }) }}>Show on map</button>
        </>
      )}
      <p className="hint">Images: NASA/JPL-Caltech Ingenuity raw image feed (navigation camera looks straight down, the colour camera ahead).</p>
      {box && (
        <div className="lightbox" onClick={() => setBox(null)}>
          <div onClick={(e) => e.stopPropagation()} style={{ textAlign: 'center' }}>
            <img src={box.url} alt={box.title} referrerPolicy="no-referrer" />
            <div className="cap">{box.title} · {box.camera} · {box.date_taken?.slice(0, 16).replace('T', ' ')} UTC</div>
            <div className="row" style={{ justifyContent: 'center', marginTop: 8 }}>
              <a className="btn sm" href={box.url} target="_blank" rel="noreferrer"><ExternalLink size={13} /> Full size</a>
              <button className="btn sm" onClick={() => setBox(null)}><X size={13} /> Close</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

export default function RoverPanel() {
  const site = useStore((s) => s.site)
  const stops = useStore((s) => s.stops)
  const habitat = useStore((s) => s.habitat)
  const selected = useStore((s) => s.selectedStop)
  const set = useStore((s) => s.set)
  const targets = useMemo(() => [{ id: 'hab', name: habitat.name || 'Habitat', lon: habitat.lon, lat: habitat.lat }, ...stops], [stops, habitat])
  const [target, setTarget] = useState(selected || stops[0]?.id || 'hab')
  const [nearest, setNearest] = useState(null)
  const [wp, setWp] = useState(null)
  const [images, setImages] = useState(null)
  const [err, setErr] = useState(null)
  const [camera, setCamera] = useState('All')
  const [box, setBox] = useState(null)
  const t = targets.find((x) => x.id === target) || targets[0]
  const mission = site.rover.raw_images_mission

  useEffect(() => { if (selected) setTarget(selected) }, [selected])
  useEffect(() => {
    setNearest(null); setWp(null); setImages(null); setErr(null)
    api.roverNearest(site.id, t.lon, t.lat).then((r) => { setNearest(r.items); setWp(r.items[0] || null) }).catch((e) => setErr(e.message))
  }, [site.id, t.lon, t.lat])
  useEffect(() => {
    if (!wp || !mission) return
    setImages(null); setErr(null)
    api.roverImages(mission, wp.sol, wp.sol_end).then((r) => setImages(r.items)).catch((e) => setErr(e.message))
  }, [wp, mission])

  const cams = images ? ['All', ...Array.from(new Set(images.map((i) => i.camera)))] : ['All']
  const shown = images ? images.filter((i) => camera === 'All' || i.camera === camera) : []

  return (
    <>
      <Ingenuity />
      <div className="section">
        <h3>Point of view</h3>
        <select value={target} onChange={(e) => setTarget(e.target.value)}>
          {targets.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
        </select>
        <p className="hint">Raw images {site.rover_name} took from the end-of-drive stop nearest to this place — the closest thing to standing there.</p>
      </div>
      <div className="section">
        <h3>Nearest {site.rover_name} stops</h3>
        {!nearest && !err && <div className="muted">Searching…</div>}
        {nearest?.length === 0 && <div className="muted">{site.rover_name} never stopped inside this map.</div>}
        {nearest?.map((n) => (
          <div key={n.sol} className={`stop-item ${wp?.sol === n.sol ? 'sel' : ''}`} onClick={() => { setWp(n); set({ focus: { lon: n.lon, lat: n.lat, t: Date.now() } }) }}>
            <div className="stop-badge" style={{ background: 'var(--accent-2)' }}><Camera size={14} /></div>
            <div className="grow">
              <div style={{ fontWeight: 650 }}>Sol {n.sol}{n.sol_end !== n.sol ? `–${n.sol_end}` : ''}</div>
              <div className="stop-meta">{fmtDist(n.distance_m)} from {t.name}</div>
            </div>
          </div>
        ))}
      </div>
      <div className="section">
        <h3>Raw images {images && <span className="tag">{shown.length}</span>}</h3>
        {err && <div className="card" style={{ borderColor: 'var(--warning)' }}>Image feed unavailable: {err}</div>}
        {wp && !images && !err && <div className="muted">Loading images for sol {wp.sol}…</div>}
        {images && (
          <>
            <div className="row wrap" style={{ gap: 4, marginBottom: 8 }}>
              {cams.map((c) => <button key={c} className={`btn sm ${camera === c ? 'on' : ''}`} onClick={() => setCamera(c)}>{c}</button>)}
            </div>
            {shown.length === 0 ? <div className="muted">No images for this filter.</div> : (
              <div className="photo-grid">
                {shown.slice(0, 36).map((im) => (
                  <button key={im.id} onClick={() => setBox(im)} title={im.title}>
                    <img src={im.thumb} alt={`${im.camera} sol ${im.sol}`} loading="lazy" referrerPolicy="no-referrer" onError={(e) => { if (e.currentTarget.src !== im.url) e.currentTarget.src = im.url }} />
                    <span className="cam">{im.camera}</span>
                  </button>
                ))}
              </div>
            )}
            <p className="hint">Images: NASA/JPL-Caltech/MSSS raw image feed (unprocessed).</p>
          </>
        )}
      </div>
      {box && (
        <div className="lightbox" onClick={() => setBox(null)}>
          <div onClick={(e) => e.stopPropagation()} style={{ textAlign: 'center' }}>
            <img src={box.url} alt={box.title} referrerPolicy="no-referrer" />
            <div className="cap">{box.title} · {box.camera} · {box.date_taken?.slice(0, 16).replace('T', ' ')} UTC</div>
            <div className="row" style={{ justifyContent: 'center', marginTop: 8 }}>
              <a className="btn sm" href={box.url} target="_blank" rel="noreferrer"><ExternalLink size={13} /> Full size</a>
              <button className="btn sm" onClick={() => setBox(null)}><X size={13} /> Close</button>
            </div>
          </div>
        </div>
      )}
    </>
  )
}
