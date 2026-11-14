import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { bisect } from '../../lib/geo.js'
import { niceTicks } from '../../lib/format.js'

export function useSize(ref) {
  const [size, setSize] = useState({ w: 0, h: 0 })
  useLayoutEffect(() => {
    if (!ref.current) return
    const ro = new ResizeObserver(([e]) => {
      const r = e.contentRect
      setSize((s) => (Math.abs(s.w - r.width) > 0.5 || Math.abs(s.h - r.height) > 0.5 ? { w: r.width, h: r.height } : s))
    })
    ro.observe(ref.current)
    return () => ro.disconnect()
  }, [ref])
  return size
}

/**
 * Small, dependency-free SVG chart: lines (+ optional area wash), x-range bands,
 * vertical markers, horizontal thresholds, categorical strips under the plot,
 * crosshair + tooltip, and an externally synced hover position.
 */
export default function XYChart({
  x, series, xDomain, yDomain, yTicks: yTicksProp, xFmt = (v) => v, yFmt = (v) => v, yLabel,
  hoverX, onHover, markers = [], bands = [], thresholds = [], strips = [], tooltip, endLabels = false,
  margin = { l: 46, r: 14, t: 10, b: 22 }, minY,
}) {
  const ref = useRef(null)
  const { w, h } = useSize(ref)
  const [localHover, setLocalHover] = useState(null)
  const stripH = 9
  const stripGap = 4
  const stripsH = strips.length ? strips.length * (stripH + stripGap) + 4 : 0
  const pw = Math.max(10, w - margin.l - margin.r)
  const ph = Math.max(10, h - margin.t - margin.b - stripsH)

  const [x0, x1] = xDomain || [x[0], x[x.length - 1]]
  const yd = useMemo(() => {
    if (yDomain) return yDomain
    let lo = Infinity
    let hi = -Infinity
    for (const s of series) for (const v of s.values) if (v != null && isFinite(v)) { lo = Math.min(lo, v); hi = Math.max(hi, v) }
    if (minY != null) lo = Math.min(lo, minY)
    const pad = (hi - lo) * 0.08 || 1
    return [lo - pad, hi + pad]
  }, [series, yDomain, minY])
  const sx = (v) => margin.l + ((v - x0) / (x1 - x0 || 1)) * pw
  const sy = (v) => margin.t + ph - ((v - yd[0]) / (yd[1] - yd[0] || 1)) * ph
  const yTicks = yTicksProp || niceTicks(yd[0], yd[1], Math.max(2, Math.floor(ph / 34)))
  const xTicks = niceTicks(x0, x1, Math.max(2, Math.floor(pw / 90)))

  const paths = useMemo(() => series.map((s) => {
    let d = ''
    let pen = false
    for (let i = 0; i < x.length; i++) {
      const v = s.values[i]
      if (v == null || !isFinite(v)) { pen = false; continue }
      d += `${pen ? 'L' : 'M'}${sx(x[i]).toFixed(1)},${sy(v).toFixed(1)}`
      pen = true
    }
    let area = null
    if (s.area) {
      const base = sy(Math.max(yd[0], Math.min(yd[1], s.areaBase ?? yd[0])))
      area = `${d}L${sx(x[x.length - 1]).toFixed(1)},${base}L${sx(x[0]).toFixed(1)},${base}Z`
    }
    return { d, area }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [series, x, w, h, yd[0], yd[1], x0, x1])

  const hx = localHover ?? hoverX
  const hi = hx != null && x.length ? bisect(x, hx) : null

  const move = (e) => {
    const r = ref.current.getBoundingClientRect()
    const px = e.clientX - r.left
    if (px < margin.l || px > margin.l + pw) { leave(); return }
    const v = x0 + ((px - margin.l) / pw) * (x1 - x0)
    setLocalHover(v)
    onHover?.(v)
  }
  const leave = () => { setLocalHover(null); onHover?.(null) }

  const tip = hi != null && tooltip && localHover != null ? tooltip(hi) : null
  const tipX = hi != null ? sx(x[hi]) : 0
  const tipLeft = tipX + 14 + 180 > w ? tipX - 194 : tipX + 14

  return (
    <div className="chart" ref={ref} onPointerMove={move} onPointerLeave={leave}>
      {w > 0 && (
        <svg width={w} height={h} role="img" aria-label={yLabel}>
          {/* x-range bands (e.g. time at stops, night) */}
          {bands.map((b, i) => (
            <rect key={i} x={sx(Math.max(x0, b.x0))} y={margin.t} width={Math.max(0, sx(Math.min(x1, b.x1)) - sx(Math.max(x0, b.x0)))} height={ph} fill={b.color} />
          ))}
          <g className="grid">
            {yTicks.map((t) => <line key={t} x1={margin.l} x2={margin.l + pw} y1={sy(t)} y2={sy(t)} />)}
          </g>
          <g className="tick">
            {yTicks.map((t) => <text key={t} x={margin.l - 6} y={sy(t) + 3.5} textAnchor="end">{yFmt(t)}</text>)}
            {xTicks.map((t) => <text key={t} x={sx(t)} y={h - 6} textAnchor="middle">{xFmt(t)}</text>)}
          </g>
          <line className="axis" x1={margin.l} x2={margin.l + pw} y1={margin.t + ph} y2={margin.t + ph} stroke="var(--axis)" />
          {thresholds.map((t, i) => (
            <g key={i}>
              <line x1={margin.l} x2={margin.l + pw} y1={sy(t.y)} y2={sy(t.y)} stroke={t.color} strokeWidth="1.5" strokeDasharray={t.dashed ? '5 4' : undefined} />
              {t.label && <text x={margin.l + pw - 4} y={sy(t.y) - 5} textAnchor="end" style={{ fill: 'var(--text-2)' }}>{t.label}</text>}
            </g>
          ))}
          {series.map((s, i) => (
            <g key={s.id}>
              {paths[i].area && <path d={paths[i].area} fill={s.color} opacity={s.areaOpacity ?? 0.12} />}
              <path d={paths[i].d} fill="none" stroke={s.color} strokeWidth={s.width || 2} strokeLinejoin="round" strokeLinecap="round" />
            </g>
          ))}
          {endLabels && series.map((s) => {
            let k = s.values.length - 1
            while (k > 0 && (s.values[k] == null || !isFinite(s.values[k]))) k--
            return (
              <g key={`e${s.id}`}>
                <circle cx={sx(x[k])} cy={sy(s.values[k])} r="4" fill={s.color} stroke="var(--panel)" strokeWidth="2" />
              </g>
            )
          })}
          {markers.map((m, i) => (
            <g key={i}>
              <line x1={sx(m.x)} x2={sx(m.x)} y1={margin.t} y2={margin.t + ph} stroke={m.color || 'rgba(255,255,255,0.28)'} strokeWidth="1" />
              {m.label && (
                <g transform={`translate(${sx(m.x)},${margin.t + 1})`}>
                  <rect x={-9} y={0} width={18} height={15} rx={4} fill={m.fill || 'var(--accent)'} />
                  <text x={0} y={11} textAnchor="middle" style={{ fill: m.ink || '#1d0c03', fontWeight: 800, fontSize: 10 }}>{m.label}</text>
                </g>
              )}
            </g>
          ))}
          {strips.map((st, si) => {
            const y = margin.t + ph + 6 + si * (stripH + stripGap)
            const rects = []
            let start = 0
            for (let i = 1; i <= x.length; i++) {
              if (i === x.length || st.values[i] !== st.values[start]) {
                const c = st.colors[st.values[start]]
                if (c && c !== 'transparent') rects.push(<rect key={i} x={sx(x[start])} y={y} width={Math.max(1, sx(x[Math.min(i, x.length - 1)]) - sx(x[start]))} height={stripH} fill={c} />)
                start = i
              }
            }
            return (
              <g key={si}>
                <rect x={margin.l} y={y} width={pw} height={stripH} fill="#151d28" rx="2" />
                {rects}
                <text x={margin.l - 6} y={y + 8} textAnchor="end" style={{ fontSize: 9.5 }}>{st.label}</text>
              </g>
            )
          })}
          {hi != null && (
            <g pointerEvents="none">
              <line className="xhair" x1={sx(x[hi])} x2={sx(x[hi])} y1={margin.t} y2={margin.t + ph + stripsH} />
              {series.map((s) => s.values[hi] != null && isFinite(s.values[hi]) && (
                <circle key={s.id} cx={sx(x[hi])} cy={sy(s.values[hi])} r="4.5" fill={s.color} stroke="var(--panel)" strokeWidth="2" />
              ))}
            </g>
          )}
        </svg>
      )}
      {tip && (
        <div className="tooltip" style={{ left: tipLeft, top: 8 }}>
          {tip.head && <div className="t-head">{tip.head}</div>}
          {tip.rows.map((r, i) => (
            <div className="t-row" key={i}>
              <i className="key" style={{ background: r.color || 'transparent' }} />
              <span>{r.label}</span>
              <b>{r.value}</b>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

export function Legend({ items }) {
  return (
    <div className="chart-legend">
      {items.map((it) => (
        <span key={it.label}>
          {it.swatch ? <i className="sw" style={{ background: it.color }} /> : <i className="key" style={{ background: it.color }} />}
          {it.label}
        </span>
      ))}
    </div>
  )
}

export function useDebounced(value, ms = 60) {
  const [v, setV] = useState(value)
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms)
    return () => clearTimeout(t)
  }, [value, ms])
  return v
}
