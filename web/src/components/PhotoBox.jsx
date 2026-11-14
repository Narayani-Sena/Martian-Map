import React from 'react'
import { ExternalLink, MapPin, X } from 'lucide-react'
import { useStore } from '../store.js'

const COMPASS = ['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west']
export const compass = (az) => COMPASS[Math.round((((az % 360) + 360) % 360) / 45) % 8]

// One of the rover's photos, opened from its view cone on the map (feature E3): where the camera stood and where it
// looked, from the raw-image feed's camera model and the rover's attitude.
export default function PhotoBox() {
  const p = useStore((s) => s.photoBox)
  const set = useStore((s) => s.set)
  if (!p) return null
  const close = () => set({ photoBox: null })
  return (
    <div className="lightbox" onClick={close}>
      <div onClick={(e) => e.stopPropagation()} style={{ textAlign: 'center', maxWidth: 1100 }}>
        <img src={p.url} alt={`${p.rover}'s ${p.camera}, sol ${p.sol}`} referrerPolicy="no-referrer" />
        <div className="cap">
          {p.rover}'s {p.camera} · sol {Math.round(p.sol)} · {p.date_taken?.slice(0, 16).replace('T', ' ')} UTC · looking {compass(p.az)}{' '}
          ({Math.round(p.az)}°, {p.el > 0 ? '+' : ''}{Math.round(p.el)}°) · {Math.round(p.hfov)}° × {Math.round(p.vfov)}° · camera {p.cam_h_m} m above the ground
        </div>
        <div className="cap muted" style={{ fontSize: 12 }}>
          The pose comes from the raw-image feed's camera model and the rover's attitude. In the 3D console, Shift+P stands
          you exactly here and wipes this photo against the terrain model.
        </div>
        <div className="row" style={{ justifyContent: 'center', marginTop: 8 }}>
          <a className="btn sm" href={p.url} target="_blank" rel="noreferrer"><ExternalLink size={13} /> Full size</a>
          <button className="btn sm" onClick={() => set({ photoBox: null, focus: { lon: p.lon, lat: p.lat, t: Date.now() } })}><MapPin size={13} /> Show on map</button>
          <button className="btn sm" onClick={close}><X size={13} /> Close</button>
        </div>
      </div>
    </div>
  )
}
