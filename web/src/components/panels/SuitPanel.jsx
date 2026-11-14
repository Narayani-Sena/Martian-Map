import React from 'react'
import { RotateCcw } from 'lucide-react'
import { useStore } from '../../store.js'

function Slider({ label, unit, value, min, max, step, onChange, hint, fmt }) {
  return (
    <label className="field">
      <span>{label} <b>{fmt ? fmt(value) : value}{unit ? ` ${unit}` : ''}</b></span>
      <input type="range" min={min} max={max} step={step} value={value} onChange={(e) => onChange(+e.target.value)} />
      {hint && <p className="hint">{hint}</p>}
    </label>
  )
}

export default function SuitPanel() {
  const walk = useStore((s) => s.walk)
  const suit = useStore((s) => s.suit)
  const site = useStore((s) => s.site)
  const set = useStore((s) => s.set)
  const w = (k) => (v) => set({ walk: { ...walk, [k]: v } })
  const u = (k) => (v) => set({ suit: { ...suit, [k]: v } })
  return (
    <>
      <div className="section">
        <h3>Walking model <button className="btn ghost sm" onClick={() => set({ walk: { ...site.defaults.walk } })}><RotateCcw size={12} /> Defaults</button></h3>
        <Slider label="Flat-ground speed" unit="m/s" value={walk.flat_speed} min={0.4} max={1.4} step={0.05} onChange={w('flat_speed')}
          fmt={(v) => `${v.toFixed(2)}`} hint={`${(walk.flat_speed * 3.6).toFixed(1)} km/h. Speed on slopes follows Tobler's hiking function (fastest on a gentle 5 % descent).`} />
        <Slider label="Maximum slope" unit="°" value={walk.max_slope} min={10} max={35} step={1} onChange={w('max_slope')} hint="Steeper ground is treated as no-go." />
        <Slider label="Caution from" unit="°" value={walk.caution_slope} min={5} max={Math.max(6, walk.max_slope - 1)} step={1} onChange={w('caution_slope')} hint="Above this, routes pay a growing safety penalty." />
        <Slider label="Maximum roughness" unit="m" value={walk.max_rough} min={0.2} max={1} step={0.05} onChange={w('max_rough')} fmt={(v) => v.toFixed(2)} />
        <Slider label="Loose-sand penalty" value={walk.sand_penalty} min={0} max={2} step={0.1} onChange={w('sand_penalty')} fmt={(v) => `+${Math.round(v * 100)} %`} />
        <Slider label="Carried equipment" unit="kg" value={walk.load_kg ?? 8} min={0} max={40} step={1} onChange={w('load_kg')}
          hint={`Tools, sample bags and instruments. Each kg slows the walk by 0.4 % and adds to the metabolic cost (now ${Math.round((walk.flat_speed / (1 + 0.004 * (walk.load_kg ?? 8))) * 100) / 100} m/s on the flat).`} />
        <Slider label="Hazard aversion" value={walk.hazard_aversion} min={0} max={3} step={0.1} onChange={w('hazard_aversion')} fmt={(v) => v.toFixed(1)}
          hint="0 = fastest route; higher keeps more distance from steep and blocky ground." />
      </div>
      <div className="section">
        <h3>Suit consumables <button className="btn ghost sm" onClick={() => set({ suit: { ...site.defaults.suit } })}><RotateCcw size={12} /> Defaults</button></h3>
        <Slider label="Primary O₂" unit="kg" value={suit.o2_kg} min={0.3} max={1.2} step={0.02} onChange={u('o2_kg')} fmt={(v) => v.toFixed(2)}
          hint="Use ≈ 0.26 g per watt-hour of metabolic work (20.1 kJ per litre of O₂) + leakage." />
        <Slider label="Battery" unit="Wh" value={suit.battery_wh} min={400} max={2000} step={50} onChange={u('battery_wh')} hint="Fans, pump, radio and HUD, plus heaters when the air is below −45 °C." />
        <Slider label="CO₂ scrubber" unit="g" value={suit.co2_capacity_g} min={300} max={1200} step={20} onChange={u('co2_capacity_g')} />
        <Slider label="Cooling water" unit="kg" value={suit.water_kg} min={1} max={6} step={0.1} onChange={u('water_kg')} fmt={(v) => v.toFixed(1)} />
      </div>
      <div className="section">
        <h3>Safety rules</h3>
        <Slider label="Fixed reserve" unit="min" value={suit.reserve_min} min={0} max={90} step={5} onChange={u('reserve_min')} />
        <Slider label="Tired-return factor" value={suit.return_factor} min={1} max={2} step={0.05} onChange={u('return_factor')} fmt={(v) => `×${v.toFixed(2)}`}
          hint="At every moment the suit must hold enough to walk back × this factor + the fixed reserve." />
        <Slider label="Airlock time (each way)" unit="min" value={suit.airlock_min} min={5} max={40} step={5} onChange={u('airlock_min')} />
      </div>
    </>
  )
}
