# Martian Map · EVA Navigator

**A map an astronaut can walk with.** Plan a Marswalk on real NASA terrain, see where the ground is safe, which
science is worth the walk, and how long you have before you must turn back.

NASA Space Apps Challenge 2026 · Challenge:
[*Interplanetary Survival Guide: Martian Map*](https://www.spaceappschallenge.org/2026/challenges/interplanetary-survival-guide-martian-map/)
· Team **Narayani Sena**

| Habitat console: planning the walk | Helmet HUD: walking the plan |
|---|---|
| ![Orbit view](godot/docs/orbit_planning.jpg) | ![Helmet HUD](godot/docs/helmet_hud_alert.jpg) |

## Summary

NASA's global tools, such as Mars Trek and the USGS-NASA geologic maps, show Mars region by region. A crew on a
Marswalk needs the opposite: one small patch of ground, metre by metre, with every source that matters for that
walk on one screen.

Martian Map is that map. You pick a site, a habitat and some science stops. The planner routes the walk over the
real 1 m HiRISE terrain while avoiding steep, rough and sandy ground and boulders. It simulates the suit's oxygen,
battery, CO₂ scrubber and cooling water minute by minute. It checks the sun, the weather, space weather, radiation
and radio coverage, then gives a **GO or NO-GO with the reasons**. The same plan then goes out with the crew: on the
habitat console, in the helmet HUD and on a printed cuff checklist.

## How it answers the brief

| The challenge asks for | Martian Map |
|---|---|
| A map, tool or interface a Mars astronaut could use on a surface mission | A web planner for the habitat (desktop or tablet), a native 3D console with a first-person helmet HUD, and an Apollo-style printable traverse sheet and cuff checklist |
| A science goal and a place to explore | Two real sites: the boxwork ridges of Mount Sharp in Gale crater, which Curiosity studied in 2025, and Perseverance's Three Forks sample depot in Jezero crater |
| Data from several NASA science missions, layered together | MRO (HiRISE, CTX, CRISM), Mars Odyssey (THEMIS), Curiosity, Perseverance, Ingenuity, NASA DONKI space weather, USGS geologic maps and ESA's HRSC terrain, in more than 20 map layers |
| At least three kinds of data | Topographic, optical, thermal (night and day), spectral (minerals), geologic, atmospheric, radiation and space weather |
| Astronaut safety first | Walk-back time from every point, consumable margins, caution and warning built to NASA-STD-3001, radio coverage, terrain shadow and sunset, CME arrival windows, and tools for when something fails |
| Spacesuit mobility and carried equipment | Walking speed from Tobler's hiking function, scaled for a suited astronaut; speed and metabolic rate depend on the load carried |
| A route that avoids obstacles such as large rocks | Our own boulder detector on 25 cm HiRISE images finds about 4,400 boulders at Gale and 11,500 on Jezero's floor; boulders of 2 m or more are no-go, smaller ones cost time |
| Space weather and radiation | NASA DONKI's predicted CME arrivals at Mars are checked against the time in suits; Curiosity RAD dose rates; terrain shielding; a solar-storm drill |
| Point-of-view imagery | Curiosity, Perseverance and Ingenuity photos at the places they were taken, and a first-person walk over the real terrain |
| Rovers and astronauts working in pairs | A pressurized rover (PR-2) as transport, safe haven and radio relay, and a two-person EVA with partner-down rescue times |

## What it does

### Plan the walk

* **Route planning** on a 2 m cost grid with directional A* (written for this project) and Dijkstra. The cost combines
  slope, metre-scale roughness, the chance of loose sand, and boulders.
* **Our own sand model.** THEMIS night IR (loose sand cools fast), HiRISE darkness and the USGS dune unit decide how
  much of each ~100 m patch is sand. Against Jezero's mapped bedforms it scores an AUC of 0.84 without using the map;
  a hand-tuned score reached 0.71.
* **Suit simulation**, minute by minute: oxygen, battery, CO₂ scrubber, cooling water, suit pressure, ppO₂ and
  inspired CO₂, for the planned walk and for the walk home from every point of it.
* **Science stop suggestions** from CRISM mineral signals, boundaries between geologic units, ridge crests and
  hollows, and rover sample sites. Each one says why it is there, for example "Clay ridge A: CRISM clays, ridge
  crest 1.0 m above its surroundings".
* **Rover-assisted EVA.** PR-2 drives the crew to a drop-off within its own limits (slopes up to 20°, around
  boulders of 1 m or more). On Gale this halves the walking (1.92 → 0.88 km) and cuts the time in suits from 162 to
  127 minutes.
* **Sunlight over the real terrain.** Every 4 m cell keeps its horizon, so sunrise, sunset and the stretches walked
  in shadow come from the real ridges. At the Gale habitat the sun is up 06:32-17:31 local solar time, against
  06:02-17:58 for a flat horizon.

### Stay safe

* **GO / NO-GO with reasons:** the return margin on the limiting consumable, CO₂ against NASA's 20 mmHg contingency
  limit, sunset, radio line of sight, terrain and space weather.
* **Caution and warning built to NASA-STD-3001 Volume 2:** four alert classes with NASA's colours and tones, latched
  alerts, silence, shelve and inhibit, spoken warnings, an event log and an alarm test. The console watches 28
  conditions and shows the turn-back time. See [docs/NASA_STANDARDS.md](docs/NASA_STANDARDS.md).
* **Uncertainty shown:** the return margin as a range under planning dispersions, how far the sand clues agree, and
  how far two independent terrain models agree, on the map and along the route.
* **Space weather in the plan:** each DONKI forecast counts as a ±12 h window. A full hit during the EVA is NO-GO,
  and the planner offers the first start that clears every window and still ends before sunset.

### When something breaks

* **Ways home.** The fastest walk back from every point, drawn as one network that flows to the habitat like rivers.
  It shows the gateways where many ways home merge (six on Gale, 24-67 minutes out) and the ground with no way home.
  Click anywhere to trace your way back.
* **Shrinking world, a suit-leak drill.** The ground still in reach as oxygen runs down. With a leak at Ridge Alpha,
  120 minutes of oxygen leaves 194 ha in reach, and below about 52 minutes the habitat itself is out of reach.
* **Partner down.** The worst point of the route for an injured partner, and the time to get them to pressure: 21
  minutes at worst on the default Gale route, with PR-2.
* **Emergency caches.** Three oxygen caches at the gateways raise the share of the site within 30 minutes of a safe
  haven from 17 % to 72 %.
* **Skyline fix.** Where am I with no GPS? The helmet's view of the horizon is matched against the terrain model.
  The median error is 4 m on Gale and 14 m on Jezero's flat floor.
* **Fallback card and radio grid.** A printable card for a dead HUD, and grid references ("Kilo seven") to say where
  you are over the radio.

### See the data together

* **Layer tower.** The map's data layers lift off the ground as a 3D stack, each labelled with its mission and
  instrument, and a needle reads one point through every layer.
* **Flood the crater.** Jezero's ancient lake at the levels published by Mangold et al. (2024). At −2,500 m, 57 % of
  the site is under water.
* **Earth link.** Sun, Earth and Mars where they are today, CMEs on their way, the light-time delay (11 minutes each
  way today) and an "Ask Earth" exchange that waits for the real delay.
* **Ingenuity at Jezero.** The helicopter's 24 flights over the site at their altitude, the ground its camera saw,
  and its photos for each flight.
* **The rover teams' own terrain models,** lined up with ours by phase correlation, so the rovers' tracks, samples
  and colour mosaics sit on the right ground. Rover heights now match our terrain within half a metre.

### Two clients

* **Web planner** (React, Leaflet, three.js) for desktop and tablet, in the habitat.
* **3D console** (Godot 4.7): orbit view for planning, first-person helmet HUD for walking, the moving rover, a
  hold-to-confirm ABORT that walks the crew home, glove mode and a cuff menu for suited hands, gamepad and offline
  voice commands, a guided tour and a hands-free demo. It runs at 25-30 FPS on an Intel UHD 620 laptop.

## Built on NASA data

| Mission or source | Data | Used for |
|---|---|---|
| MRO HiRISE (NASA/JPL/University of Arizona, via USGS Astrogeology) | 1 m terrain models, 25 cm orthoimages, colour mosaics | Terrain, slope, roughness, boulders, routing, 3D scene |
| MRO CTX (JPL MMGIS) | Colour mosaics | Basemap |
| MRO CRISM (PDS Geosciences Node, ODE REST) | MTRDR mineral products | Mineral layers, science stops |
| Mars Odyssey THEMIS (ASU, USGS, NASA Mars Trek) | Night IR mosaics, day IR | Sand model, thermal layers |
| Curiosity | REMS weather, RAD dose rates, traverse, raw images; MSL Gale merged DEM mosaic (Parker & Calef, USGS) | Climate calibration, radiation, rover track, ground photos, terrain cross-check |
| Perseverance | MEDA weather, traverse, sample sites, raw images; Mars 2020 TRN HiRISE DTM mosaic (Fergason et al. 2020, USGS) | Sample-depot site, science stops, terrain cross-check |
| Ingenuity (JPL MMGIS, mars.nasa.gov) | Flight paths, waypoints, raw images | Flights layer, scouted ground, photos |
| USGS-NASA Planetary Geologic Mapping Program | SIM 3464 (Sun & Stack 2020), SIM 3292 (Tanaka et al. 2014) | Geologic unit layer and descriptions |
| NASA CCMC DONKI | CME analyses and predicted arrivals at Mars | Space weather in the plan, Earth link |
| NASA GISS Mars24 | Mars time and sun position | Sol, local solar time, sun path |
| ESA / DLR / FU Berlin (Space Agency Partner) | HRSC-MOLA blended terrain model | Regional terrain and far horizon |
| Mangold et al. (2024) | Jezero lake levels | Flood-the-crater layer |

All of these are public products. The site pipeline downloads and caches them. All suit, walking and rover numbers
are planning assumptions and are shown in the app.

## How we checked it

* The sand model was tested against Jezero's mapped bedforms: AUC 0.84, and it flags 1 % of non-dune ground
  instead of 60 %.
* The rover teams' terrain models line up with ours within half a metre after the shift found by phase correlation
  (12 m and 5 m off before).
* The skyline fix is scored on 1,000 random points of each site.
* Planet positions match the January 2025 Mars close approach, and the Mars clocks are cross-checked against
  Mars24.
* The default plans for both sites are GO. A pytest suite covers routing, the suit model, the rover, boulders, CRISM,
  weather, Mars time, the emergency tools and the site configs. The 3D console has scripted check tours, including
  25 NASA-standards checks.

## Sites

| Site | Rover | Story |
|---|---|---|
| **Gale crater · Mount Sharp boxwork** (`gale_boxwork`) | Curiosity | Sample a mineral-cemented boxwork ridge and two sandy hollows that Curiosity explored in 2025 |
| **Jezero crater · Three Forks sample depot** (`jezero_threeforks`) | Perseverance | Recover two of the ten sample tubes Perseverance left at Three Forks, then visit Wildcat Ridge (organic-bearing lake mudstone) and the Amalik outcrop on the delta front |

| Default plan | Walking from the habitat | With the pressurized rover PR-2 |
|---|---|---|
| Gale | 1.92 km walked · 162 min in suits · farthest walk-back 17.8 min · GO | 0.88 km walked + 1.25 km driven · 127 min in suits · walk-back 6.8 min · GO |
| Jezero | 2.57 km walked · 175 min in suits · farthest walk-back 22.5 min · GO | 1.40 km walked + 1.38 km driven · 140 min in suits · walk-back 8.9 min · GO |

Each site is one JSON file in `config/sites/`, so a new site is a new file and one pipeline run.

## Run it

Windows PowerShell, from this folder:

```powershell
python -m venv .venv; .venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python -m pipeline.build_site gale_boxwork        # builds the site data: about 25 min the first time, cached after
.venv\Scripts\python -m pipeline.build_site jezero_threeforks
.\run_web.ps1                                                    # web planner: builds web/dist when needed, starts the API, opens http://localhost:8000
.\run_godot.ps1                                                  # 3D console (finds Godot 4.7 via $env:GODOT or PATH)
.venv\Scripts\python -m pytest -q                                # tests
```

For development, run the API with `.venv\Scripts\python -m uvicorn server.main:app --port 8000` and the web planner
with `cd web; npm install; npm run dev` (http://localhost:5173). The built site data (`data/`) is not stored in the
repository; the pipeline downloads and builds it.

## Layout

```
config/sites/   site definitions (area, terrain models, basemaps, rover feeds, habitat, stops, shelters)
pipeline/       builds a site: terrain mosaic, slope and roughness, rover-team terrain and its offset, sky view and
                horizon, imagery, THEMIS, CRISM, geology, boulders, sand model, terrain confidence, rover track,
                Ingenuity, science score, contours
marsgeo/        shared library: Mars time, site grids, STAC search, map tiles, HTTP session
server/         FastAPI: plans, routes, walk-back, ways home, emergency tools, viewshed, conditions, weather,
                space weather, tiles, traverse sheet, live habitat link
web/            React + Leaflet planner (Vite)
godot/          Godot 4.7 3D EVA console (see godot/README.md)
tests/          pytest suite
docs/           NASA standards notes
```

## Status

Everything described above works and has been checked. Still in progress: a "Smart planner" panel (plan it for me,
scout first, crew map tags, the cost of each rock sample, beat the planner), glare and pace notes along the route,
and the helmet side of the live link and of the HUD-failure drill in the 3D console.

## Disclaimer

An educational project made for the NASA Space Apps Challenge 2026. It is not an operational tool, and it is not a
NASA product or endorsed by NASA.

© 2026 Team Narayani Sena. All rights reserved.
