import React, { useEffect, useState } from 'react'
import { ChevronLeft, ChevronRight, X } from 'lucide-react'
import { useStore } from '../store.js'

export const TOUR_SEEN_KEY = 'martian-map:tour-seen'

// The guided tour: one minute through the planner, a spotlight on each part. Shown once on the first visit (or with
// ?tour in the address), and from TOUR in the top bar. Each step may open a panel; sel lists targets, first found wins.
function tourSteps(site) {
  const rover = site.rover_name
  return [
    { title: 'Welcome to Martian Map',
      text: `Plan a walk on Mars over NASA's own data, check that the crew can always get home, then walk it. This is ${site.short_name}: ${site.region}. Eleven stops, about a minute. Enter or the arrow keys move on; Esc closes.` },
    { sel: ['.stage'], panel: 'mission', place: 'inside', title: 'The plan on real ground',
      text: 'HiRISE imagery over a 1 m terrain model. The route links the science stops, and the rings give the minutes it takes to walk back to the habitat from anywhere. Drag a pin to move it; right-click the map for more.' },
    { sel: ['.side'], panel: 'mission', place: 'right', title: 'Mission plan',
      text: 'The habitat, the stops and the return rule. Every change re-plans the whole EVA in about a second: route, timeline and suit.' },
    { sel: ['[aria-label="EVA summary"]'], place: 'below', title: 'GO or NO-GO',
      text: "Each plan is checked against the suit's oxygen, power and cooling water, the time to walk home, daylight, radiation and space weather. Hover over it for the reasons." },
    { sel: ['.right'], place: 'left', title: 'The EVA at a glance',
      text: 'The margins at every moment, the timeline and the caution and warning list, the way a flight controller would read them.' },
    { sel: ['.drawer'], place: 'above', title: 'Along the route',
      text: 'The elevation profile with hazard, radio, shade and terrain-confidence bands; the sun over the timeline; the suit consumables as they drain; and our A* route against Dijkstra.' },
    { sel: ['.side'], panel: 'layers', place: 'right', title: 'Every layer, and where it comes from',
      text: 'Imagery, terrain, heat, minerals and rover data, and the hazard, safety and science layers made from them. Each one carries a tag: MEASURED, MAPPED, DERIVED, MODELED or RULE.' },
    { sel: ['.side'], panel: 'breaks', place: 'right', title: 'When it breaks',
      text: 'No GPS (fix your position from the skyline), a dead visor, a suit leak, a crew member down: each one has a drill and its own map.' },
    { sel: ['.seg[aria-label="Mode"]'], place: 'below', title: 'Four ways to see it',
      text: 'TOWER lifts every data layer off the ground as a stack, 3D flies over the terrain, and WALK puts you in the helmet on the planned route.' },
    { sel: ['.rover-check', '.side'], panel: 'about', place: 'right', title: `Checked against ${rover}`,
      text: `${rover} only drove where its team judged the ground safe, so its track is ground known to be crossable. Here is how much of it our map calls walkable, with the sources and the limits of every model.` },
    { title: 'Your turn',
      text: 'Move a stop, switch on a layer, or press WALK. The desktop console adds the full helmet, the failure drills and the radar curtain in 3D.' },
  ]
}

const CARD_W = 340

function findTarget(sel) {
  for (const s of sel || []) {
    const el = document.querySelector(s)
    if (!el) continue
    const r = el.getBoundingClientRect()
    if (r.width > 4 && r.height > 4 && r.bottom > 0 && r.right > 0 && r.top < window.innerHeight && r.left < window.innerWidth) return el
  }
  return null
}

