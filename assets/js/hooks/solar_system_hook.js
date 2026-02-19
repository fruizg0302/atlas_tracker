import * as THREE from "../../vendor/three.module.js"

// ---------------------------------------------------------------------------
// Planet data  (distance in AU, color)
// ---------------------------------------------------------------------------
const PLANETS = [
  { name: "Mercury", au: 0.39, color: 0xb0b0b0, size: 0.25 },
  { name: "Venus",   au: 0.72, color: 0xe8cda0, size: 0.35 },
  { name: "Earth",   au: 1.0,  color: 0x4488ff, size: 0.4  },
  { name: "Mars",    au: 1.52, color: 0xcc4422, size: 0.3  },
  { name: "Jupiter", au: 5.20, color: 0xd4a574, size: 0.8  },
  { name: "Saturn",  au: 9.54, color: 0xc9b077, size: 0.7  },
  { name: "Uranus",  au: 19.19, color: 0x88ccdd, size: 0.55 },
  { name: "Neptune", au: 30.07, color: 0x4466ee, size: 0.55 },
]

// Scale AU -> scene units.  Inner planets need to be visible while outer
// planets shouldn't be absurdly far away, so we use a mild log-ish scale.
const AU_SCALE = 3.0

function auToScene(au) {
  return au * AU_SCALE
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Create a circular orbit ring at the given radius in the XZ plane. */
function createOrbitRing(radius) {
  const segments = 128
  const points = []
  for (let i = 0; i <= segments; i++) {
    const theta = (i / segments) * Math.PI * 2
    points.push(new THREE.Vector3(Math.cos(theta) * radius, 0, Math.sin(theta) * radius))
  }
  const geometry = new THREE.BufferGeometry().setFromPoints(points)
  const material = new THREE.LineBasicMaterial({ color: 0x333355, transparent: true, opacity: 0.4 })
  return new THREE.LineLoop(geometry, material)
}

/** Create a small sphere mesh for a planet marker. */
function createPlanetMarker(radius, color) {
  const geometry = new THREE.SphereGeometry(radius, 16, 12)
  const material = new THREE.MeshBasicMaterial({ color })
  return new THREE.Mesh(geometry, material)
}

// ---------------------------------------------------------------------------
// Inline OrbitControls (spherical coords, mouse drag + scroll zoom)
// ---------------------------------------------------------------------------

class SimpleOrbitControls {
  constructor(camera, domElement) {
    this.camera = camera
    this.domElement = domElement
    this.target = new THREE.Vector3()

    // Spherical coordinates
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

    // Prevent context menu on right-click drag
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
    this._renderer = new THREE.WebGLRenderer({ antialias: true })
    this._renderer.setPixelRatio(window.devicePixelRatio)
    this._renderer.setSize(container.clientWidth, container.clientHeight)
    container.appendChild(this._renderer.domElement)

    // --- Scene ---
    this._scene = new THREE.Scene()
    this._scene.background = new THREE.Color(0x0a0a1a)

    // --- Camera ---
    this._camera = new THREE.PerspectiveCamera(
      60,
      container.clientWidth / container.clientHeight,
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
    const sun = new THREE.Mesh(sunGeo, sunMat)
    this._scene.add(sun)

    // Sun glow (slightly larger transparent sphere)
    const glowGeo = new THREE.SphereGeometry(1.8, 32, 24)
    const glowMat = new THREE.MeshBasicMaterial({
      color: 0xffaa00,
      transparent: true,
      opacity: 0.15,
    })
    const glow = new THREE.Mesh(glowGeo, glowMat)
    this._scene.add(glow)

    // --- Ambient light (so MeshBasicMaterial looks fine, but useful if
    //     we ever switch to MeshStandardMaterial) ---
    this._scene.add(new THREE.AmbientLight(0xffffff, 0.5))

    // --- Ecliptic grid ---
    const grid = new THREE.GridHelper(200, 80, 0x222244, 0x111133)
    grid.material.transparent = true
    grid.material.opacity = 0.3
    this._scene.add(grid)

    // --- Planets ---
    this._planetMeshes = []
    for (const planet of PLANETS) {
      const r = auToScene(planet.au)

      // Orbit ring
      const ring = createOrbitRing(r)
      this._scene.add(ring)

      // Planet marker — placed on the +X axis initially
      const marker = createPlanetMarker(planet.size, planet.color)
      marker.position.set(r, 0, 0)
      marker.userData = { name: planet.name, orbitRadius: r }
      this._scene.add(marker)
      this._planetMeshes.push(marker)
    }

    // --- Trajectory line (will be replaced when data arrives) ---
    this._trajectoryLine = null

    // --- Listen for trajectory data from LiveView ---
    this.handleEvent("trajectory_data", ({ positions }) => {
      this._drawTrajectory(positions)
    })

    // --- Animation loop ---
    this._animationId = null
    const animate = () => {
      this._animationId = requestAnimationFrame(animate)

      // Slowly rotate planets around their orbits for visual life
      const t = Date.now() * 0.0001
      for (const mesh of this._planetMeshes) {
        const r = mesh.userData.orbitRadius
        // Outer planets orbit slower (Kepler-ish feel)
        const speed = 1 / Math.sqrt(r)
        const angle = t * speed
        mesh.position.set(Math.cos(angle) * r, 0, Math.sin(angle) * r)
      }

      this._renderer.render(this._scene, this._camera)
    }
    animate()

    // --- Responsive resize ---
    this._resizeObserver = new ResizeObserver(() => {
      const w = container.clientWidth
      const h = container.clientHeight
      if (w === 0 || h === 0) return
      this._camera.aspect = w / h
      this._camera.updateProjectionMatrix()
      this._renderer.setSize(w, h)
    })
    this._resizeObserver.observe(container)
  },

  destroyed() {
    // Cancel animation
    if (this._animationId != null) {
      cancelAnimationFrame(this._animationId)
    }

    // Dispose controls
    if (this._controls) {
      this._controls.dispose()
    }

    // Dispose renderer
    if (this._renderer) {
      this._renderer.dispose()
      if (this._renderer.domElement && this._renderer.domElement.parentNode) {
        this._renderer.domElement.parentNode.removeChild(this._renderer.domElement)
      }
    }

    // Disconnect resize observer
    if (this._resizeObserver) {
      this._resizeObserver.disconnect()
    }
  },

  /**
   * Draw a trajectory as a red line.
   * JPL ecliptic coords: X right, Y forward, Z up
   * Three.js coords:     X right, Y up, Z toward camera
   * Mapping: Three(x, y, z) = JPL(x, z, y)
   */
  _drawTrajectory(positions) {
    // Remove old trajectory if present
    if (this._trajectoryLine) {
      this._scene.remove(this._trajectoryLine)
      this._trajectoryLine.geometry.dispose()
      this._trajectoryLine.material.dispose()
      this._trajectoryLine = null
    }

    if (!positions || positions.length === 0) return

    const points = positions.map(
      (p) => new THREE.Vector3(p.x * AU_SCALE, p.z * AU_SCALE, p.y * AU_SCALE)
    )

    const geometry = new THREE.BufferGeometry().setFromPoints(points)
    const material = new THREE.LineBasicMaterial({ color: 0xff3333, linewidth: 2 })
    this._trajectoryLine = new THREE.Line(geometry, material)
    this._scene.add(this._trajectoryLine)
  },
}

export default SolarSystem
