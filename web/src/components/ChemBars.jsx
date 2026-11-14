// Rover chemistry at a target (feature E2): the oxide weight percents as small bars. Each bar is drawn against that
// oxide's usual range in Mars rocks (SiO2 to 80 %, K2O to 8 %), so minor oxides still show; the number is the value.

export const CHEM_ORDER = ['SiO2', 'FeOT', 'MgO', 'CaO', 'Al2O3', 'Na2O', 'K2O', 'TiO2', 'MnO']
const RANGE = { SiO2: 80, FeOT: 40, MgO: 30, CaO: 40, Al2O3: 25, Na2O: 8, K2O: 8, TiO2: 4, MnO: 4 }
const LABEL = { SiO2: 'SiO₂', FeOT: 'FeOᴛ', MgO: 'MgO', CaO: 'CaO', Al2O3: 'Al₂O₃', Na2O: 'Na₂O', K2O: 'K₂O', TiO2: 'TiO₂', MnO: 'MnO' }
const KEY = { 'calcium-rich (sulfate veins?)': 'CaO', 'silica-rich': 'SiO2', 'iron-rich': 'FeOT', 'magnesium-rich': 'MgO', 'manganese-rich': 'MnO' }

const bar = (k, v, hot, color) => {
  const w = Math.max(1, Math.min(100, (v / RANGE[k]) * 100))
  return { k, label: LABEL[k], v, w, color: hot ? color : 'var(--accent, #4fd1ff)' }
}

export function chemRows(t) {
  const hot = KEY[t.hint]
  return CHEM_ORDER.filter((k) => t.oxides?.[k] != null).map((k) => bar(k, t.oxides[k], k === hot, t.color))
}

// For Leaflet tooltips (plain HTML)
export function chemBarsHtml(t) {
  const rows = chemRows(t).map((r) => `<span>${r.label}</span><i style="width:${r.w}%;background:${r.color}"></i><em>${r.v.toFixed(1)}</em>`).join('')
  return `<div class="chem-bars">${rows}</div>`
}

export default function ChemBars({ t }) {
  return (
    <div className="chem-bars">
      {chemRows(t).map((r) => (
        <span key={r.k} style={{ display: 'contents' }}>
          <span>{r.label}</span>
          <i style={{ width: `${r.w}%`, background: r.color }} />
          <em>{r.v.toFixed(1)}</em>
        </span>
      ))}
    </div>
  )
}
