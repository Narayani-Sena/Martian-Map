import React from 'react'

// The 3D world and the helmet HUD live in the native Godot app (martian-map/godot).
// This tab just points there so the browser build stays light.
export default function Scene3D({ walk }) {
  return (
    <div className="splash" style={{ zIndex: 1 }}>
      <div className="inner">
        <div className="planet" />
        <div>{walk ? 'Helmet view' : '3D view'} runs in the Godot EVA Console</div>
        <div className="muted">Start it with <code>run_godot.ps1</code> in the project folder (it starts this API too if needed).</div>
      </div>
    </div>
  )
}
