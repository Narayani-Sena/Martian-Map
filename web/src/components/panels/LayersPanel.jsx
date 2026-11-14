import React from 'react'
import { useStore } from '../../store.js'
import { hms, ltst, marsTime } from '../../lib/mars24.js'
import { fmtDur } from '../../lib/format.js'
import WaysHomeInfo from './WaysHomeInfo.jsx'
import LakeControl from './LakeControl.jsx'
import { ProvChip, ProvKey, VECTOR_PROV, layerProv } from '../../lib/provenance.jsx'

function Legend({ legend }) {
  if (!legend) return null
  if (legend.classes) {
    return (
      <div className="legend legend-classes">
        {legend.classes.map(([label, color]) => (
          <span key={label}><i style={{ background: color === '#00000000' ? 'transparent' : color }} />{label}</span>
        ))}
      </div>
    )
  }
  const stops = legend.stops
  const lo = stops[0][0]
  const hi = stops[stops.length - 1][0]
  const grad = stops.map(([v, c]) => `${c} ${((v - lo) / (hi - lo || 1)) * 100}%`).join(', ')
  return (
    <div className="legend">
      <div className="legend-bar" style={{ background: `linear-gradient(90deg, ${grad})` }} />
      <div className="legend-ticks"><span>{lo}</span><span>{legend.unit}</span><span>{hi}</span></div>
    </div>
  )
}

// Terrain shadow at a chosen moment of the EVA (data-use item E4).
function ShadowTime() {
  const site = useStore((s) => s.site)
  const startUtc = useStore((s) => s.startUtc)
  const total = useStore((s) => s.plan?.totals?.total_s) || 6 * 3600
  const t = useStore((s) => s.shadowT) || 0
  const set = useStore((s) => s.set)
  if (!startUtc) return null
  const when = new Date(new Date(startUtc).getTime() + t * 1000)
  return (
    <label className="field" style={{ marginTop: 6 }}>
      <span>Shadows at <b>T+{fmtDur(t, { short: true })}</b> · {hms(ltst(marsTime(when), site.center.lon), false)} LTST</span>
      <input type="range" min="0" max={Math.max(600, Math.round(total))} step="120" value={Math.min(t, total)} onChange={(e) => set({ shadowT: +e.target.value })} />
    </label>
  )
}

function Switch({ checked, onChange, label }) {
  return (
    <label className="switch" aria-label={label}>
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span />
    </label>
  )
}

const NOTES = {
  hillshade: 'Computed from the 1 m HiRISE terrain model with our own numpy hillshade (four sun directions).',
  elevation: 'Height above the Mars areoid. Blend with the shaded relief for a classic topographic look.',
  slope: 'Slope over a 4 m baseline. Suited walking gets hard above ~15° and the planner forbids anything above the max-slope limit.',
  roughness: 'Metre-scale blockiness: RMS height left after fitting a plane to each 5 × 5 m patch. Rocks smaller than ~1 m are not visible in the data.',
  thermal: 'THEMIS night-time infrared (100 m pixels). Bright = holds heat at night = rock/bedrock; dark = fine sand or dust.',
  hazard: 'Worst of slope, roughness and sand classes, using the limits in Suit & limits.',
  shielding: 'Share of galactic cosmic-ray dose blocked by terrain above the horizon (from 1 m up, incl. crater walls and distant hills). Curiosity measured ~4-5 % next to a butte.',
  skyview: 'Fraction of the sky dome visible from each spot.',
  walkback: 'Fastest walking time from every point back to the habitat (direction-aware Dijkstra on a 4 m grid).',
  comms: 'Line of sight from the habitat mast (and any relays) to a suit antenna 2 m above the ground. Hatched = dead zone.',
}

