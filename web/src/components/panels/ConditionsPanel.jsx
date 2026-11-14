import React from 'react'
import { AlertTriangle, ExternalLink, Radiation, Siren, Sun, Sunrise, Sunset } from 'lucide-react'
import { useStore } from '../../store.js'
import XYChart, { Legend } from '../charts/XYChart.jsx'
import { hms } from '../../lib/mars24.js'
import { fmtNum, fmtUtc } from '../../lib/format.js'

function Tile({ label, value, unit, sub }) {
  return (
    <div className="tile">
      <div className="label">{label}</div>
      <div className="value">{value}{unit && <small>{unit}</small>}</div>
      {sub && <div className="sub">{sub}</div>}
    </div>
  )
}

export default function ConditionsPanel() {
  const c = useStore((s) => s.conditions)
  const sw = useStore((s) => s.spaceWeather)
  const sep = useStore((s) => s.sepActive)
  const plan = useStore((s) => s.plan)
  const set = useStore((s) => s.set)
  const live = useStore((s) => s.liveWeather)
  const site = useStore((s) => s.site)
  if (!c) return <div className="muted">Loading conditions…</div>
  const curve = c.sol_curve
  const status = sep ? 'RED' : sw?.status
  const cls = status === 'GREEN' ? 'go' : status === 'AMBER' ? 'amber' : status === 'RED' ? 'nogo' : 'idle'

  return (
    <>
      <div className="section">
        <h3>Sun at the site now</h3>
        <div className="card">
          <div className="row between">
            <div className="row"><Sun size={18} color="var(--warning)" /><span className="mono" style={{ fontSize: 18, fontWeight: 600 }}>{c.sun.elevation.toFixed(1)}°</span><span className="muted">elevation</span></div>
            <span className="mono dim">az {c.sun.azimuth.toFixed(0)}°</span>
          </div>
          <div className="row between" style={{ marginTop: 8, fontSize: 12 }}>
            <span className="row"><Sunrise size={14} /> {c.sun.sunrise_ltst != null ? hms(c.sun.sunrise_ltst, false) : '—'}</span>
            <span className="muted">LTST</span>
            <span className="row"><Sunset size={14} /> {c.sun.sunset_ltst != null ? hms(c.sun.sunset_ltst, false) : '—'}</span>
          </div>
          {c.sun.terrain_sunrise_ltst != null && (
            <p className="hint" style={{ margin: '6px 0 0' }}>Over the terrain at the hab: {hms(c.sun.terrain_sunrise_ltst, false)} → {hms(c.sun.terrain_sunset_ltst, false)} LTST (the times above assume a flat horizon; hills to the {c.sun.hab_horizon_deg ? ['north', 'east', 'south', 'west'][[0, 6, 12, 18].map((k) => Math.max(...c.sun.hab_horizon_deg.slice(k, k + 6))).reduce((bi, v, i, a) => (v > a[bi] ? i : bi), 0)] : 'east'} rise to {c.sun.hab_horizon_deg ? Math.max(...c.sun.hab_horizon_deg).toFixed(0) : '—'}°).</p>
          )}
          <p className="hint">Ls {c.ls}° ({c.season}) · Mars Year {c.mars_year} · Sun {c.helio_au} AU away · {fmtNum(c.sun.toa_wm2)} W/m² at the top of the atmosphere ({fmtNum((c.sun.toa_wm2 / 1361) * 100)} % of Earth's)</p>
        </div>
      </div>

      <div className="section">
        <h3>Through the sol</h3>
        <div style={{ height: 120 }}>
          <XYChart x={curve.ltst} series={[{ id: 'sun', color: 'var(--series-1)', values: curve.sun_elev, area: true, areaBase: 0 }]}
            xDomain={[0, 24]} minY={0} xFmt={(v) => `${v}h`} yFmt={(v) => `${v}°`} yLabel="Sun elevation" margin={{ l: 36, r: 8, t: 6, b: 20 }}
            markers={[{ x: c.ltst_h, color: 'var(--accent)' }]} thresholds={[{ y: 0, color: 'var(--axis)' }]}
            tooltip={(i) => ({ head: `${hms(curve.ltst[i], false)} LTST`, rows: [{ label: 'Sun', value: `${curve.sun_elev[i]}°`, color: 'var(--series-1)' }] })} />
        </div>
        <div className="chart-sub" style={{ margin: '6px 0 2px' }}>Sun elevation (°)</div>
        <div style={{ height: 130, marginTop: 8 }}>
          <XYChart x={curve.ltst} series={[{ id: 'air', color: 'var(--series-1)', values: curve.air_c }, { id: 'ground', color: 'var(--series-2)', values: curve.ground_c }]}
            xDomain={[0, 24]} xFmt={(v) => `${v}h`} yFmt={(v) => `${v}°`} yLabel="Temperature" margin={{ l: 36, r: 8, t: 6, b: 20 }}
            markers={[{ x: c.ltst_h, color: 'var(--accent)' }]}
            tooltip={(i) => ({ head: `${hms(curve.ltst[i], false)} LTST`, rows: [{ label: 'Air (1.5 m)', value: `${curve.air_c[i]} °C`, color: 'var(--series-1)' }, { label: 'Ground', value: `${curve.ground_c[i]} °C`, color: 'var(--series-2)' }] })} />
        </div>
        <div className="row between" style={{ marginTop: 6 }}>
          <span className="chart-sub">Temperature (°C)</span>
          <Legend items={[{ label: 'Air 1.5 m', color: 'var(--series-1)' }, { label: 'Ground', color: 'var(--series-2)' }]} />
        </div>
      </div>

      <div className="section">
        <h3>Weather now <span className="tag">{c.weather.calibrated ? 'REMS-calibrated' : 'model'}</span></h3>
        <div className="tiles">
          <Tile label="Air" value={c.weather.air_c} unit="°C" sub={`${c.weather.air_min_c} to ${c.weather.air_max_c} today`} />
          <Tile label="Ground" value={c.weather.ground_c} unit="°C" />
          <Tile label="Pressure" value={fmtNum(c.weather.pressure_pa)} unit="Pa" sub="~0.8 % of Earth's" />
          <Tile label="Dust opacity τ" value={c.weather.tau} sub={c.weather.tau > 0.9 ? 'dusty season' : 'clear season'} />
          <Tile label="UV index" value={c.weather.uv_index} />
          <Tile label="Wind" value={c.weather.wind_ms} unit="m/s" sub="typical for the hour" />
        </div>
        <p className="hint">{c.weather.model}.</p>
      </div>

      {live?.available && (
        <div className="section">
          <h3>Measured by {site.rover_name} <span className="tag">{site.mission === 'MSL' ? 'REMS' : 'MEDA'}</span></h3>
          <div className="tiles">
            <Tile label={`Air · sol ${live.latest.sol}`} value={`${live.latest.min_c} / ${live.latest.max_c}`} unit="°C" sub={`${live.latest.date} · Ls ${Math.round(live.latest.ls)}°`} />
            <Tile label="Ground" value={`${live.latest.ground_min_c} / ${live.latest.ground_max_c}`} unit="°C" />
            <Tile label="Pressure" value={fmtNum(live.latest.pressure_pa)} unit="Pa" sub={live.latest.opacity} />
            {live.same_season_last_year && (
              <Tile label="Same season, 1 Mars year ago" value={`${live.same_season_last_year.min_c} / ${live.same_season_last_year.max_c}`} unit="°C"
                sub={`sols ${live.same_season_last_year.sol_from}–${live.same_season_last_year.sol_to} · ${fmtNum(live.same_season_last_year.pressure_pa)} Pa`} />
            )}
          </div>
          <p className="hint">{live.stale
            ? `The public ${site.mission === 'MSL' ? 'REMS' : 'MEDA'} feed has had no new sols since ${live.latest.date} (${live.lag_sols} sols ago), so these values are for reference only.`
            : `The newest measured sol is ${live.lag_sols} sols old (${site.mission === 'MSL' ? 'REMS' : 'MEDA'} data reach the public feed with a delay), so last year's values at the same season are the best data-based forecast for today.`}
            {live.model_vs_measured && ` Our plain model was off by ${live.model_vs_measured.error_min_c} / ${live.model_vs_measured.error_max_c} °C on sol ${live.latest.sol}, which is why the numbers above are calibrated with the measurements.`}</p>
        </div>
      )}

      <div className="section">
        <h3>Radiation</h3>
        <div className="tiles">
          <Tile label="Cosmic rays (open sky)" value={c.radiation.gcr_usv_h} unit="µSv/h" sub={`${c.radiation.gcr_msv_day} mSv per sol`} />
          <Tile label="This EVA" value={plan ? fmtNum(plan.totals.dose_usv) : '—'} unit="µSv" sub={plan ? `${fmtNum(plan.totals.dose_usv / 1000 / 600 * 100, 3)} % of a 600 mSv career limit` : ''} />
        </div>
        <p className="hint">Curiosity's RAD measured ≈0.64 mSv/day on the surface at Gale (reduced ~15 % near solar maximum); we use it for every site. The big May 2024 solar storm delivered ≈8,100 µGy in a day — the habitat is the real shelter; terrain only blocks a few percent (see the shielding layer).</p>
      </div>

      <div className="section">
        <h3>Space weather <span className={`pill ${cls}`} style={{ padding: '3px 8px' }}><span className="dot" />{status || '…'}</span></h3>
        <div className="card">
          <ul className="issues">
            {(sep ? ['Solar-storm drill active: an SEP event is being simulated at Mars'] : sw?.reasons || []).map((r, i) => (
              <li key={i}><AlertTriangle size={15} color={status === 'GREEN' ? 'var(--good-ink)' : 'var(--warning)'} /><span>{r}</span></li>
            ))}
          </ul>
          <div className="divider" />
          <div className="chart-sub" style={{ marginBottom: 4 }}>CME arrivals predicted at Mars (WSA-ENLIL)</div>
          {sw?.mars_arrivals?.length ? sw.mars_arrivals.slice(-5).reverse().map((a, i) => (
            <div key={i} className="row between" style={{ fontSize: 12, padding: '3px 0' }}>
              <span className="mono">{fmtUtc(a.arrival)}</span>
              <span className="dim">{a.hours_from_now > 0 ? `in ${Math.round(a.hours_from_now)} h` : `${Math.round(-a.hours_from_now)} h ago`}{a.glancing ? ' · glancing' : ''}{a.speed_kms ? ` · ${a.speed_kms} km/s` : ''}</span>
            </div>
          )) : <div className="muted" style={{ fontSize: 12 }}>None in the last 30 days.</div>}
          <div className="divider" />
          <div className="chart-sub" style={{ marginBottom: 4 }}>Recent M/X-class flares</div>
          {sw?.flares?.length ? sw.flares.slice(0, 4).map((f, i) => (
            <div key={i} className="row between" style={{ fontSize: 12, padding: '2px 0' }}>
              <span className="mono"><b>{f.class}</b></span><span className="dim">{f.hours_ago != null ? `${Math.round(f.hours_ago)} h ago` : ''}{f.region ? ` · AR ${f.region}` : ''}</span>
            </div>
          )) : <div className="muted" style={{ fontSize: 12 }}>None.</div>}
          <p className="hint">Source: {sw?.source || 'NASA DONKI'} · {sw?.key === 'DEMO_KEY' ? 'DEMO_KEY (set NASA_API_KEY for more requests)' : 'personal key'} · cached {sw?.cache_age_min != null ? `${sw.cache_age_min} min ago` : '—'}{sw?.errors?.length ? ` · errors: ${sw.errors.join(', ')}` : ''}</p>
          <a href="https://kauai.ccmc.gsfc.nasa.gov/DONKI/" target="_blank" rel="noreferrer" className="row" style={{ fontSize: 12, gap: 4 }}>DONKI <ExternalLink size={12} /></a>
        </div>
        <button className={`btn ${sep ? 'on' : ''}`} style={{ marginTop: 10, width: '100%' }} onClick={() => set({ sepActive: !sep })}>
          <Siren size={14} /> {sep ? 'End solar-storm drill' : 'Run a solar-storm drill'}
        </button>
        <p className="hint"><Radiation size={11} style={{ verticalAlign: -1 }} /> The drill adds an SEP dose to the plan and triggers storm alerts in the helmet view.</p>
      </div>
    </>
  )
}
