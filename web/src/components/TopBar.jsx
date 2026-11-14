import React, { useEffect, useState } from 'react'
import { Box, Footprints, Layers3, Map as MapIcon, Radiation, ShieldCheck, ShieldAlert, SunMedium } from 'lucide-react'
import { useStore } from '../store.js'
import { hms, ltst, lmst, marsTime, missionSol, seasonName } from '../lib/mars24.js'

function useNow(ms = 1000) {
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), ms)
    return () => clearInterval(t)
  }, [ms])
  return now
}

export function Logo({ size = 26 }) {
  return (
    <svg className="brand-mark" width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <defs>
        <radialGradient id="lg" cx="38%" cy="34%" r="70%">
          <stop offset="0" stopColor="#ffb07a" />
          <stop offset="0.55" stopColor="#e2602b" />
          <stop offset="1" stopColor="#7a2410" />
        </radialGradient>
      </defs>
      <circle cx="32" cy="32" r="26" fill="url(#lg)" />
      <path d="M14 38c8-6 14 2 22-3s10-9 16-6" fill="none" stroke="#fff3e6" strokeWidth="3" strokeLinecap="round" opacity=".9" />
      <circle cx="44" cy="27" r="3.5" fill="#fff3e6" />
    </svg>
  )
}

export default function TopBar() {
  const now = useNow()
  const site = useStore((s) => s.site)
  const sites = useStore((s) => s.sites)
  const siteId = useStore((s) => s.siteId)
  const mode = useStore((s) => s.mode)
  const plan = useStore((s) => s.plan)
  const planError = useStore((s) => s.planError)
  const sw = useStore((s) => s.spaceWeather)
  const sep = useStore((s) => s.sepActive)
  const light = useStore((s) => s.light)
  const set = useStore((s) => s.set)

  const mt = marsTime(now)
  const lon = site.center.lon
  const sol = missionSol(mt, lon, site.rover.landing_msd_local)
  const swStatus = sep ? 'RED' : sw?.status || '…'
  const swClass = swStatus === 'GREEN' ? 'go' : swStatus === 'AMBER' ? 'amber' : swStatus === 'RED' ? 'nogo' : 'idle'
  const go = plan?.totals?.go
  const evaClass = planError ? 'idle' : plan ? (go ? 'go' : 'nogo') : 'idle'

  const modes = [
    { id: 'plan', label: 'PLAN', icon: MapIcon },
    { id: 'tower', label: 'TOWER', icon: Layers3 },
    { id: '3d', label: '3D', icon: Box },
    { id: 'walk', label: 'WALK', icon: Footprints },
  ]

  return (
    <header className="topbar">
      <div className="brand">
        <Logo />
        <div>
          <b>MARTIAN MAP</b>
          <small>EVA navigator</small>
        </div>
      </div>
      <select className="site-select" value={siteId || ''} onChange={(e) => set({ siteId: e.target.value })} aria-label="Site">
        {sites.map((s) => (
          <option key={s.id} value={s.id} disabled={!s.built}>
            {s.short_name}{s.built ? '' : ' (not built)'}
          </option>
        ))}
      </select>
      <div className="seg" role="tablist" aria-label="Mode">
        {modes.map(({ id, label, icon: Icon }) => (
          <button key={id} className={mode === id ? 'on' : ''} onClick={() => set({ mode: id, ...(id === 'tower' ? { panel: null } : {}) })} role="tab" aria-selected={mode === id}>
            <Icon size={14} /> {label}
          </button>
        ))}
      </div>

      <div className="clock">
        <div className="cell hide-md" title={`${site.rover_name} mission sol (local mean solar time at the site)`}>
          <span>{site.rover_name} sol</span>
          <b>{sol}</b>
        </div>
        <div className="cell" title="Local true solar time at the site (sundial time)">
          <span>LTST</span>
          <b>{hms(ltst(mt, lon))}</b>
        </div>
        <div className="cell hide-sm" title="Local mean solar time">
          <span>LMST</span>
          <b>{hms(lmst(mt, lon))}</b>
        </div>
        <div className="cell hide-sm" title="Solar longitude: Mars' position around the Sun (season)">
          <span>Ls · MY{mt.marsYear}</span>
          <b>{mt.ls.toFixed(1)}° {seasonName(mt.ls, site.center.lat)}</b>
        </div>
        <div className="cell hide-sm" title="Earth time">
          <span>UTC</span>
          <b>{now.toISOString().slice(11, 19)}</b>
        </div>
        <span className={`pill button light-toggle ${light === 'earth' ? 'earth' : ''}`} role="button" aria-pressed={light === 'earth'}
          title={"Geologist's white balance: show the ground, the 3D view and the rover photos in Earth-like light, so rock colours read as they would at home. The rover teams publish both natural and white-balanced colour."}
          onClick={() => { const v = light === 'earth' ? 'mars' : 'earth'; try { localStorage.setItem('martian-map:light', v) } catch { /* private mode */ } set({ light: v }) }}>
          <SunMedium size={13} /> <span className="hide-xs">{light === 'earth' ? 'EARTH LIGHT' : 'MARS LIGHT'}</span>
        </span>
        <span
          className={`pill button ${swClass}`}
          title={(sep ? ['Simulated solar storm drill is ON'] : sw?.reasons || []).join('\n')}
          onClick={() => set({ panel: 'conditions' })}
        >
          <span className="dot" /> <Radiation size={13} /> <span className="hide-xs">SPACE WX</span> {swStatus}
        </span>
        <span className={`pill button ${evaClass}`} title={plan?.issues?.map((i) => i.text).join('\n') || planError || ''}
          role="button" aria-label="EVA summary"
          onClick={() => (window.matchMedia('(max-width: 1180px)').matches
            ? set((s) => ({ summaryOpen: !s.summaryOpen, ...(!s.summaryOpen && window.matchMedia('(max-width: 900px)').matches ? { panel: null } : {}) }))
            : set({ panel: 'mission' }))}>
          <span className="dot" /> {go ? <ShieldCheck size={13} /> : <ShieldAlert size={13} />} <span className="hide-xs">EVA</span> {planError ? '—' : plan ? (go ? 'GO' : 'NO-GO') : '…'}
        </span>
      </div>
    </header>
  )
}
