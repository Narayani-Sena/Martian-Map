// The shrinking world (feature A3): the server sends, for every 4 m cell, the minutes of oxygen a walk there and
// home needs. Here that field is thresholded against the oxygen left, on a canvas stretched over the site, so the
// boundary can tighten smoothly as the oxygen drops (no round trip per frame).
import L from 'leaflet'

export const CanvasOverlay = L.ImageOverlay.extend({
  // `url` is a <canvas>: Leaflet places and scales it like an image
  _initImage() {
    const c = (this._image = this._url)
    L.DomUtil.addClass(c, 'leaflet-image-layer')
    if (this._zoomAnimated) L.DomUtil.addClass(c, 'leaflet-zoom-animated')
    if (this.options.className) L.DomUtil.addClass(c, this.options.className)
    c.onselectstart = L.Util.falseFn
    c.onmousemove = L.Util.falseFn
    c.style.imageRendering = 'pixelated'
    if (this.options.zIndex != null) this._updateZIndex()
  },
})

// minutes x 10 in R (high byte) and G (low byte); alpha 0 = impossible
export async function decodeMinutes(dataUrl) {
  const img = new Image()
  img.src = dataUrl
  await img.decode()
  const c = document.createElement('canvas')
  c.width = img.width
  c.height = img.height
  const ctx = c.getContext('2d', { willReadFrequently: true })
  ctx.drawImage(img, 0, 0)
  const px = ctx.getImageData(0, 0, c.width, c.height).data
  const n = c.width * c.height
  const m = new Float32Array(n)
  for (let i = 0; i < n; i++) m[i] = px[i * 4 + 3] ? (px[i * 4] * 256 + px[i * 4 + 1]) / 10 : Infinity
  return { m, w: c.width, h: c.height }
}

// Paint the envelope for `minutes` of oxygen into `canvas`; returns the number of cells in reach.
export function paintEnvelope(canvas, field, minutes) {
  const { m, w, h } = field
  if (canvas.width !== w) canvas.width = w
  if (canvas.height !== h) canvas.height = h
  const ctx = canvas.getContext('2d')
  const img = ctx.createImageData(w, h)
  const d = img.data
  let n = 0
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x
      const v = m[i]
      const k = i * 4
      if (v === Infinity) { d[k] = 70; d[k + 1] = 0; d[k + 2] = 12; d[k + 3] = 120; continue }
      if (v > minutes) { d[k] = 12; d[k + 1] = 6; d[k + 2] = 18; d[k + 3] = 170; continue }
      n++
      // inside: clear, with a bright rim where a neighbour is outside
      const edge = (x > 0 && m[i - 1] > minutes) || (x < w - 1 && m[i + 1] > minutes) || (y > 0 && m[i - w] > minutes) || (y < h - 1 && m[i + w] > minutes)
      if (edge) { d[k] = 255; d[k + 1] = 236; d[k + 2] = 190; d[k + 3] = 255 } else {
        // the last few minutes of margin glow amber, so the next ring to go is visible
        const slack = minutes - v
        if (slack < 8) { d[k] = 255; d[k + 1] = 170; d[k + 2] = 60; d[k + 3] = Math.round(90 * (1 - slack / 8)) } else d[k + 3] = 0
      }
    }
  }
  ctx.putImageData(img, 0, 0)
  return n
}
