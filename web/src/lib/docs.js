import { missionBody, useStore } from '../store.js'

// Open a printable page the API renders from the current mission (traverse sheet, fallback card, debrief ...).
// A new tab when pop-ups are allowed, else the page is downloaded as a file.
export async function openPlanDoc(path, filename, label, extra = {}) {
  const state = useStore.getState()
  if (!state.site) return
  const win = window.open('', '_blank')
  try {
    const r = await fetch(`/api/sites/${state.site.id}/${path}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...missionBody(state), ...extra }),
    })
    if (!r.ok) {
      let msg = `HTTP ${r.status}`
      try { const b = await r.json(); if (b.detail) msg = typeof b.detail === 'string' ? b.detail : JSON.stringify(b.detail) } catch { /* not JSON */ }
      throw new Error(msg)
    }
    const html = await r.text()
    if (win) { win.document.open(); win.document.write(html); win.document.close(); return }
    const a = document.createElement('a')
    a.href = URL.createObjectURL(new Blob([html], { type: 'text/html' }))
    a.download = `${filename}_${state.site.id}.html`
    a.click()
    setTimeout(() => URL.revokeObjectURL(a.href), 5000)
    state.notify(`Pop-up blocked: the ${label} was downloaded instead.`, 'info')
  } catch (e) {
    if (win) win.close()
    state.notify(`${label[0].toUpperCase()}${label.slice(1)} failed: ${e.message}`, 'error')
  }
}

// Download a file the API renders from the current mission (STL, GLB, SVG ...).
export async function downloadPlanFile(path, filename, label, extra = {}) {
  const state = useStore.getState()
  try {
    const r = await fetch(`/api/sites/${state.site.id}/${path}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...missionBody(state), ...extra }),
    })
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    const blob = await r.blob()
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = filename
    a.click()
    setTimeout(() => URL.revokeObjectURL(a.href), 5000)
    state.notify(`${label} saved (${(blob.size / 1024 / 1024).toFixed(1)} MB)`, 'ok')
  } catch (e) {
    state.notify(`${label} failed: ${e.message}`, 'error')
  }
}
