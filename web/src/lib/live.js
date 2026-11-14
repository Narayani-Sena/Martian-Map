// Habitat and suit, live (feature D1): the console's end of the WebSocket relay, and a simulated helmet that
// walks the plan when no Godot helmet is connected (so the link can be shown with one laptop).
import { useStore } from '../store.js'
import { bearingDeg, interp } from './geo.js'

let sock = null
let sim = null

const setLive = (patch) => useStore.getState().set((s) => ({ live: { ...s.live, ...patch } }))

export function liveUrl(siteId) {
  const proto = window.location.protocol === 'https:' ? 'wss' : 'ws'
  return `${proto}://${window.location.host}/ws/live/${siteId}`
}

function handle(m) {
  const s = useStore.getState()
  if (m.type === 'welcome') setLive({ clients: m.status?.clients, last: m.last, history: m.history || [], lightTimeS: m.light_time_s })
  else if (m.type === 'presence') setLive({ clients: m.clients })
  else if (m.type === 'telemetry') {
    const hist = [...(s.live.history || []), m]
    if (hist.length > 2400) hist.splice(0, hist.length - 2400)
    setLive({ last: m, history: hist })
  } else if (m.type === 'waypoint' || m.type === 'clear_waypoint') setLive({ waypoint: m.type === 'waypoint' ? m : null })
  else if (m.type === 'message') setLive({ messages: [...(s.live.messages || []).slice(-6), m] })
}

export function connectConsole(siteId) {
  disconnectConsole()
  const ws = new WebSocket(liveUrl(siteId))
  sock = ws
  setLive({ connecting: true })
  ws.onopen = () => { ws.send(JSON.stringify({ type: 'hello', role: 'console' })); setLive({ connected: true, connecting: false }) }
  ws.onmessage = (ev) => { try { handle(JSON.parse(ev.data)) } catch { /* ignore a bad frame */ } }
  ws.onclose = () => { if (sock === ws) { sock = null; setLive({ connected: false, connecting: false }) } }
  ws.onerror = () => setLive({ connecting: false })
}

export function disconnectConsole() {
  if (sock) { const s0 = sock; sock = null; s0.close() }
  setLive({ connected: false })
}

export function sendCommand(cmd) {
  if (sock && sock.readyState === 1) { sock.send(JSON.stringify(cmd)); return true }
  return false
}

// ----------------------------------------------------------------------------- simulated helmet
export function startSimHelmet(siteId, speed = 20) {
  stopSimHelmet()
  const ws = new WebSocket(liveUrl(siteId))
  const st = { ws, t: 0, timer: null }
  sim = st
  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'hello', role: 'helmet' }))
    setLive({ simulating: true })
    st.timer = setInterval(() => {
      const plan = useStore.getState().plan
      if (!plan || ws.readyState !== 1) return
      const p = plan.profile
      const sm = plan.sim
      const total = plan.totals.total_s
      st.t = (st.t + 0.5 * speed) % total
      const t = st.t
      const lon = interp(p.t, p.lon, t)
      const lat = interp(p.t, p.lat, t)
      const lon2 = interp(p.t, p.lon, t + 20)
      const lat2 = interp(p.t, p.lat, t + 20)
      const moving = Math.abs(lon2 - lon) + Math.abs(lat2 - lat) > 1e-8
      const ev = plan.events.find((e) => t >= e.t0 && t < e.t1)
      const msg = {
        type: 'telemetry', source: 'simulated', lon, lat, eva_t: t, heading: moving ? bearingDeg({ lon, lat }, { lon: lon2, lat: lat2 }) : (st.heading ?? 0),
        o2_pct: interp(sm.t, sm.o2_pct, t), battery_pct: interp(sm.t, sm.battery_pct, t), co2_pct: interp(sm.t, sm.co2_pct, t),
        ppco2_mmhg: interp(sm.t, sm.ppco2_mmhg, t), met_w: interp(sm.t, sm.met_w, t), margin_min: interp(sm.t, sm.margin_min, t),
        walkback_min: interp(p.t, p.walkback_min.map((v) => v ?? 0), t), phase: ev ? ev.name : '', dose_usv: interp(sm.t, sm.dose_usv, t),
      }
      st.heading = msg.heading
      ws.send(JSON.stringify(msg))
    }, 500)
  }
  ws.onmessage = (ev) => {
    try {
      const m = JSON.parse(ev.data)
      if (m.type === 'waypoint') useStore.getState().notify(`Simulated visor: new waypoint "${m.name}" from the habitat`, 'ok')
      if (m.type === 'message') useStore.getState().notify(`Simulated visor: "${m.text}"`, 'info')
    } catch { /* ignore */ }
  }
  ws.onclose = () => { if (sim === st) { clearInterval(st.timer); sim = null; setLive({ simulating: false }) } }
}

export function stopSimHelmet() {
  if (sim) { clearInterval(sim.timer); const w = sim.ws; sim = null; w.close() }
  setLive({ simulating: false })
}

// Where Earth sees the crew: the newest sample at least one light-time (of EVA clock) older than the latest.
export function earthView(history, lightTimeS) {
  if (!history?.length || !lightTimeS) return null
  const last = history[history.length - 1]
  const target = (last.eva_t ?? 0) - lightTimeS
  for (let i = history.length - 1; i >= 0; i--) {
    const h = history[i]
    if (h.eva_t != null && h.eva_t <= target && h.eva_t <= last.eva_t) return h
  }
  return null
}
