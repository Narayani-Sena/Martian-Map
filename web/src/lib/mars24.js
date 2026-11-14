// Mars24 sun clock (Allison & McEwen 2000) - JavaScript twin of marsgeo/mars24.py.
// East-positive longitudes; hour angle positive in the afternoon; azimuth clockwise from north.

const TT_MINUS_UTC = 69.184
export const SOL_DAYS = 1.0274912517
export const SOL_MS = SOL_DAYS * 86400000

const PBS = [
  [0.0071, 2.2353, 49.409], [0.0057, 2.7543, 168.173], [0.0039, 1.1177, 191.837], [0.0037, 15.7866, 21.736],
  [0.0021, 2.1354, 15.704], [0.002, 2.4694, 95.528], [0.0018, 32.8493, 49.095],
]
const rad = (d) => (d * Math.PI) / 180
const deg = (r) => (r * 180) / Math.PI
const mod = (a, n) => ((a % n) + n) % n

export function marsTime(date) {
  const ms = date instanceof Date ? date.getTime() : date
  const jdUT = 2440587.5 + ms / 86400000
  const jdTT = jdUT + TT_MINUS_UTC / 86400
  const d = jdTT - 2451545.0
  const M = mod(19.3871 + 0.52402073 * d, 360)
  const aFMS = mod(270.3871 + 0.524038496 * d, 360)
  let pbs = 0
  for (const [A, tau, phi] of PBS) pbs += A * Math.cos(rad((0.985626 * d) / tau + phi))
  const Mr = rad(M)
  const nuM = (10.691 + 3e-7 * d) * Math.sin(Mr) + 0.623 * Math.sin(2 * Mr) + 0.05 * Math.sin(3 * Mr) +
    0.005 * Math.sin(4 * Mr) + 0.0005 * Math.sin(5 * Mr) + pbs
  const ls = mod(aFMS + nuM, 360)
  const lsr = rad(ls)
  const eot = 2.861 * Math.sin(2 * lsr) - 0.071 * Math.sin(4 * lsr) + 0.002 * Math.sin(6 * lsr) - nuM
  const msd = (jdTT - 2451549.5) / SOL_DAYS + 44796.0 - 0.0009626
  const mtc = mod(24 * msd, 24)
  const decl = deg(Math.asin(0.42565 * Math.sin(lsr))) + 0.25 * Math.sin(lsr)
  const helio = 1.5236 * (1.00436 - 0.09309 * Math.cos(Mr) - 0.004336 * Math.cos(2 * Mr) - 0.00031 * Math.cos(3 * Mr) - 0.00003 * Math.cos(4 * Mr))
  const year = Math.floor((jdTT - 2435208.5) / 686.9725 + 1)
  let my = year
  const frac = mod((jdTT - 2435208.5) / 686.9725, 1)
  if (ls > 300 && frac < 0.1) my -= 1
  if (ls < 60 && frac > 0.9) my += 1
  return { jdUT, jdTT, msd, mtc, ls, eot, decl, helio, M, marsYear: my }
}

export const lmst = (mt, lon) => mod(mt.mtc + lon / 15, 24)
export const ltst = (mt, lon) => mod(mt.mtc + lon / 15 + mt.eot / 15, 24)

export function sunPosition(mt, lat, lon) {
  const h = rad((ltst(mt, lon) - 12) * 15)
  const phi = rad(lat)
  const dec = rad(mt.decl)
  const sinAlt = Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(h)
  const alt = deg(Math.asin(Math.max(-1, Math.min(1, sinAlt))))
  const az = deg(Math.atan2(-Math.cos(dec) * Math.sin(h), Math.sin(dec) * Math.cos(phi) - Math.cos(dec) * Math.sin(phi) * Math.cos(h)))
  return { elevation: alt, azimuth: mod(az, 360) }
}

export function sunriseSunset(mt, lat, horizon = -0.25) {
  const phi = rad(lat)
  const dec = rad(mt.decl)
  const c = (Math.sin(rad(horizon)) - Math.sin(phi) * Math.sin(dec)) / (Math.cos(phi) * Math.cos(dec))
  if (c <= -1 || c >= 1) return null
  const h0 = deg(Math.acos(c)) / 15
  return [12 - h0, 12 + h0]
}

export function utcForLtst(date, lon, target) {
  let t = date instanceof Date ? date.getTime() : date
  for (let i = 0; i < 6; i++) {
    const cur = ltst(marsTime(t), lon)
    const diff = mod(target - cur + 12, 24) - 12
    if (Math.abs(diff) < 1e-5) break
    t += diff * 3600000 * SOL_DAYS
  }
  return new Date(t)
}

export const missionSol = (mt, lon, landing) => Math.floor(mt.msd + lon / 360) - landing

export function seasonName(ls, lat) {
  const north = ['spring', 'summer', 'autumn', 'winter']
  const south = ['autumn', 'winter', 'spring', 'summer']
  return (lat >= 0 ? north : south)[Math.floor(ls / 90) % 4]
}

export function hms(hours, withSeconds = true) {
  let s = Math.round(mod(hours, 24) * 3600)
  const h = Math.floor(s / 3600)
  s -= h * 3600
  const m = Math.floor(s / 60)
  s -= m * 60
  const p = (n) => String(n).padStart(2, '0')
  return withSeconds ? `${p(h % 24)}:${p(m)}:${p(s)}` : `${p(h % 24)}:${p(m)}`
}
