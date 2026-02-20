import * as THREE from "../../vendor/three.module.js"

// ---------------------------------------------------------------------------
// Planet data with J2000 Keplerian orbital elements + mean anomaly at epoch
// a (AU), e, i (°), omega/Ω (°), w/ω (°), M0 = mean anomaly at J2000 (°)
// ---------------------------------------------------------------------------
const PLANETS = [
  { name: "Mercury", a: 0.387, e: 0.2056, i: 7.005,  omega: 48.331,  w: 29.124,  M0: 174.796, color: 0xb0b0b0, size: 0.25 },
  { name: "Venus",   a: 0.723, e: 0.0068, i: 3.395,  omega: 76.680,  w: 54.884,  M0: 50.115,  color: 0xe8cda0, size: 0.35 },
  { name: "Earth",   a: 1.000, e: 0.0167, i: 0.000,  omega: -11.261, w: 114.208, M0: 357.529, color: 0x4488ff, size: 0.4  },
  { name: "Mars",    a: 1.524, e: 0.0934, i: 1.850,  omega: 49.558,  w: 286.502, M0: 19.373,  color: 0xcc4422, size: 0.3  },
  { name: "Jupiter", a: 5.203, e: 0.0489, i: 1.303,  omega: 100.464, w: 273.867, M0: 20.020,  color: 0xd4a574, size: 0.8  },
  { name: "Saturn",  a: 9.537, e: 0.0565, i: 2.489,  omega: 113.665, w: 339.392, M0: 317.020, color: 0xc9b077, size: 0.7  },
  { name: "Uranus",  a: 19.191, e: 0.0473, i: 0.773, omega: 74.006,  w: 96.999,  M0: 142.238, color: 0x88ccdd, size: 0.55 },
  { name: "Neptune", a: 30.069, e: 0.0086, i: 1.770, omega: 131.784, w: 276.336, M0: 256.228, color: 0x4466ee, size: 0.55 },
]

const AU_SCALE = 3.0
const DEG2RAD = Math.PI / 180

// J2000 epoch: 2000-01-01T12:00:00Z
const J2000_MS = Date.UTC(2000, 0, 1, 12, 0, 0)

// Trajectory date range (matches Horizons fetch in tracker_live.ex)
const TRAJ_START = new Date("2025-07-01").getTime()
const TRAJ_END   = new Date("2026-06-01").getTime()

// ---------------------------------------------------------------------------
// Orbital mechanics helpers
// ---------------------------------------------------------------------------

/** Solve Kepler's equation M = E - e*sin(E) for eccentric anomaly E. */
function solveKepler(M, e) {
  let E = M
  for (let iter = 0; iter < 20; iter++) {
    const dE = (E - e * Math.sin(E) - M) / (1 - e * Math.cos(E))
    E -= dE
    if (Math.abs(dE) < 1e-8) break
  }
  return E
}

/** Convert eccentric anomaly E to true anomaly θ. */
function trueAnomalyFromE(E, e) {
  return 2 * Math.atan2(
    Math.sqrt(1 + e) * Math.sin(E / 2),
    Math.sqrt(1 - e) * Math.cos(E / 2)
  )
}

/** Compute a planet's 3D position for a given date (ms since Unix epoch). */
function planetPositionAtDate(planet, dateMs) {
  const daysSinceJ2000 = (dateMs - J2000_MS) / 86400000
  // Mean motion in deg/day: n = 360 / (a^1.5 * 365.25)
  const n = 360 / (Math.pow(planet.a, 1.5) * 365.25)
  const Mdeg = (planet.M0 + n * daysSinceJ2000) % 360
  const Mrad = Mdeg * DEG2RAD
  const E = solveKepler(Mrad, planet.e)
  const theta = trueAnomalyFromE(E, planet.e)
  return keplerPosition(planet, theta)
}

