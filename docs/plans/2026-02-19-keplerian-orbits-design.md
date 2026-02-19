# Keplerian Orbits + Auto-load + Layout — Design

## Overview

Replace circular orbit approximations with real Keplerian ellipses, auto-load the 3I/ATLAS trajectory on page mount, and move the Wolfram panel below the full-width 3D scene.

## Decisions

- **Keplerian elements in JS constants** — J2000 orbital elements for all 8 planets computed client-side, no API calls needed
- **Auto-load trajectory** — LiveView fetches Horizons data in mount/3 asynchronously, pushes to hook on arrival
- **Full-width 3D scene** — remove 2-column grid, 3D panel takes full width
- **Wolfram panel below** — secondary section underneath the visualization

## Changes

### solar_system_hook.js

Replace `createOrbitRing(radius, color)` (circular LineLoop) with `createKeplerianOrbit(elements, color)` that:
1. Takes orbital elements: semi-major axis (a), eccentricity (e), inclination (i), longitude of ascending node (Ω), argument of perihelion (ω)
2. Computes the elliptical path using the conic equation: r(θ) = a(1-e²) / (1 + e·cos(θ))
3. Rotates into 3D using the three Euler angles (ω, i, Ω)
4. Returns a THREE.Line with the orbit path

Planet orbital elements (J2000 epoch):

| Planet  | a (AU) | e      | i (°)  | Ω (°)    | ω (°)    |
|---------|--------|--------|--------|----------|----------|
| Mercury | 0.387  | 0.2056 | 7.005  | 48.331   | 29.124   |
| Venus   | 0.723  | 0.0068 | 3.395  | 76.680   | 54.884   |
| Earth   | 1.000  | 0.0167 | 0.000  | -11.261  | 114.208  |
| Mars    | 1.524  | 0.0934 | 1.850  | 49.558   | 286.502  |
| Jupiter | 5.203  | 0.0489 | 1.303  | 100.464  | 273.867  |
| Saturn  | 9.537  | 0.0565 | 2.489  | 113.665  | 339.392  |
| Uranus  | 19.191 | 0.0473 | 0.773  | 74.006   | 96.999   |
| Neptune | 30.069 | 0.0086 | 1.770  | 131.784  | 276.336  |

### tracker_live.ex

- Remove 2-column grid, make 3D panel full width
- Auto-fetch Horizons data in mount/3 (only on connected? socket to avoid double-fetch)
- Remove or hide the Fetch button (trajectory loads automatically)
- Move Wolfram panel to a section below the 3D scene

## Success Criteria

1. Planet orbits render as proper ellipses with correct inclinations
2. 3I/ATLAS trajectory appears automatically on page load
3. 3D scene takes full page width
4. Wolfram panel works below the visualization
