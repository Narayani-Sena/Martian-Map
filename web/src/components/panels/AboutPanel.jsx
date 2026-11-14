import React from 'react'
import { ExternalLink } from 'lucide-react'
import { useStore } from '../../store.js'

const A = ({ href, children }) => <a href={href} target="_blank" rel="noreferrer">{children} <ExternalLink size={10} style={{ verticalAlign: -1 }} /></a>
const pct = (v) => `${Math.round(v * 100)} %`

export default function AboutPanel() {
  const site = useStore((s) => s.site)
  const crism = (site.layers || []).filter((L) => L.id.startsWith('crism_'))
  const team = site.team_dem
  const sand = site.sand
  const chk = sand?.check_bedform_unit
  const heli = site.ingenuity
  const tc = site.terrain_confidence
  return (
    <>
      <div className="section">
        <h3>The scenario</h3>
        <p className="dim" style={{ lineHeight: 1.55, margin: 0 }}>{site.story}</p>
      </div>
      <div className="section">
        <h3>Data used for this site</h3>
        <div className="card" style={{ fontSize: 12, lineHeight: 1.6 }}>
          <div><b>Terrain</b> — HiRISE stereo DTMs, 1 m posting: {(site.dem_sources || []).map((d) => d.id).join(', ')} (<A href="https://stac.astrogeology.usgs.gov/docs/data/mars/hirise_dtms/">USGS STAC</A>)</div>
          {team && <div><b>Rover team's terrain</b> — {team.name} ({team.team}), read in strips from USGS to line up everything the team publishes</div>}
          <div><b>Wide terrain</b> — HRSC + MOLA blended DEM, 200 m (<A href="https://astrogeology.usgs.gov/search/map/mars_mgs_mola_mex_hrsc_blended_dem_global_200m">USGS</A>)</div>
          <div><b>Imagery</b> — {site.basemap?.attribution}</div>
          <div><b>Thermal</b> — THEMIS night-IR controlled mosaic {site.thermal_source?.id || ''} (USGS STAC){site.thermal_day_source ? '; THEMIS day IR from NASA Mars Trek' : ''}</div>
          {crism.length > 0 && <div><b>Minerals</b> — MRO CRISM MTRDR composites: {crism.map((L) => L.name.replace('CRISM ', '')).join(', ')}</div>}
          {site.geology && <div><b>Geology</b> — {site.geology.map}, {site.geology.scale} (<A href={site.geology.url}>USGS</A>)</div>}
          <div><b>Rover</b> — {site.rover_name} waypoints & traverse from JPL MMGIS; raw images from <A href="https://mars.nasa.gov/msl/multimedia/raw-images/">mars.nasa.gov</A></div>
          {heli && <div><b>Ingenuity</b> — {heli.flights} flights near the site ({heli.in_site} over it, flights {heli.first}–{heli.last}) from JPL MMGIS; its photos from the raw-image feed</div>}
          <div><b>Space weather</b> — <A href="https://ccmc.gsfc.nasa.gov/tools/DONKI/">NASA DONKI</A> (WSA-ENLIL Mars arrivals, flares, SEPs)</div>
          <div><b>Time & sun</b> — our implementation of NASA GISS <A href="https://www.giss.nasa.gov/tools/mars24/help/algorithm.html">Mars24</A></div>
        </div>
      </div>
      <div className="section">
        <h3>How it works</h3>
        <ul className="dim" style={{ paddingLeft: 18, margin: 0, lineHeight: 1.6, fontSize: 12 }}>
          <li>Slope, shading, roughness and horizon angles are computed with our own numpy code (tested against known surfaces).</li>
          <li>Routes: our A* in plain Python on a 2 m grid, with direction-aware Tobler walking speed; compare against scikit-image's Dijkstra.</li>
          <li>Walk-back rings: Dijkstra over reversed edges on a 4 m grid, so each value is the time to return, not to leave.</li>
          <li>Radio dead zones: vectorised line-of-sight ray casting incl. Mars curvature.</li>
          <li>Horizon: 24 directions from every 4 m cell, 1 m above ground, out to 45 km (crater walls and mountains included). It gives the radiation shielding, and sunrise, sunset and shadows over the real terrain.</li>
          <li>Loose sand: night IR (sand cools fast), HiRISE darkness and the mapped dune unit say how much of each ~100 m patch is sand; hollows and dark spots inside it get it.{chk ? ` Checked on Jezero's mapped bedforms without using the map: ${chk.in_mean.toFixed(2)} inside against ${chk.out_mean.toFixed(2)} outside, ${pct(chk.out_flagged_ge_058)} of the rest flagged.` : ''}</li>
          {team && <li>Rover team's frame: phase correlation of the two terrain models puts the team's products {Math.round(team.shift_m)} m away sideways ({team.dx_m.toFixed(1)} m east, {team.dy_m.toFixed(1)} m north) and {team.dz_m.toFixed(1)} m in height; rover tracks, samples, flights and the colour mosaics are moved by that. After lining up, the two models differ by {team.median_abs_m} m (median).</li>}
          <li>Science score: strong CRISM signals, map-unit contacts, ridge crests and hollow floors, rover sample sites; SUGGEST STOPS picks the best within the walk-back limit.</li>
          <li>Space weather: each DONKI CME arrival forecast is a ±12 h window, compared with the time in suits.</li>
          <li>Suit: oxygen from metabolic work (≈0.26 g per Wh), battery with heaters (more in terrain shadow), CO₂ scrubber and cooling water; the plan keeps enough to walk back × a factor + a reserve at every moment, and shows the margin again with the metabolic rate and walking speed pushed both ways.</li>
        </ul>
      </div>
      <div className="section">
        <h3>Limits — read before trusting it</h3>
        <ul className="dim" style={{ paddingLeft: 18, margin: 0, lineHeight: 1.6, fontSize: 12 }}>
          <li>A 1 m DTM cannot see rocks under ~1–2 m. Real EVAs need rover or drone scouting.</li>
          <li>Weather is a climatology model, not a forecast.</li>
          <li>The sand likelihood is a model checked on one mapped dune field, not a measurement; the <i>Sand estimate confidence</i> layer shows where its clues disagree{sand ? ` (on average ${pct(sand.confidence_mean)} here)` : ''}.</li>
          {tc && <li>Terrain confidence compares two stereo models{tc.share_low != null ? `; ${pct(tc.share_low)} of this site is marked low` : ''}. Both can be wrong in the same place.</li>}
          <li>CME arrival forecasts miss by about 10 h at Earth; nobody scores them at Mars.</li>
          <li>Suit and walking numbers are planning assumptions from Apollo and analogue studies.</li>
          <li>Not an operational tool.</li>
        </ul>
      </div>
      <div className="section">
        <h3>Shortcuts</h3>
        <dl className="kv"><dt>Esc</dt><dd>cancel map tool</dd><dt>Right-click map</dt><dd>actions</dd><dt>Walk mode</dt><dd>WASD · mouse · Space · P autopilot</dd></dl>
      </div>
    </>
  )
}