/** Create a Keplerian elliptical orbit path in 3D. */
function createKeplerianOrbit(elements) {
  const { a, e, i, omega, w } = elements
  const segments = 256
  const points = []
  const p = a * (1 - e * e)
  const iRad = i * DEG2RAD
  const omegaRad = omega * DEG2RAD
  const wRad = w * DEG2RAD

  for (let k = 0; k <= segments; k++) {
    const theta = (k / segments) * Math.PI * 2
    const r = p / (1 + e * Math.cos(theta))
    const xOrb = r * Math.cos(theta)
    const yOrb = r * Math.sin(theta)

    const cosW = Math.cos(wRad), sinW = Math.sin(wRad)
    const cosI = Math.cos(iRad), sinI = Math.sin(iRad)
    const cosO = Math.cos(omegaRad), sinO = Math.sin(omegaRad)

    const x1 = cosW * xOrb - sinW * yOrb
    const y1 = sinW * xOrb + cosW * yOrb
    const x2 = x1
    const y2 = cosI * y1
    const z2 = sinI * y1
    const xEcl = cosO * x2 - sinO * y2
    const yEcl = sinO * x2 + cosO * y2
    const zEcl = z2

    points.push(new THREE.Vector3(xEcl * AU_SCALE, zEcl * AU_SCALE, yEcl * AU_SCALE))
  }

  const geometry = new THREE.BufferGeometry().setFromPoints(points)
  const material = new THREE.LineBasicMaterial({ color: 0x333355, transparent: true, opacity: 0.4 })
  return new THREE.LineLoop(geometry, material)
}

/** Compute a position on a Keplerian orbit at a given true anomaly θ. */
function keplerPosition(elements, theta) {
  const { a, e, i, omega, w } = elements
  const p = a * (1 - e * e)
  const r = p / (1 + e * Math.cos(theta))
  const xOrb = r * Math.cos(theta)
  const yOrb = r * Math.sin(theta)

  const iRad = i * DEG2RAD, omegaRad = omega * DEG2RAD, wRad = w * DEG2RAD
  const cosW = Math.cos(wRad), sinW = Math.sin(wRad)
  const cosI = Math.cos(iRad), sinI = Math.sin(iRad)
  const cosO = Math.cos(omegaRad), sinO = Math.sin(omegaRad)

  const x1 = cosW * xOrb - sinW * yOrb
  const y1 = sinW * xOrb + cosW * yOrb
  const x2 = x1, y2 = cosI * y1, z2 = sinI * y1
  const xEcl = cosO * x2 - sinO * y2
  const yEcl = sinO * x2 + cosO * y2

  return new THREE.Vector3(xEcl * AU_SCALE, z2 * AU_SCALE, yEcl * AU_SCALE)
}

/**
 * Interpolate 3I/ATLAS position from trajectory data points.
 * positions: array of {x, y, z, date} in AU
 * dateMs: target date in ms
 * Returns THREE.Vector3 in scene coords, or null if no data.
 */
function interpolateTrajectory(positions, dateMs) {
  if (!positions || positions.length === 0) return null

  for (let j = 0; j < positions.length - 1; j++) {
    const d0 = new Date(positions[j].date).getTime()
    const d1 = new Date(positions[j + 1].date).getTime()
    if (dateMs >= d0 && dateMs <= d1) {
      const t = (dateMs - d0) / (d1 - d0)
      const p0 = positions[j], p1 = positions[j + 1]
      const x = (p0.x + t * (p1.x - p0.x)) * AU_SCALE
      const y = (p0.y + t * (p1.y - p0.y)) * AU_SCALE
      const z = (p0.z + t * (p1.z - p0.z)) * AU_SCALE
      // Ecliptic -> Three.js: (x, z, y)
      return new THREE.Vector3(x, z, y)
    }
  }

  // Clamp to nearest endpoint
  const first = positions[0], last = positions[positions.length - 1]
  if (dateMs <= new Date(first.date).getTime()) {
    return new THREE.Vector3(first.x * AU_SCALE, first.z * AU_SCALE, first.y * AU_SCALE)
  }
  return new THREE.Vector3(last.x * AU_SCALE, last.z * AU_SCALE, last.y * AU_SCALE)
}

// ---------------------------------------------------------------------------
// Visual helpers
// ---------------------------------------------------------------------------

function createPlanetMarker(radius, color) {
  const geometry = new THREE.SphereGeometry(radius, 16, 12)
  const material = new THREE.MeshBasicMaterial({ color })
  return new THREE.Mesh(geometry, material)
}

