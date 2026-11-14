import React from 'react'
import { BookOpen, Camera, ClipboardList, Layers, LifeBuoy, Route, Satellite, SlidersHorizontal, Sparkles, Sun, X } from 'lucide-react'
import { useStore } from '../store.js'
import MissionPanel from './panels/MissionPanel.jsx'
import LayersPanel from './panels/LayersPanel.jsx'
import ConditionsPanel from './panels/ConditionsPanel.jsx'
import RoverPanel from './panels/RoverPanel.jsx'
import SuitPanel from './panels/SuitPanel.jsx'
import ChecklistPanel from './panels/ChecklistPanel.jsx'
import AboutPanel from './panels/AboutPanel.jsx'
import BreaksPanel from './panels/BreaksPanel.jsx'
import EarthPanel from './panels/EarthPanel.jsx'
import SmartPanel from './panels/SmartPanel.jsx'

export const PANELS = [
  { id: 'mission', label: 'Mission plan', sub: 'Habitat, stops and routing', icon: Route, C: MissionPanel },
  { id: 'layers', label: 'Map layers', sub: 'Imagery, hazards, radiation, rover data', icon: Layers, C: LayersPanel },
  { id: 'smart', label: 'Smart planner', sub: 'Plan it for me, scout first, crew tags, rocks', icon: Sparkles, C: SmartPanel },
  { id: 'breaks', label: 'When it breaks', sub: 'No GPS, dead visor, leaks, a crew member down', icon: LifeBuoy, C: BreaksPanel },
  { id: 'conditions', label: 'Conditions', sub: 'Sun, weather, radiation, space weather', icon: Sun, C: ConditionsPanel },
  { id: 'earth', label: 'Earth link', sub: 'Light time, CMEs, ask Earth, the live habitat console', icon: Satellite, C: EarthPanel },
  { id: 'rover', label: 'Rover view', sub: 'Ground-level photos near each stop', icon: Camera, C: RoverPanel },
  { id: 'suit', label: 'Suit & limits', sub: 'Walking model and consumables', icon: SlidersHorizontal, C: SuitPanel },
  { id: 'checklist', label: 'Cuff checklist', sub: 'Printable Apollo-style EVA card', icon: ClipboardList, C: ChecklistPanel },
  { id: 'about', label: 'Data & method', sub: 'Sources, assumptions, credits', icon: BookOpen, C: AboutPanel },
]

export default function LeftRail() {
  const panel = useStore((s) => s.panel)
  const set = useStore((s) => s.set)
  const P = PANELS.find((p) => p.id === panel)
  return (
    <>
      <nav className="rail" aria-label="Panels">
        {PANELS.map(({ id, label, icon: Icon }, i) => (
          <React.Fragment key={id}>
            {i === PANELS.length - 1 && <div className="spacer" />}
            <button className={panel === id ? 'on' : ''} onClick={() => set({ panel: panel === id ? null : id, ...(window.matchMedia('(max-width: 900px)').matches ? { summaryOpen: false } : {}) })} aria-label={label} aria-pressed={panel === id}>
              <Icon size={19} />
              <span className="tip">{label}</span>
            </button>
          </React.Fragment>
        ))}
      </nav>
      <aside className={`side ${P ? '' : 'closed'}`} aria-label={P?.label}>
        {P && (
          <>
            <div className="side-head">
              <div>
                <h2>{P.label}</h2>
                <p>{P.sub}</p>
              </div>
              <button className="btn ghost icon" onClick={() => set({ panel: null })} aria-label="Close panel"><X size={16} /></button>
            </div>
            <div className="side-body">
              <P.C />
            </div>
          </>
        )}
      </aside>
    </>
  )
}