function cardStyle(rect, place) {
  const vw = window.innerWidth
  const vh = window.innerHeight
  const w = Math.min(CARD_W, vw - 24)
  if (!rect) return { left: (vw - w) / 2, top: Math.max(12, vh / 2 - 130), width: w }
  const gap = 14
  let x = rect.x + rect.w + gap
  let y = rect.y + 12
  let bottom = null
  if (place === 'left') x = rect.x - w - gap
  if (place === 'below') { x = rect.x + rect.w / 2 - w / 2; y = rect.y + rect.h + gap }
  if (place === 'above') { x = rect.x + rect.w / 2 - w / 2; bottom = vh - rect.y + gap }
  if (place === 'inside') { x = rect.x + rect.w - w - 16; y = rect.y + 16 }
  // no room on the chosen side: inside the target instead
  if ((place === 'right' && x + w > vw - 8) || (place === 'left' && x < 8)) { x = rect.x + 16; y = rect.y + 16 }
  x = Math.max(12, Math.min(x, vw - w - 12))
  if (bottom != null) return { left: x, bottom: Math.max(12, Math.min(bottom, vh - 160)), width: w }
  return { left: x, top: Math.max(12, Math.min(y, vh - 230)), width: w }
}

export default function GuidedTour() {
  const step = useStore((s) => s.tourStep)
  const site = useStore((s) => s.site)
  const set = useStore((s) => s.set)
  const [rect, setRect] = useState(null)
  const list = site ? tourSteps(site) : []
  const S = step != null ? list[step] : null

  const close = () => {
    try { localStorage.setItem(TOUR_SEEN_KEY, '1') } catch { /* private mode */ }
    set({ tourStep: null })
  }
  const go = (d) => {
    const n = (useStore.getState().tourStep ?? 0) + d   // the live step: two quick presses move two steps
    if (n >= list.length) close()
    else if (n >= 0) set({ tourStep: n })
  }

  // open the step's panel; tower and walk modes go back to the map
  useEffect(() => {
    if (!S) return
    const st = useStore.getState()
    const patch = {}
    if (st.mode !== 'plan') patch.mode = 'plan'
    if (S.panel && st.panel !== S.panel) patch.panel = S.panel
    if (Object.keys(patch).length) set(patch)
  }, [step]) // eslint-disable-line react-hooks/exhaustive-deps

  // follow the target while panels slide in and the window changes size
  useEffect(() => {
    if (!S) return undefined
    let last = ''
    let scrolled = false
    const poll = () => {
      const el = findTarget(S.sel)
      if (el && !scrolled && el.closest('.side-body')) { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); scrolled = true }
      const r = el?.getBoundingClientRect()
      const next = r ? { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) } : null
      const key = JSON.stringify(next)
      if (key !== last) { last = key; setRect(next) }
    }
    poll()
    const t = setInterval(poll, 120)
    window.addEventListener('resize', poll)
    return () => { clearInterval(t); window.removeEventListener('resize', poll) }
  }, [step]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (step == null) return undefined
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); close() }
      else if (e.key === 'ArrowRight' || e.key === 'Enter') { e.preventDefault(); go(1) }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); go(-1) }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }) // re-bound every render: go() and close() read the current step

  if (!S) return null
  const last = step === list.length - 1
  return (
    <div className="tour" role="dialog" aria-modal="true" aria-label={`Guided tour, step ${step + 1} of ${list.length}: ${S.title}`}>
      <div className="tour-block" />
      {rect
        ? <div className="tour-hole" style={{ left: rect.x - 4, top: rect.y - 4, width: rect.w + 8, height: rect.h + 8 }} />
        : <div className="tour-dim" />}
      <div className="tour-card" style={cardStyle(rect, S.place)}>
        <div className="tour-head">
          <span className="tour-count">{step + 1} / {list.length}</span>
          <button className="btn ghost icon" onClick={close} aria-label="Close the tour"><X size={15} /></button>
        </div>
        <h3>{S.title}</h3>
        <p>{S.text}</p>
        <div className="tour-dots" aria-hidden="true">
          {list.map((_, i) => <i key={i} className={i === step ? 'on' : i < step ? 'done' : ''} />)}
        </div>
        <div className="tour-actions">
          {step > 0 ? <button className="btn ghost" onClick={() => go(-1)}><ChevronLeft size={15} /> Back</button> : <button className="btn ghost" onClick={close}>Skip</button>}
          <button className="btn primary" onClick={() => go(1)} autoFocus>{last ? 'Start planning' : <>Next <ChevronRight size={15} /></>}</button>
        </div>
      </div>
    </div>
  )
}
