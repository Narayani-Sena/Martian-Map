import React, { Suspense, lazy, useEffect, useRef } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { AlertTriangle, CheckCircle2, Info } from 'lucide-react'
import { api } from './api.js'
import { missionBody, useStore } from './store.js'
import TopBar from './components/TopBar.jsx'
import LeftRail from './components/LeftRail.jsx'
import MapView from './components/MapView.jsx'
import RightPanel from './components/RightPanel.jsx'
import BottomDrawer from './components/BottomDrawer.jsx'
import PrintChecklist from './components/PrintChecklist.jsx'
import TowerView from './components/TowerView.jsx'
import RadarView from './components/RadarView.jsx'
import PhotoBox from './components/PhotoBox.jsx'

const Scene3D = lazy(() => import('./components/Scene3D.jsx'))

// Recompute the EVA plan whenever anything it depends on changes (debounced, cancellable).
function usePlanner() {
  const deps = useStore(useShallow((s) => [s.siteId, s.habitat, s.stops, s.relays, s.radio, s.walk, s.suit, s.algorithm, s.astarWeight, s.startUtc, s.sepActive, s.returnToHab, s.rover, s.cmeDrill, s.tagKey]))
  const timer = useRef(null)
  const ctrl = useRef(null)
  useEffect(() => {
    const s = useStore.getState()
    if (!s.site || !s.habitat) return
    clearTimeout(timer.current)
    timer.current = setTimeout(async () => {
      const st = useStore.getState()
      if (st.stops.length === 0) {
        st.set({ plan: null, planError: 'Add a stop to plan an EVA', planLoading: false })
        return
      }
      ctrl.current?.abort()
      ctrl.current = new AbortController()
      st.set({ planLoading: true })
      try {
        const plan = await api.plan(st.siteId, missionBody(st), ctrl.current.signal)
        useStore.getState().set({ plan, planError: null, planLoading: false })
      } catch (e) {
        if (e.name === 'AbortError') return
        useStore.getState().set({ planError: e.message, planLoading: false })
      }
      useStore.getState().saveMission()
    }, 350)
    return () => clearTimeout(timer.current)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
}

function useSiteLoader() {
  const siteId = useStore((s) => s.siteId)
  const set = useStore((s) => s.set)
  useEffect(() => {
    api.sites().then((sites) => {
      const built = sites.filter((s) => s.built)
      const fromHash = window.location.hash.replace('#', '')
      const pick = built.find((s) => s.id === fromHash) || built[0]
      set({ sites, siteId: pick?.id ?? null, siteError: pick ? null : 'No site has been built yet. Run: python -m pipeline.build_site gale_boxwork' })
    }).catch((e) => set({ siteError: `Cannot reach the API (${e.message}). Is the backend running on port 8000?` }))
  }, [set])
  useEffect(() => {
    if (!siteId) return
    window.location.hash = siteId
    let alive = true
    set({ site: null })
    api.site(siteId).then((site) => {
      if (!alive) return
      set({ site })
      useStore.getState().loadMission(site)
      api.tags(siteId).then((t) => { if (alive) set({ tags: t.tags, tagKey: t.version }) }).catch(() => {})
    }).catch((e) => set({ siteError: e.message }))
    return () => { alive = false }
  }, [siteId, set])
}

function useConditions() {
  const site = useStore((s) => s.site)
  const set = useStore((s) => s.set)
  useEffect(() => {
    if (!site) return
    const load = () => api.conditions(site.id).then((c) => set({ conditions: c })).catch(() => {})
    load()
    const t = setInterval(load, 5 * 60 * 1000)
    return () => clearInterval(t)
  }, [site, set])
  useEffect(() => {
    if (!site) return undefined
    let alive = true
    const load = () => api.liveWeather(site.id).then((w) => { if (alive) set({ liveWeather: w }) }).catch(() => {})
    load()
    const id = setInterval(load, 3 * 3600 * 1000)
    return () => { alive = false; clearInterval(id) }
  }, [site?.id])
  useEffect(() => { // the interplanetary map (feature A5): planets move slowly, every 10 min is plenty
    const load = () => api.orrery().then((o) => set({ orrery: o })).catch(() => {})
    load()
    const t = setInterval(load, 10 * 60 * 1000)
    return () => clearInterval(t)
  }, [set])
  useEffect(() => {
    const load = () => api.spaceWeather().then((w) => set({ spaceWeather: w })).catch((e) => set({ spaceWeather: { status: 'UNKNOWN', reasons: [e.message], errors: [e.message], mars_arrivals: [], flares: [], seps: [] } }))
    load()
    const t = setInterval(load, 30 * 60 * 1000)
    return () => clearInterval(t)
  }, [set])
}

function Toast() {
  const toast = useStore((s) => s.toast)
  if (!toast) return null
  const Icon = toast.kind === 'error' ? AlertTriangle : toast.kind === 'ok' ? CheckCircle2 : Info
  return (
    <div className={`toast ${toast.kind}`} role="status">
      <Icon size={16} /> {toast.text}
    </div>
  )
}

function Splash() {
  const err = useStore((s) => s.siteError)
  return (
    <div className="splash">
      <div className="inner">
        <div className="planet" />
        <div style={{ fontSize: 22, fontWeight: 700 }}>Martian Map</div>
        <div className="muted" style={{ marginTop: 6 }}>{err || 'Loading terrain, imagery and mission data…'}</div>
      </div>
    </div>
  )
}

// Geologist's white balance (feature G6): a von Kries diagonal scaling in linear RGB that takes out the dusty red cast
// of Martian daylight, so rock colours read as they would under Earth's sky (the rover teams publish both).
function WhiteBalanceFilter() {
  return (
    <svg width="0" height="0" style={{ position: 'absolute' }} aria-hidden="true" focusable="false">
      <filter id="wb-earth" colorInterpolationFilters="linearRGB">
        <feColorMatrix type="matrix" values="0.82 0 0 0 0  0 1.05 0 0 0  0 0 1.40 0 0  0 0 0 1 0" />
      </filter>
    </svg>
  )
}

export default function App() {
  useSiteLoader()
  usePlanner()
  useConditions()
  const site = useStore((s) => s.site)
  const mode = useStore((s) => s.mode)
  const planLoading = useStore((s) => s.planLoading)
  const light = useStore((s) => s.light)

  if (!site) return <Splash />
  const walk = mode === 'walk'
  return (
    <>
      <div className={`app ${light === 'earth' ? 'wb-earth' : ''}`}>
        <WhiteBalanceFilter />
        <TopBar />
        <div className="workspace" style={walk ? { gridTemplateColumns: '1fr' } : undefined}>
          {!walk && <LeftRail />}
          <div className="center">
            <div className="stage">
              {planLoading && <div className="loading-bar" />}
              {mode === 'plan' && <MapView />}
              {mode === 'plan' && <RadarView />}
              {mode === 'tower' && <TowerView />}
              {(mode === '3d' || mode === 'walk') && (
                <Suspense fallback={<div className="splash" style={{ zIndex: 1 }}><div className="inner"><div className="planet" /><div className="muted">Building the 3D scene…</div></div></div>}>
                  <Scene3D walk={walk} />
                </Suspense>
              )}
            </div>
            {!walk && mode !== 'tower' && <BottomDrawer />}
          </div>
          {!walk && mode !== 'tower' && <RightPanel />}
        </div>
        <PhotoBox />
      </div>
      <PrintChecklist />
      <Toast />
    </>
  )
}