export default function LayersPanel() {
  const site = useStore((s) => s.site)
  const layers = useStore((s) => s.layers)
  const setLayer = useStore((s) => s.setLayer)
  const base = useStore((s) => s.base)
  const vectors = useStore((s) => s.vectors)
  const toggleVector = useStore((s) => s.toggleVector)
  const set = useStore((s) => s.set)
  const groups = {}
  for (const L of site.layers) (groups[L.group] ||= []).push(L)

  const vectorRows = [
    ['route', 'Planned route'], ['stops', 'Stops & habitat'], ['rings', 'Walk-back rings (15–120 min)'],
    ['traverse', `${site.rover_name}'s traverse`], ['waypoints', `${site.rover_name} stops (by sol)`],
    ['contours', 'Contours (5 m)'], ['shelters', 'Shelters'], ['refuges', 'Terrain radiation refuges'], ['relays', 'Radio relays'],
    ['labels', 'Place names (JPL)'],
    ...((site.files || []).includes('ingenuity.geojson') ? [['ingenuity', 'Ingenuity flights (helicopter)']] : []),
    ['suggestions', 'Suggested science stops'],
    ['grid', 'Radio grid (250 m squares, “Kilo seven”)'],
    ...(site.chemistry ? [['chemistry', `Rover chemistry: ${site.chemistry.instrument}, ${site.chemistry.n_targets} targets`]] : []),
    ['photoviews', `${site.rover_name}'s photos where they were taken (view cones)`],
    ...(site.radar ? [['radar', `Ground radar: RIMFAX under ${site.rover_name}'s track, ${site.radar.sols} sols, ${(site.radar.length_m / 1000).toFixed(1)} km`]] : []),
  ]

  return (
    <>
      <div className="section">
        <h3>Base map</h3>
        <div className="seg small" style={{ width: '100%' }}>
          {[['hirise', site.basemap?.name?.split(' (')[0] || 'HiRISE'], ['ctx', 'CTX 6 m'], ['none', 'None']].map(([id, label]) => (
            <button key={id} className={base === id ? 'on' : ''} style={{ flex: 1 }} onClick={() => set({ base: id })}>{label}</button>
          ))}
        </div>
        <p className="hint">{site.basemap?.attribution}</p>
        {site.team_dem && (
          <p className="hint">JPL's mosaics, rover tracks and samples use the {site.rover_name} team's map frame, which sits {Math.round(site.team_dem.shift_m)} m from our USGS terrain model; they are shifted onto it (measured by matching the two terrain models).</p>
        )}
        <ProvKey />
      </div>

      {Object.entries(groups).map(([group, list]) => (
        <div className="section" key={group}>
          <h3>{group}</h3>
          {list.map((L) => {
            const st = layers[L.id] || { on: false, opacity: L.default_opacity }
            return (
              <div key={L.id} className={`layer ${st.on ? 'on' : ''}`}>
                <div className="row between">
                  <label className="grow" style={{ fontWeight: 600 }} onClick={() => setLayer(L.id, { on: !st.on })}>{L.name} <ProvChip tag={layerProv(L)} /></label>
                  <Switch checked={st.on} onChange={(v) => setLayer(L.id, { on: v })} label={L.name} />
                </div>
                {st.on && (
                  <>
                    <div className="row" style={{ marginTop: 6 }}>
                      <span className="muted" style={{ fontSize: 11, width: 52 }}>Opacity</span>
                      <input type="range" min="0.1" max="1" step="0.05" value={st.opacity} onChange={(e) => setLayer(L.id, { opacity: +e.target.value })} />
                    </div>
                    {L.dynamic === 'sun' && <ShadowTime />}
                    <Legend legend={L.legend} />
                    {L.id === 'ways_home' && <WaysHomeInfo />}
                    {L.dynamic === 'level' && <LakeControl layer={L} />}
                    <p className="hint" style={{ lineHeight: 1.45 }}>{NOTES[L.id] || L.about}{L.source ? ` Source: ${L.source}.` : ''}</p>
                  </>
                )}
              </div>
            )
          })}
        </div>
      ))}

      <div className="section">
        <h3>Vector data</h3>
        <div className="card" style={{ padding: '6px 10px' }}>
          {vectorRows.map(([id, label]) => (
            <div key={id} className="row between" style={{ padding: '5px 0' }}>
              <span style={{ fontSize: 12.5 }}>{label} <ProvChip tag={VECTOR_PROV[id]} /></span>
              <Switch checked={!!vectors[id]} onChange={() => toggleVector(id)} label={label} />
            </div>
          ))}
        </div>
      </div>
    </>
  )
}
