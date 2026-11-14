import React from 'react'

// Where each thing on the map comes from, in five words used everywhere in the planner.
export const PROV = {
  MEASURED: { color: '#4fd1ff', text: 'An instrument reading: what a camera, spectrometer, radar or rover recorded.' },
  MAPPED: { color: '#b48cff', text: 'Drawn or published by scientists from the measurements (a geologic map, a lake level).' },
  DERIVED: { color: '#3ccf3c', text: 'Computed from measurements by geometry alone (slope, shading, line of sight).' },
  MODELED: { color: '#fab219', text: 'Our model, with stated assumptions: read its limits before trusting it.' },
  RULE: { color: '#ff7a3d', text: 'A mission rule: the limits you set under Suit & limits decide it.' },
  PLAN: { color: '#b6c0cd', text: 'Your plan: placed by you or by the planner.' },
}

const LAYER_PROV = {
  hillshade: 'DERIVED', elevation: 'MEASURED', slope: 'DERIVED', roughness: 'DERIVED', thermal: 'MEASURED',
  thermal_day: 'MEASURED', sand: 'MODELED', hazard: 'RULE', boulders: 'DERIVED', shielding: 'DERIVED',
  skyview: 'DERIVED', walkback: 'MODELED', ways_home: 'MODELED', comms: 'DERIVED', geology: 'MAPPED',
  science: 'MODELED', shadow: 'DERIVED', rescue: 'MODELED', skyline_fix: 'MODELED', scouted: 'DERIVED',
  sand_conf: 'MODELED', terrain_conf: 'DERIVED',
}

export const VECTOR_PROV = {
  route: 'PLAN', stops: 'PLAN', rings: 'MODELED', traverse: 'MEASURED', waypoints: 'MEASURED', contours: 'DERIVED',
  shelters: 'PLAN', refuges: 'DERIVED', relays: 'PLAN', labels: 'MAPPED', ingenuity: 'MEASURED', suggestions: 'MODELED',
  grid: 'PLAN', chemistry: 'MEASURED', photoviews: 'MEASURED', radar: 'MEASURED',
}

export function layerProv(L) {
  if (L.id.startsWith('crism_')) return 'MEASURED'
  if (L.id === 'lake') return (L.levels || []).some((v) => v.published) ? 'MAPPED' : 'MODELED'
  return LAYER_PROV[L.id] || null
}

export function ProvChip({ tag }) {
  const p = PROV[tag]
  if (!p) return null
  return <span className="prov" title={`${tag}: ${p.text}`}><i style={{ background: p.color }} />{tag}</span>
}

export function ProvKey() {
  return (
    <details className="prov-key">
      <summary>Every layer says where it comes from {Object.keys(PROV).map((t) => <ProvChip key={t} tag={t} />)}</summary>
      <dl>
        {Object.entries(PROV).map(([t, p]) => (
          <React.Fragment key={t}><dt><ProvChip tag={t} /></dt><dd>{p.text}</dd></React.Fragment>
        ))}
      </dl>
    </details>
  )
}
