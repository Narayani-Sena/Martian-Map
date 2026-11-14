# NASA standards in Martian Map

The EVA console is designed against NASA's human-system standard **NASA-STD-3001 Volume 2**:
[chapter 10, Crew Interfaces](https://www.nasa.gov/reference/10-0-crew-interfaces-vol-2/) and
[chapter 11, Spacesuits](https://www.nasa.gov/reference/11-0-spacesuits-vol-2/). Requirement numbers are written
as [V2 nnnnn]. Each item below has an automatic check in the Godot console's `nasa` tour
(`--tour=nasa`, items N1-N25), and the server parts are covered by the pytest suite.

## Data the challenge brief lists

| # | Item | What the app does |
|---|---|---|
| N1 | USGS geologic map layer | Unit polygons from the USGS-NASA Planetary Geologic Mapping Program's own map services (Jezero: SIM 3464, Sun & Stack 2020, 1:75,000; Gale: SIM 3292, Tanaka et al. 2014), drawn on the site grid with the official colours. Inspect shows each unit's code, name, interpretation and citation. Jezero has 6 units on the site. |
| N2 | NASA Mars Trek data | THEMIS day IR read through Mars Trek's tile service, next to the night IR, and an "open in Mars Trek" link for any inspected point. |
| N3 | Labelled legends | Hazard, walk-back, radio and geology legends drawn as labelled swatches, not only colour ramps. |

## Caution and warning [V2 10114-10117, 10154-10156, 10175-10178, 10056-10058]

| # | Item | What the app does |
|---|---|---|
| N4 | Four alert classes | Emergency (flashing red), warning (red), caution (yellow), advisory (blue), prioritised highest first. |
| N5 | Latched alerts | An alert stays on screen and keeps sounding until acknowledged; a cleared condition stays listed until acknowledged; master-alarm light in the top bar and the HUD. |
| N6 | Silence, acknowledge, shelve, inhibit | Silence stops the sound only; acknowledge clears the annunciation; shelved alerts are still logged; inhibited ones are reported every 5 minutes. |
| N7 | NASA tones (Table 10.3-1) | Emergency, warning, caution and advisory tones synthesised to the table, on their own audio bus with a volume floor; the first burst is 10 dB lower; muting the interface never silences alarms. |
| N8 | Spoken alerts, log, alarm test | Warnings are spoken after their tone, every event is logged (and can be saved as CSV), and TEST ALARMS runs each class. |

## Suit data [V2 11010, 11023, 11035, 11036, 11038, 11040]

| # | Item | What the app does |
|---|---|---|
| N9 | Suit pressure, ppO₂, ppCO₂ | Modelled in the server's EVA simulation and in the console's suit model, shown with units and limits. GO/NO-GO flags inspired CO₂ over 15 mmHg and fails it over NASA's 20 mmHg contingency limit. Drills: suit leak, CO₂ breakthrough. |
| N10 | Monitored parameters | 28 monitored conditions: oxygen, battery, feedwater, CO₂ scrubber, heart rate, metabolic rate, dose rate and EVA dose, sunset, partner separation, off-route, server link, terrain, plan and more. |

## Information [V2 10020, 10045, 10066, 10080, 10113, 10153, 10162, 10178]

| # | Item | What the app does |
|---|---|---|
| N11 | Stale and missing data | One STALE style for old feeds; loss of signal counted in a radio shadow; a server outage raises a caution. |
| N12 | Colour is never the only cue | Words on every out-of-limit value (OK / LOW / CRIT, STEEP ▲▼), labelled legends, hatched and dotted bands on the elevation profile. |
| N13 | Mode annunciator | MANUAL / AUTOPILOT / RIDING / DEMO always shown, with an advisory on every change. |
| N14 | Turn-back time | "TURN BACK IN 38 min · BY 14:32 LTST" instead of mental arithmetic, and TURN BACK NOW at zero margin. |
| N15 | Response time and confirmation | Re-plan progress shown within 1 s (Table 10.2-1); confirmation before defaults, site switch and ABORT. |
| — | Uncertainty shown [V2 10161] | The return margin as a range under planning dispersions (metabolic rate ±20 %, walking speed ±12 %), sand-model agreement and agreement between two independent terrain models, on the map, in Inspect and along the route. |

## Settings, accessibility and controls

| # | Item | What the app does |
|---|---|---|
| N16 | Tabbed settings | Graphics, Display, HUD, Alerts, Controls, Sound, Data, each with a note citing the NASA rule behind it. |
| N17 | Performance | Render scale, frame cap, v-sync, FPS readout. |
| N18 | Accessibility | Colour-vision-safe palette (Okabe-Ito), minimum text size including a NASA 12 pt option, reduce flashing, kPa or psi. |
| N19 | HUD | Declutter level, brightness, tint. |
| N20 | Data | Export and import a mission file. |
| N21 | Rebinding | Every key and gamepad button, with a clash check and reset. |
| N22 | Feel options | Stick dead zone, orbit invert, zoom and pan speed, hold-or-toggle options. |
| N23 | ABORT EVA | Hold End (or R3, the HUD button, or a voice command): guidance straight back to the nearest safe haven along the walk-back route, working even with the interface hidden. |
| N24 | Glove mode and cuff menu | Large targets for suited hands, and every crew action reachable from a d-pad or number-key menu without a mouse. |
| N25 | Voice commands | "Suit ..." phrases through Windows' offline speech recogniser, with a self-test from synthesised speech. |

## How it was checked

* `--tour=nasa`: 25 of 25 checks pass, plus the older tours (fixes, camera, walk, gamepad, polish, settings) for
  regressions.
* A benchmark against the code before this work (A-B-B-A order, Intel UHD 620, low preset) showed no measurable
  frame-time cost.
* `pytest -q` for the server: suit gas model, plan checks, space-weather windows and the rest of the suite.