function createTextLabel(text, color = "#ffffff", scale = 1.5) {
  const canvas = document.createElement("canvas")
  const ctx = canvas.getContext("2d")
  const fontSize = 48
  ctx.font = `${fontSize}px sans-serif`
  const metrics = ctx.measureText(text)
  const width = metrics.width + 16
  const height = fontSize + 16

  canvas.width = width
  canvas.height = height

  ctx.font = `${fontSize}px sans-serif`
  ctx.fillStyle = color
  ctx.textAlign = "center"
  ctx.textBaseline = "middle"
  ctx.fillText(text, width / 2, height / 2)

  const texture = new THREE.CanvasTexture(canvas)
  texture.minFilter = THREE.LinearFilter
  const spriteMat = new THREE.SpriteMaterial({ map: texture, transparent: true, depthTest: false })
  const sprite = new THREE.Sprite(spriteMat)
  sprite.scale.set(scale * (width / height), scale, 1)
  return sprite
}

function formatDate(ms) {
  const d = new Date(ms)
  return d.toISOString().slice(0, 10)
}

// ---------------------------------------------------------------------------
// Inline OrbitControls (spherical coords, mouse drag + scroll zoom)
// ---------------------------------------------------------------------------

class SimpleOrbitControls {
  constructor(camera, domElement) {
    this.camera = camera
    this.domElement = domElement
    this.target = new THREE.Vector3()

    const offset = new THREE.Vector3().subVectors(camera.position, this.target)
    this.spherical = new THREE.Spherical().setFromVector3(offset)

    this._rotateSpeed = 0.005
    this._zoomSpeed = 1.1
    this._minDistance = 2
    this._maxDistance = 200
    this._minPolarAngle = 0.05
    this._maxPolarAngle = Math.PI - 0.05

    this._isDragging = false
    this._prevMouse = { x: 0, y: 0 }

    this._onMouseDown = this._onMouseDown.bind(this)
    this._onMouseMove = this._onMouseMove.bind(this)
    this._onMouseUp = this._onMouseUp.bind(this)
    this._onWheel = this._onWheel.bind(this)
    this._onTouchStart = this._onTouchStart.bind(this)
    this._onTouchMove = this._onTouchMove.bind(this)
    this._onTouchEnd = this._onTouchEnd.bind(this)

    domElement.addEventListener("mousedown", this._onMouseDown)
    domElement.addEventListener("mousemove", this._onMouseMove)
    domElement.addEventListener("mouseup", this._onMouseUp)
    domElement.addEventListener("mouseleave", this._onMouseUp)
    domElement.addEventListener("wheel", this._onWheel, { passive: false })
    domElement.addEventListener("touchstart", this._onTouchStart, { passive: false })
    domElement.addEventListener("touchmove", this._onTouchMove, { passive: false })
    domElement.addEventListener("touchend", this._onTouchEnd)

    domElement.addEventListener("contextmenu", (e) => e.preventDefault())
  }

  _onMouseDown(e) {
    this._isDragging = true
    this._prevMouse.x = e.clientX
    this._prevMouse.y = e.clientY
  }

  _onMouseMove(e) {
    if (!this._isDragging) return
    const dx = e.clientX - this._prevMouse.x
    const dy = e.clientY - this._prevMouse.y
    this._prevMouse.x = e.clientX
    this._prevMouse.y = e.clientY

    this.spherical.theta -= dx * this._rotateSpeed
    this.spherical.phi -= dy * this._rotateSpeed
    this.spherical.phi = Math.max(this._minPolarAngle, Math.min(this._maxPolarAngle, this.spherical.phi))
    this._updateCamera()
  }

  _onMouseUp() {
    this._isDragging = false
  }

  _onWheel(e) {
    e.preventDefault()
    if (e.deltaY > 0) {
      this.spherical.radius = Math.min(this._maxDistance, this.spherical.radius * this._zoomSpeed)
    } else {
      this.spherical.radius = Math.max(this._minDistance, this.spherical.radius / this._zoomSpeed)
    }
    this._updateCamera()
  }

  _onTouchStart(e) {
    if (e.touches.length === 1) {
      e.preventDefault()
      this._isDragging = true
      this._prevMouse.x = e.touches[0].clientX
      this._prevMouse.y = e.touches[0].clientY
    }
  }

  _onTouchMove(e) {
    if (!this._isDragging || e.touches.length !== 1) return
    e.preventDefault()
    const dx = e.touches[0].clientX - this._prevMouse.x
    const dy = e.touches[0].clientY - this._prevMouse.y
    this._prevMouse.x = e.touches[0].clientX
    this._prevMouse.y = e.touches[0].clientY

    this.spherical.theta -= dx * this._rotateSpeed
    this.spherical.phi -= dy * this._rotateSpeed
    this.spherical.phi = Math.max(this._minPolarAngle, Math.min(this._maxPolarAngle, this.spherical.phi))
    this._updateCamera()
  }

