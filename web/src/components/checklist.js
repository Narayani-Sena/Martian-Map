// Builds the Apollo-style cuff checklist rows from a plan.
import { compass } from '../lib/geo.js'
import { fmtDist, fmtDur } from '../lib/format.js'
import { hms } from '../lib/mars24.js'

export function buildChecklist(plan, state) {
  if (!plan) return null
  const rows = []
  const legByIndex = plan.legs
  let legI = 0
  for (const e of plan.events) {
    const t = `T+${fmtDur(e.t0, { short: true })}`
    const ltst = hms(e.t0_ltst, false)
    const pr = plan.rover?.enabled
    if (e.kind === 'drive') {
      const out = e.leg === 'out'
      rows.push({ t, ltst, kind: 'drive', title: out ? 'DRIVE OUT · PR-2' : 'DRIVE HOME · PR-2',
        lines: out ? [`Board PR-2 at the hab · ${fmtDist(e.dist_m)} to the drop-off, ~${fmtDur(e.t1 - e.t0)}`, 'Suits on the suitports, topped up · crew in shirt-sleeves']
          : [`${fmtDist(e.dist_m)} back to the hab, ~${fmtDur(e.t1 - e.t0)}`, 'Dock at the hab · samples stay in the rover\'s sample lock'] })
    }
    if (e.kind === 'egress') rows.push({ t, ltst, kind: 'egress', title: pr ? 'SUITPORT EGRESS' : 'EGRESS', lines: ['Suit check: O₂, battery, CO₂, comms, HUD', pr ? 'Seal the suitport hatch · confirm radio through the PR-2 mast' : 'Depress airlock · confirm radio with hab', `Weather/space-weather status: ${state.sepActive ? 'STORM DRILL' : state.spaceWeather?.status || '—'}`] })
    if (e.kind === 'walk') {
      const L = legByIndex[legI++]
      rows.push({
        t, ltst, kind: 'walk', title: `NAV ${L.from.toUpperCase()} → ${L.to.toUpperCase()}`,
        lines: [`Heading ${Math.round(L.bearing_deg)}° ${compass(L.bearing_deg)} · ${fmtDist(L.dist_m)} · ~${fmtDur(L.time_s)}`, `Climb +${L.ascent_m} m / −${L.descent_m} m · steepest ${L.max_slope}°`],
      })
    }
    if (e.kind === 'stop') rows.push({ t, ltst, kind: 'stop', title: `STOP · ${e.name.toUpperCase()} (${fmtDur(e.t1 - e.t0)})`, lines: (e.tasks || []).filter(Boolean) })
    if (e.kind === 'ingress') rows.push({ t, ltst, kind: 'ingress', title: pr ? 'SUITPORT INGRESS' : 'INGRESS', lines: pr ? ['Dust-off, back into the suitports (the dust stays outside)', 'Stow samples in the sample lock', 'Debrief on the drive home'] : ['Dust-off, repress airlock', 'Stow samples in the clean cache', 'Debrief'] })
  }
  const tot = plan.totals
  const shelters = (state.site.shelters || []).map((s) => s.name)
  const pr = plan.rover?.enabled
  const ingress = [...plan.events].reverse().find((e) => e.kind === 'ingress') || plan.events[plan.events.length - 1]
  const rules = [
    `Planned ingress by ${hms(ingress.t1_ltst, false)} LTST · sunset ${tot.sunset_ltst ? hms(tot.sunset_ltst, false) : '—'}`,
    `TURN BACK at once if the HUD return margin reaches 0 (plan minimum ${Math.round(tot.min_margin_min)} min, ${tot.limiting})`,
    `No slopes above ${state.walk.max_slope}° · stay out of purple no-go ground`,
    `Farthest point is ${tot.max_walkback_min} min from ${pr ? 'PR-2 (parked at the drop-off)' : 'the hab'}`,
    pr ? 'Solar storm / SEP alert → into PR-2\'s water-wall shelter' : `Solar storm / SEP alert → go to the hab${shelters.length ? ` or ${shelters.join(', ')}` : ''}`,
    tot.comms_dead_fraction > 0 ? `Expect no radio line of sight on ${Math.round(tot.comms_dead_fraction * 100)} % of the route — report before and after` : 'Radio line of sight on the whole route',
  ]
  return { rows, rules, totals: tot }
}
