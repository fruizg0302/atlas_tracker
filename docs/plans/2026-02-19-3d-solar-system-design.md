# 3D Solar System Visualization — Design

## Overview

Replace the raw JPL Horizons text output in the left panel with an interactive 3D solar system scene rendered via Three.js, showing all 8 planet orbits and the 3I/ATLAS hyperbolic trajectory.

## Decisions

- **Three.js via LiveView hook** — standard 3D library, ~150KB, OrbitControls for free camera interaction
- **Replace left panel only** — Wolfram eval panel stays on the right as-is
- **All 8 planets** — circular orbit rings + small exaggerated spheres at approximate positions
- **AU as scene unit** — OrbitControls zoom handles the 0.39–30 AU scale range naturally
- **Server-side parsing** — Elixir parses the JPL Horizons text into `[{x, y, z}]` positions, pushes to JS hook

## Components

### SolarSystemHook (JS)

LiveView hook mounted on a `<div>` in the left panel. Creates a Three.js WebGL scene with:

- **Sun** — glowing yellow sphere at origin
- **Planet orbits** — 8 circular `LineLoop` rings at known semi-major axes (Mercury 0.39 AU to Neptune 30.07 AU), each with a distinct color
- **Planet markers** — small spheres at approximate positions on their orbits
- **Ecliptic grid** — faint grid on the XY plane for spatial reference
- **OrbitControls** — mouse drag to rotate, scroll to zoom, right-click to pan
- **Responsive resize** — re-renders on container resize

Listens for `push_event("trajectory_data", payload)` from LiveView. On receipt, draws the 3I/ATLAS trajectory as a red `Line` from the position array.

### StateVectorParser (Elixir)

Parses JPL Horizons API response text. Extracts position vectors from between `$$SOE` and `$$EOE` markers. Each data block contains `X`, `Y`, `Z` in km — converts to AU (divide by 1.496e8).

Returns: `[%{x: float, y: float, z: float}, ...]`

### TrackerLive (modified)

Left panel changes from `<pre>` text dump to a `<div>` with `phx-hook="SolarSystem"`. On horizons result, parses state vectors and pushes to hook instead of displaying raw text. Raw text optionally available via a toggle.

## Data Flow

1. User clicks "Fetch 3I/ATLAS"
2. `HorizonsClient.fetch_state_vectors/4` returns raw API response
3. `StateVectorParser.parse/1` extracts `[{x, y, z}]` positions in AU
4. LiveView pushes `trajectory_data` event with positions to JS hook
5. Hook draws trajectory as a 3D line, camera auto-adjusts to frame it

## Planet Data

Static constants (no API call needed):

| Planet  | Semi-major axis (AU) | Color   |
|---------|---------------------|---------|
| Mercury | 0.39                | #b0b0b0 |
| Venus   | 0.72                | #e8cda0 |
| Earth   | 1.00                | #4488ff |
| Mars    | 1.52                | #cc4422 |
| Jupiter | 5.20                | #d4a574 |
| Saturn  | 9.54                | #c9b077 |
| Uranus  | 19.19               | #88ccdd |
| Neptune | 30.07               | #4466ee |

## File Structure

- `assets/vendor/three.min.js` — Three.js r170+ (ES module build)
- `assets/vendor/three-orbit-controls.js` — OrbitControls
- `assets/js/hooks/solar_system_hook.js` — LiveView hook
- `lib/atlas_tracker/state_vector_parser.ex` — Horizons text parser
- Modified: `lib/atlas_tracker_web/live/tracker_live.ex`

## Error Handling

- WebGL not available: show fallback message in the panel
- Horizons fetch fails: show error text (existing behavior)
- Empty state vectors: show scene with planets only, no trajectory

## Success Criteria

1. Clicking "Fetch 3I/ATLAS" shows a 3D scene with the Sun, 8 planet orbits, and the red hyperbolic trajectory
2. Mouse drag rotates, scroll zooms, right-click pans
3. Zooming in shows inner planets clearly, zooming out shows full trajectory to outer solar system
4. Wolfram eval panel continues working unchanged