  _onTouchEnd() {
    this._isDragging = false
  }

  _updateCamera() {
    const offset = new THREE.Vector3().setFromSpherical(this.spherical)
    this.camera.position.copy(this.target).add(offset)
    this.camera.lookAt(this.target)
  }

  dispose() {
    this.domElement.removeEventListener("mousedown", this._onMouseDown)
    this.domElement.removeEventListener("mousemove", this._onMouseMove)
    this.domElement.removeEventListener("mouseup", this._onMouseUp)
    this.domElement.removeEventListener("mouseleave", this._onMouseUp)
    this.domElement.removeEventListener("wheel", this._onWheel)
    this.domElement.removeEventListener("touchstart", this._onTouchStart)
    this.domElement.removeEventListener("touchmove", this._onTouchMove)
    this.domElement.removeEventListener("touchend", this._onTouchEnd)
  }
}

// ---------------------------------------------------------------------------
// SolarSystem LiveView Hook
// ---------------------------------------------------------------------------

const SolarSystem = {
  mounted() {
    const container = this.el

    // --- Renderer ---
    // Create a wrapper so the canvas has a fixed height and controls sit below
    this._canvasWrap = document.createElement("div")
    this._canvasWrap.style.cssText = "width:100%; height:580px; position:relative;"
    container.appendChild(this._canvasWrap)

    this._renderer = new THREE.WebGLRenderer({ antialias: true })
    this._renderer.setPixelRatio(window.devicePixelRatio)
    this._renderer.setSize(this._canvasWrap.clientWidth, this._canvasWrap.clientHeight)
    this._canvasWrap.appendChild(this._renderer.domElement)

    // --- Scene ---
    this._scene = new THREE.Scene()
    this._scene.background = new THREE.Color(0x0a0a1a)

    // --- Camera ---
    this._camera = new THREE.PerspectiveCamera(
      60,
      this._canvasWrap.clientWidth / this._canvasWrap.clientHeight,
      0.1,
      1000
    )
    this._camera.position.set(0, 20, 30)
    this._camera.lookAt(0, 0, 0)

    // --- Controls ---
    this._controls = new SimpleOrbitControls(this._camera, this._renderer.domElement)

    // --- Sun ---
    const sunGeo = new THREE.SphereGeometry(1.2, 32, 24)
    const sunMat = new THREE.MeshBasicMaterial({ color: 0xffcc33 })
    this._scene.add(new THREE.Mesh(sunGeo, sunMat))

    const sunLabel = createTextLabel("Sun", "#ffcc33", 1.2)
    sunLabel.position.set(0, 2.0, 0)
    this._scene.add(sunLabel)

    const glowGeo = new THREE.SphereGeometry(1.8, 32, 24)
    const glowMat = new THREE.MeshBasicMaterial({ color: 0xffaa00, transparent: true, opacity: 0.15 })
    this._scene.add(new THREE.Mesh(glowGeo, glowMat))

    this._scene.add(new THREE.AmbientLight(0xffffff, 0.5))

    // --- Ecliptic grid ---
    const grid = new THREE.GridHelper(200, 80, 0x222244, 0x111133)
    grid.material.transparent = true
    grid.material.opacity = 0.3
    this._scene.add(grid)

    // --- Planets ---
    this._planetMeshes = []
    this._planetLabels = []
    for (const planet of PLANETS) {
      const orbit = createKeplerianOrbit(planet)
      this._scene.add(orbit)

      const marker = createPlanetMarker(planet.size, planet.color)
      marker.userData = { planet, labelOffset: planet.size + 0.6 }
      this._scene.add(marker)
      this._planetMeshes.push(marker)

      const colorHex = "#" + planet.color.toString(16).padStart(6, "0")
      const label = createTextLabel(planet.name, colorHex, 1.0)
      this._scene.add(label)
      this._planetLabels.push(label)
    }

    // --- Interstellar object trajectories ---
    // Each entry: { line, positions, marker, label, color }
    this._trajectories = {}

    // Color map for each interstellar object
    this._trajectoryColors = {
      "3i_atlas":    { hex: 0xff5555, css: "#ff5555" },
      "1i_oumuamua": { hex: 0x55ddff, css: "#55ddff" },
      "2i_borisov":  { hex: 0xffaa33, css: "#ffaa33" },
    }

    // --- Listen for trajectory data from LiveView (called per object) ---
    this.handleEvent("trajectory_data", ({ id, label, positions }) => {
      this._addTrajectory(id, label, positions)
      this._updateScene(this._simProgress)
    })

    // --- Time simulation state ---
    // Progress is 0..1 normalized across each object's own time range.
    // For planets and the date display, we map progress to 3I/ATLAS's date range.
    this._simProgress = this._todayProgress()
    this._playing = false
    this._playSpeed = 5  // progress units per real second (in days of 3I range)

    // --- Time controls UI ---
    this._buildTimeControls(container)

    // Position everything to today initially
    this._updateScene(this._simProgress)

    // --- Animation loop ---
    this._lastFrameTime = performance.now()
    this._animationId = null
    const trajDurationDays = (TRAJ_END - TRAJ_START) / 86400000
    const animate = (now) => {
      this._animationId = requestAnimationFrame(animate)

      if (this._playing) {
        const dtSec = (now - this._lastFrameTime) / 1000
        // Advance progress: playSpeed is in days/sec relative to 3I range
        const progressStep = (dtSec * this._playSpeed) / trajDurationDays
        this._simProgress += progressStep

        // Loop back to start
        if (this._simProgress >= 1) this._simProgress = 0

        this._slider.value = this._simProgress * 1000
        this._dateDisplay.textContent = formatDate(this._progressToDate(this._simProgress))
        this._updateScene(this._simProgress)
      }

      this._lastFrameTime = now
      this._renderer.render(this._scene, this._camera)
    }
    animate(performance.now())

    // --- Responsive resize (watch the canvas wrapper, not the outer container) ---
    this._resizeObserver = new ResizeObserver(() => {
      const w = this._canvasWrap.clientWidth
      const h = this._canvasWrap.clientHeight
      if (w === 0 || h === 0) return
      this._camera.aspect = w / h
      this._camera.updateProjectionMatrix()
      this._renderer.setSize(w, h)
    })
    this._resizeObserver.observe(this._canvasWrap)
  },

  /** Convert normalized progress (0..1) to a date in 3I/ATLAS range. */
  _progressToDate(progress) {
    return TRAJ_START + progress * (TRAJ_END - TRAJ_START)
  },

  /** Compute today's progress within the 3I/ATLAS range. */
  _todayProgress() {
    const now = Date.now()
    return Math.max(0, Math.min(1, (now - TRAJ_START) / (TRAJ_END - TRAJ_START)))
  },

  /** Build the time slider + play/pause + speed controls below the canvas. */
  _buildTimeControls(container) {
    const bar = document.createElement("div")
    bar.style.cssText = "display:flex; align-items:center; gap:8px; padding:8px 4px; font-family:monospace; font-size:13px; color:#aaa;"

    // Play/pause button
    const playBtn = document.createElement("button")
    playBtn.textContent = "\u25B6"  // ▶
    playBtn.title = "Play/Pause"
    playBtn.style.cssText = "background:#333; color:#fff; border:1px solid #555; border-radius:4px; padding:4px 10px; cursor:pointer; font-size:14px;"
    playBtn.addEventListener("click", () => {
      this._playing = !this._playing
      playBtn.textContent = this._playing ? "\u23F8" : "\u25B6"  // ⏸ or ▶
    })
    bar.appendChild(playBtn)

    // Speed selector
    const speedSel = document.createElement("select")
    speedSel.style.cssText = "background:#222; color:#aaa; border:1px solid #555; border-radius:4px; padding:3px 6px; font-size:12px;"
    for (const s of [1, 5, 10, 30]) {
      const opt = document.createElement("option")
      opt.value = s
      opt.textContent = `${s}d/s`
      if (s === 5) opt.selected = true
      speedSel.appendChild(opt)
    }
    speedSel.addEventListener("change", () => {
      this._playSpeed = Number(speedSel.value)
    })
    this._playSpeed = 5
    bar.appendChild(speedSel)

    // Progress slider (0..1000 for precision)
    const slider = document.createElement("input")
    slider.type = "range"
    slider.min = 0
    slider.max = 1000
    slider.value = Math.round(this._simProgress * 1000)
    slider.style.cssText = "flex:1; accent-color:#ff5555; cursor:pointer;"
    slider.addEventListener("input", () => {
      this._simProgress = Number(slider.value) / 1000
      this._dateDisplay.textContent = formatDate(this._progressToDate(this._simProgress))
      this._updateScene(this._simProgress)
    })
    this._slider = slider
    bar.appendChild(slider)

    // Date display (shows 3I/ATLAS date)
    const dateDisp = document.createElement("span")
    dateDisp.textContent = formatDate(this._progressToDate(this._simProgress))
    dateDisp.style.cssText = "min-width:90px; text-align:right;"
    this._dateDisplay = dateDisp
    bar.appendChild(dateDisp)

    // "Today" button
    const todayBtn = document.createElement("button")
    todayBtn.textContent = "Today"
    todayBtn.style.cssText = "background:#333; color:#fff; border:1px solid #555; border-radius:4px; padding:4px 8px; cursor:pointer; font-size:12px;"
    todayBtn.addEventListener("click", () => {
      this._simProgress = this._todayProgress()
      this._slider.value = Math.round(this._simProgress * 1000)
      this._dateDisplay.textContent = formatDate(this._progressToDate(this._simProgress))
      this._updateScene(this._simProgress)
    })
    bar.appendChild(todayBtn)

    container.appendChild(bar)
  },

  /** Update all object positions for a given normalized progress (0..1). */
  _updateScene(progress) {
    // Map progress to 3I/ATLAS date for planet positions
    const dateMs = this._progressToDate(progress)

    // Update planet positions
    for (let idx = 0; idx < this._planetMeshes.length; idx++) {
      const mesh = this._planetMeshes[idx]
      const label = this._planetLabels[idx]
      const planet = mesh.userData.planet
      const pos = planetPositionAtDate(planet, dateMs)
      mesh.position.copy(pos)
      label.position.copy(pos)
      label.position.y += mesh.userData.labelOffset
    }

    // Update all interstellar objects using normalized progress into their own date ranges
    for (const [id, traj] of Object.entries(this._trajectories)) {
      if (!traj.positions || traj.positions.length === 0) continue

      // Map progress to this object's own date range
      const firstDate = new Date(traj.positions[0].date).getTime()
      const lastDate = new Date(traj.positions[traj.positions.length - 1].date).getTime()
      const objDateMs = firstDate + progress * (lastDate - firstDate)

      const pos = interpolateTrajectory(traj.positions, objDateMs)
      if (pos) {
        traj.marker.visible = true
        traj.marker.position.copy(pos)
        traj.label.visible = true
        traj.label.position.copy(pos)
        traj.label.position.y += 1.0
      }
    }
  },

  destroyed() {
    if (this._animationId != null) cancelAnimationFrame(this._animationId)
    if (this._controls) this._controls.dispose()
    if (this._renderer) {
      this._renderer.dispose()
      if (this._renderer.domElement && this._renderer.domElement.parentNode) {
        this._renderer.domElement.parentNode.removeChild(this._renderer.domElement)
      }
    }
    if (this._resizeObserver) this._resizeObserver.disconnect()
  },

  /** Add a trajectory for an interstellar object. */
  _addTrajectory(id, label, positions) {
    // Remove old trajectory for this id if present
    const old = this._trajectories[id]
    if (old) {
      if (old.line) { this._scene.remove(old.line); old.line.geometry.dispose(); old.line.material.dispose() }
      if (old.marker) this._scene.remove(old.marker)
      if (old.label) this._scene.remove(old.label)
    }

    if (!positions || positions.length === 0) return

    const colors = this._trajectoryColors[id] || { hex: 0xffffff, css: "#ffffff" }

    // Draw the orbit path
    const points = positions.map(
      (p) => new THREE.Vector3(p.x * AU_SCALE, p.z * AU_SCALE, p.y * AU_SCALE)
    )
    const geometry = new THREE.BufferGeometry().setFromPoints(points)
    const material = new THREE.LineBasicMaterial({ color: colors.hex, linewidth: 2 })
    const line = new THREE.Line(geometry, material)
    this._scene.add(line)

    // Animated marker for this object
    const markerGeo = new THREE.SphereGeometry(0.35, 16, 12)
    const markerMat = new THREE.MeshBasicMaterial({ color: colors.hex })
    const marker = new THREE.Mesh(markerGeo, markerMat)
    marker.visible = false
    this._scene.add(marker)

    const labelSprite = createTextLabel(label, colors.css, 1.2)
    labelSprite.visible = false
    this._scene.add(labelSprite)

    this._trajectories[id] = { line, positions, marker, label: labelSprite }
  },
}

export default SolarSystem
