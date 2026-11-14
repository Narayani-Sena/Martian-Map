export const fmtDist = (m) => (m == null || !isFinite(m) ? '—' : m >= 1000 ? `${(m / 1000).toFixed(2)} km` : `${Math.round(m)} m`)

export function fmtDur(s, { short = false } = {}) {
  if (s == null || !isFinite(s)) return '—'
  const neg = s < 0
  s = Math.abs(Math.round(s))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const out = h > 0 ? `${h} h ${String(m).padStart(2, '0')} min` : `${m} min`
  return (neg ? '−' : '') + (short ? out.replace(' min', 'm').replace(' h ', 'h ') : out)
}

export function fmtClock(s) {
  if (s == null || !isFinite(s)) return '—'
  const sign = s < 0 ? '−' : '+'
  s = Math.abs(Math.round(s))
  const p = (n) => String(n).padStart(2, '0')
  return `T${sign}${p(Math.floor(s / 3600))}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}`
}

export const fmtNum = (v, d = 0) => (v == null || !isFinite(v) ? '—' : Number(v).toLocaleString('en-US', { maximumFractionDigits: d, minimumFractionDigits: d }))

export function fmtUtc(iso, withDate = true) {
  if (!iso) return '—'
  const d = new Date(iso)
  const p = (n) => String(n).padStart(2, '0')
  const t = `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`
  return withDate ? `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${t} UTC` : `${t} UTC`
}

export const fmtLonLat = (lon, lat, d = 5) => `${Math.abs(lat).toFixed(d)}°${lat < 0 ? 'S' : 'N'}  ${Math.abs(lon).toFixed(d)}°${lon < 0 ? 'W' : 'E'}`

export function niceTicks(min, max, count = 5) {
  if (!isFinite(min) || !isFinite(max) || min === max) return [min]
  const span = max - min
  const step0 = span / count
  const mag = 10 ** Math.floor(Math.log10(step0))
  const err = step0 / mag
  const step = (err >= 7.5 ? 10 : err >= 3 ? 5 : err >= 1.5 ? 2 : 1) * mag
  const out = []
  for (let v = Math.ceil(min / step) * step; v <= max + step * 1e-9; v += step) out.push(+v.toFixed(10))
  return out
}

export const clamp = (v, a, b) => Math.max(a, Math.min(b, v))
