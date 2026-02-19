# 3D Solar System Visualization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the raw JPL Horizons text dump with an interactive Three.js 3D solar system showing all 8 planet orbits and the 3I/ATLAS hyperbolic trajectory.

**Architecture:** A LiveView hook (`SolarSystem`) mounts a Three.js WebGL scene in the left panel. When the user clicks "Fetch 3I/ATLAS", the server fetches state vectors from JPL Horizons, parses them into `[{x, y, z}]` positions (AU) via `StateVectorParser`, and pushes data to the JS hook via `push_event`. The hook draws the trajectory as a red 3D line over the planet orbits.

**Tech Stack:** Elixir/Phoenix LiveView, Three.js r170 (vendor bundle), esbuild

---

### Task 1: Add Three.js to vendor assets

**Files:**
- Create: `assets/vendor/three.module.js`

**Step 1: Download Three.js ES module build**

```bash
cd /Volumes/MacintoshEDD/workspace/PERSONAL/atlas_tracker
curl -L -o assets/vendor/three.module.js "https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.min.js"
```

**Step 2: Verify the file was downloaded**

```bash
head -1 assets/vendor/three.module.js
```

Expected: minified JS starting with `// threejs.org/license` or similar.

**Step 3: Verify esbuild can bundle it**

Temporarily add to `assets/js/app.js`:

```js
import * as THREE from "../vendor/three.module.js"
console.log("Three.js version:", THREE.REVISION)
```

Then compile:

```bash
mix assets.build
```

Expected: builds without errors. Then **remove** the temporary import lines.

**Step 4: Commit**

```bash
git add assets/vendor/three.module.js
git commit -m "Add Three.js r170 vendor module"
```

Note: This file is ~700KB minified. It's a vendor dependency so large file size is expected.

---

### Task 2: StateVectorParser — Parse JPL Horizons response

**Files:**
- Create: `lib/atlas_tracker/state_vector_parser.ex`
- Create: `test/atlas_tracker/state_vector_parser_test.exs`

**Step 1: Write the failing test**

Create `test/atlas_tracker/state_vector_parser_test.exs`:

```elixir
defmodule AtlasTracker.StateVectorParserTest do
  use ExUnit.Case, async: true

  alias AtlasTracker.StateVectorParser

  @sample_result """
  Some header text
  $$SOE
  2460949.500000000 = A.D. 2025-Oct-01 00:00:00.0000 TDB
   X =-1.473031599831380E+08 Y =-2.077370683445942E+08 Z = 2.175281990054543E+07
   VX=-2.224863603945271E+01 VY= 6.241298060062839E+01 VZ=-3.046970847863886E+00
   LT= 8.525554763125925E+02 RG= 2.555897018251128E+08 RR=-3.816458707505653E+01
  2460956.500000000 = A.D. 2025-Oct-08 00:00:00.0000 TDB
   X =-1.605173434215324E+08 Y =-1.696801359571860E+08 Z = 1.987642809082884E+07
   VX=-2.140034910681917E+01 VY= 6.344658110564275E+01 VZ=-3.161249979338084E+00
   LT= 7.819374093574131E+02 RG= 2.344189379534111E+08 RR=-3.153896926392922E+01
  $$EOE
  Some footer text
  """

  test "parses state vectors into positions in AU" do
    {:ok, positions} = StateVectorParser.parse(@sample_result)

    assert length(positions) == 2

    [first | _] = positions
    assert_in_delta first.x, -1.473031599831380e8 / 1.496e8, 0.01
    assert_in_delta first.y, -2.077370683445942e8 / 1.496e8, 0.01
    assert_in_delta first.z, 2.175281990054543e7 / 1.496e8, 0.01
  end

  test "returns error when no SOE/EOE markers found" do
    assert {:error, :no_ephemeris_data} = StateVectorParser.parse("no data here")
  end

  test "returns empty list for empty SOE/EOE block" do
    result = "$$SOE\n$$EOE"
    assert {:ok, []} = StateVectorParser.parse(result)
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/atlas_tracker/state_vector_parser_test.exs --trace
```

Expected: FAIL — module not found.

**Step 3: Implement StateVectorParser**

Create `lib/atlas_tracker/state_vector_parser.ex`:

```elixir
defmodule AtlasTracker.StateVectorParser do
  @km_per_au 1.496e8

  def parse(result_text) do
    case extract_ephemeris_block(result_text) do
      {:ok, block} ->
        positions = parse_positions(block)
        {:ok, positions}

      :error ->
        {:error, :no_ephemeris_data}
    end
  end

  defp extract_ephemeris_block(text) do
    case String.split(text, "$$SOE") do
      [_, rest] ->
        case String.split(rest, "$$EOE") do
          [block, _] -> {:ok, String.trim(block)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_positions(""), do: []

  defp parse_positions(block) do
    block
    |> String.split(~r/\n\s*\d{7}/, include_captures: true)
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(fn chunks -> Enum.join(chunks) end)
    |> Enum.flat_map(&extract_xyz/1)
  end

  defp extract_xyz(chunk) do
    x_regex = ~r/X\s*=\s*([^\s]+)/
    y_regex = ~r/Y\s*=\s*([^\s]+)/
    z_regex = ~r/Z\s*=\s*([^\s]+)/

    with [_, x_str] <- Regex.run(x_regex, chunk),
         [_, y_str] <- Regex.run(y_regex, chunk),
         [_, z_str] <- Regex.run(z_regex, chunk),
         {x, _} <- Float.parse(x_str),
         {y, _} <- Float.parse(y_str),
         {z, _} <- Float.parse(z_str) do
      [%{x: x / @km_per_au, y: y / @km_per_au, z: z / @km_per_au}]
    else
      _ -> []
    end
  end
end
```

**Step 4: Run tests**

```bash
mix test test/atlas_tracker/state_vector_parser_test.exs --trace
```

Expected: All 3 tests pass.

**Step 5: Commit**

```bash
git add lib/atlas_tracker/state_vector_parser.ex test/atlas_tracker/state_vector_parser_test.exs
git commit -m "Add StateVectorParser to extract positions from JPL Horizons response"
```

---

### Task 3: SolarSystem LiveView Hook — Scene setup with planets

**Files:**
- Create: `assets/js/hooks/solar_system_hook.js`
- Modify: `assets/js/app.js`

**Step 1: Create the hook with static solar system scene**

Create `assets/js/hooks/solar_system_hook.js`:

```js
import * as THREE from "../../vendor/three.module.js"

// Planet data: [name, semiMajorAxis (AU), color, size]
const PLANETS = [
  ["Mercury", 0.39, 0xb0b0b0, 0.04],
  ["Venus",   0.72, 0xe8cda0, 0.06],
  ["Earth",   1.00, 0x4488ff, 0.06],
  ["Mars",    1.52, 0xcc4422, 0.05],
  ["Jupiter", 5.20, 0xd4a574, 0.15],
  ["Saturn",  9.54, 0xc9b077, 0.13],
  ["Uranus",  19.19, 0x88ccdd, 0.10],
  ["Neptune", 30.07, 0x4466ee, 0.10],
]

function createOrbitRing(radius, color) {
  const segments = 128
  const geometry = new THREE.BufferGeometry()
  const positions = new Float32Array((segments + 1) * 3)
  for (let i = 0; i <= segments; i++) {
    const theta = (i / segments) * Math.PI * 2
    positions[i * 3]     = radius * Math.cos(theta)
    positions[i * 3 + 1] = 0
    positions[i * 3 + 2] = radius * Math.sin(theta)
  }
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3))
  return new THREE.LineLoop(geometry, new THREE.LineBasicMaterial({ color, opacity: 0.4, transparent: true }))
}

function createPlanetMarker(semiMajorAxis, color, size) {
  const geometry = new THREE.SphereGeometry(size, 16, 16)
  const material = new THREE.MeshBasicMaterial({ color })
  const mesh = new THREE.Mesh(geometry, material)
  // Place at a fixed angle for now (no ephemeris for planets)
  const angle = Math.random() * Math.PI * 2
  mesh.position.set(
    semiMajorAxis * Math.cos(angle),
    0,
    semiMajorAxis * Math.sin(angle)
  )
  return mesh
}

// Minimal OrbitControls (inline to avoid separate vendor file)
class SimpleOrbitControls {
  constructor(camera, domElement) {
    this.camera = camera
    this.domElement = domElement
    this.target = new THREE.Vector3()
    this.spherical = new THREE.Spherical()
    this.sphericalDelta = new THREE.Spherical()
    this.scale = 1
    this.rotateSpeed = 0.5
    this.zoomSpeed = 1.0

    // Get initial spherical coords from camera
    const offset = new THREE.Vector3().copy(camera.position).sub(this.target)
    this.spherical.setFromVector3(offset)

    this._onMouseDown = this._onMouseDown.bind(this)
    this._onMouseMove = this._onMouseMove.bind(this)
    this._onMouseUp = this._onMouseUp.bind(this)
    this._onWheel = this._onWheel.bind(this)
    this._isPointerDown = false

    domElement.addEventListener("mousedown", this._onMouseDown)
    domElement.addEventListener("wheel", this._onWheel, { passive: false })
  }

  _onMouseDown(e) {
    this._isPointerDown = true
    this._pointerStart = { x: e.clientX, y: e.clientY }
    document.addEventListener("mousemove", this._onMouseMove)
    document.addEventListener("mouseup", this._onMouseUp)
  }

  _onMouseMove(e) {
    if (!this._isPointerDown) return
    const dx = e.clientX - this._pointerStart.x
    const dy = e.clientY - this._pointerStart.y
    this._pointerStart = { x: e.clientX, y: e.clientY }
    const el = this.domElement
    this.sphericalDelta.theta -= 2 * Math.PI * dx / el.clientWidth * this.rotateSpeed
    this.sphericalDelta.phi -= 2 * Math.PI * dy / el.clientHeight * this.rotateSpeed
  }

  _onMouseUp() {
    this._isPointerDown = false
    document.removeEventListener("mousemove", this._onMouseMove)
    document.removeEventListener("mouseup", this._onMouseUp)
  }

  _onWheel(e) {
    e.preventDefault()
    if (e.deltaY > 0) {
      this.scale *= (1 + this.zoomSpeed * 0.05)
    } else {
      this.scale /= (1 + this.zoomSpeed * 0.05)
    }
  }

  update() {
    this.spherical.theta += this.sphericalDelta.theta
    this.spherical.phi += this.sphericalDelta.phi
    this.spherical.phi = Math.max(0.01, Math.min(Math.PI - 0.01, this.spherical.phi))
    this.spherical.radius *= this.scale

    this.sphericalDelta.set(0, 0, 0)
    this.scale = 1

    const offset = new THREE.Vector3().setFromSpherical(this.spherical)
    this.camera.position.copy(this.target).add(offset)
    this.camera.lookAt(this.target)
  }

  dispose() {
    this.domElement.removeEventListener("mousedown", this._onMouseDown)
    this.domElement.removeEventListener("wheel", this._onWheel)
  }
}

const SolarSystem = {
  mounted() {
    this._initScene()
    this._addSun()
    this._addPlanets()
    this._addEclipticGrid()
    this._animate()

    this.handleEvent("trajectory_data", (payload) => {
      this._drawTrajectory(payload.positions)
    })
  },

  destroyed() {
    if (this._animationId) cancelAnimationFrame(this._animationId)
    if (this._controls) this._controls.dispose()
    if (this._renderer) this._renderer.dispose()
  },

  _initScene() {
    const container = this.el
    const width = container.clientWidth
    const height = Math.max(400, container.clientHeight)

    this._scene = new THREE.Scene()
    this._scene.background = new THREE.Color(0x0a0a1a)

    this._camera = new THREE.PerspectiveCamera(60, width / height, 0.01, 500)
    this._camera.position.set(0, 20, 30)

    this._renderer = new THREE.WebGLRenderer({ antialias: true })
    this._renderer.setSize(width, height)
    this._renderer.setPixelRatio(window.devicePixelRatio)
    container.appendChild(this._renderer.domElement)

    this._controls = new SimpleOrbitControls(this._camera, this._renderer.domElement)

    this._resizeObserver = new ResizeObserver(() => {
      const w = container.clientWidth
      const h = Math.max(400, container.clientHeight)
      this._camera.aspect = w / h
      this._camera.updateProjectionMatrix()
      this._renderer.setSize(w, h)
    })
    this._resizeObserver.observe(container)
  },

  _addSun() {
    const sunGeo = new THREE.SphereGeometry(0.2, 32, 32)
    const sunMat = new THREE.MeshBasicMaterial({ color: 0xffdd44 })
    const sun = new THREE.Mesh(sunGeo, sunMat)
    this._scene.add(sun)

    // Sun glow
    const glowGeo = new THREE.SphereGeometry(0.35, 32, 32)
    const glowMat = new THREE.MeshBasicMaterial({ color: 0xffdd44, transparent: true, opacity: 0.15 })
    this._scene.add(new THREE.Mesh(glowGeo, glowMat))
  },

  _addPlanets() {
    for (const [_name, au, color, size] of PLANETS) {
      this._scene.add(createOrbitRing(au, color))
      this._scene.add(createPlanetMarker(au, color, size))
    }
  },

  _addEclipticGrid() {
    const gridHelper = new THREE.GridHelper(80, 40, 0x222244, 0x111133)
    this._scene.add(gridHelper)
  },

  _drawTrajectory(positions) {
    // Remove existing trajectory if any
    if (this._trajectoryLine) {
      this._scene.remove(this._trajectoryLine)
      this._trajectoryLine.geometry.dispose()
      this._trajectoryLine.material.dispose()
    }

    if (!positions || positions.length === 0) return

    const points = positions.map(p => new THREE.Vector3(p.x, p.z, p.y))
    const geometry = new THREE.BufferGeometry().setFromPoints(points)
    const material = new THREE.LineBasicMaterial({ color: 0xff3333, linewidth: 2 })
    this._trajectoryLine = new THREE.Line(geometry, material)
    this._scene.add(this._trajectoryLine)
  },

  _animate() {
    this._animationId = requestAnimationFrame(() => this._animate())
    this._controls.update()
    this._renderer.render(this._scene, this._camera)
  }
}

export default SolarSystem
```

**Step 2: Register the hook in app.js**

In `assets/js/app.js`, add the import and register the hook:

After the existing imports (around line 26), add:

```js
import SolarSystem from "./hooks/solar_system_hook.js"
```

Then modify the LiveSocket creation to merge the hook:

Change:
```js
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})
```

To:
```js
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, SolarSystem},
})
```

**Step 3: Verify it compiles**

```bash
mix assets.build
```

Expected: builds without errors.

**Step 4: Commit**

```bash
git add assets/js/hooks/solar_system_hook.js assets/js/app.js
git commit -m "Add SolarSystem Three.js hook with planets and orbit controls"
```

---

### Task 4: Update TrackerLive to push trajectory data to hook

**Files:**
- Modify: `lib/atlas_tracker_web/live/tracker_live.ex`
- Modify: `test/atlas_tracker_web/live/tracker_live_test.exs`

**Step 1: Update the TrackerLive test**

Replace the existing test in `test/atlas_tracker_web/live/tracker_live_test.exs`:

```elixir
defmodule AtlasTrackerWeb.TrackerLiveTest do
  use AtlasTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag timeout: 60_000

  test "renders the tracker page with 3D canvas", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Atlas Tracker"
    assert html =~ "Fetch 3I/ATLAS"
    assert html =~ "Evaluate"
    assert html =~ "phx-hook=\"SolarSystem\""
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/atlas_tracker_web/live/tracker_live_test.exs --trace
```

Expected: FAIL — no `phx-hook="SolarSystem"` in the HTML yet.

**Step 3: Update TrackerLive render and handle_info**

Replace the full `lib/atlas_tracker_web/live/tracker_live.ex` with:

```elixir
defmodule AtlasTrackerWeb.TrackerLive do
  use AtlasTrackerWeb, :live_view

  alias AtlasTracker.StateVectorParser

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:wolfram_input, "40 + 2")
      |> assign(:wolfram_result, nil)
      |> assign(:loading, nil)
      |> assign(:error, nil)
      |> assign(:trajectory_loaded, false)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <h1 class="text-3xl font-bold mb-8">Atlas Tracker</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
        <%!-- 3D Solar System Panel --%>
        <div class="border rounded-lg p-4">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-xl font-semibold">3I/ATLAS Trajectory</h2>
            <button
              phx-click="fetch_horizons"
              disabled={@loading == :horizons}
              class="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:opacity-50 text-sm"
            >
              <%= if @loading == :horizons, do: "Fetching...", else: "Fetch 3I/ATLAS" %>
            </button>
          </div>
          <div id="solar-system" phx-hook="SolarSystem" phx-update="ignore" class="w-full" style="min-height: 500px;">
          </div>
          <%= if @trajectory_loaded do %>
            <p class="text-xs text-gray-500 mt-2">Drag to rotate, scroll to zoom, right-click to pan</p>
          <% end %>
        </div>

        <%!-- Wolfram Panel --%>
        <div class="border rounded-lg p-6">
          <h2 class="text-xl font-semibold mb-4">Wolfram Kernel</h2>
          <form phx-submit="evaluate_wolfram" class="mb-4">
            <label class="block text-sm text-gray-600 mb-2">Wolfram expression:</label>
            <input
              type="text"
              name="code"
              value={@wolfram_input}
              class="w-full border rounded px-3 py-2 mb-2 font-mono text-sm"
            />
            <button
              type="submit"
              disabled={@loading == :wolfram}
              class="bg-green-600 text-white px-4 py-2 rounded hover:bg-green-700 disabled:opacity-50"
            >
              <%= if @loading == :wolfram, do: "Evaluating...", else: "Evaluate" %>
            </button>
          </form>

          <%= if @wolfram_result do %>
            <pre class="mt-4 p-4 bg-gray-50 rounded text-xs overflow-auto max-h-96"><%= @wolfram_result %></pre>
          <% end %>
        </div>
      </div>

      <%= if @error do %>
        <div class="mt-6 p-4 bg-red-50 border border-red-200 rounded text-red-800">
          <%= @error %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("fetch_horizons", _params, socket) do
    pid = self()
    socket = assign(socket, :loading, :horizons)

    Task.start(fn ->
      result =
        AtlasTracker.HorizonsClient.fetch_state_vectors(
          "C/2025 N1",
          "2025-07-01",
          "2026-06-01",
          "7d"
        )

      send(pid, {:horizons_result, result})
    end)

    {:noreply, socket}
  end

  def handle_event("evaluate_wolfram", %{"code" => code}, socket) do
    pid = self()
    socket = socket |> assign(:loading, :wolfram) |> assign(:wolfram_input, code)

    Task.start(fn ->
      result = AtlasTracker.KernelWorker.evaluate(AtlasTracker.KernelWorker, code)
      send(pid, {:wolfram_result, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:horizons_result, {:ok, %{"result" => result_text}}}, socket) do
    case StateVectorParser.parse(result_text) do
      {:ok, positions} ->
        socket =
          socket
          |> assign(:loading, nil)
          |> assign(:trajectory_loaded, true)
          |> push_event("trajectory_data", %{positions: positions})

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:error, "Failed to parse trajectory data")
         |> assign(:loading, nil)}
    end
  end

  def handle_info({:horizons_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:error, "Horizons error: #{inspect(reason)}")
     |> assign(:loading, nil)}
  end

  def handle_info({:wolfram_result, {:ok, result}}, socket) do
    formatted = Jason.encode!(result, pretty: true)
    {:noreply, socket |> assign(:wolfram_result, formatted) |> assign(:loading, nil)}
  end

  def handle_info({:wolfram_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:error, "Wolfram error: #{inspect(reason)}")
     |> assign(:loading, nil)}
  end
end
```

**Step 4: Run the test**

```bash
mix test test/atlas_tracker_web/live/tracker_live_test.exs --trace
```

Expected: PASS — HTML now contains `phx-hook="SolarSystem"`.

**Step 5: Run all fast tests**

```bash
mix test
```

Expected: All pass (StateVectorParser tests + TrackerLive test + error tests).

**Step 6: Commit**

```bash
git add lib/atlas_tracker_web/live/tracker_live.ex test/atlas_tracker_web/live/tracker_live_test.exs
git commit -m "Wire TrackerLive to push parsed trajectory data to SolarSystem hook"
```

---

### Task 5: Integration test with live Horizons data

**Files:**
- Modify: `test/atlas_tracker/state_vector_parser_test.exs`

**Step 1: Add an integration test that parses real Horizons data**

Add to the existing test file:

```elixir
  @tag :horizons
  test "parses real JPL Horizons response" do
    {:ok, %{"result" => result_text}} =
      AtlasTracker.HorizonsClient.fetch_state_vectors(
        "C/2025 N1",
        "2025-07-01",
        "2026-06-01",
        "7d"
      )

    {:ok, positions} = AtlasTracker.StateVectorParser.parse(result_text)

    # ~52 weeks of weekly data
    assert length(positions) >= 48
    assert length(positions) <= 55

    # All positions should be reasonable AU values (within 50 AU of Sun)
    for pos <- positions do
      distance = :math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
      assert distance < 50.0, "Position #{inspect(pos)} is unreasonably far: #{distance} AU"
      assert distance > 0.1, "Position #{inspect(pos)} is unreasonably close: #{distance} AU"
    end
  end
```

**Step 2: Run integration test**

```bash
mix test test/atlas_tracker/state_vector_parser_test.exs --include horizons --trace
```

Expected: All 4 tests pass (3 unit + 1 integration).

**Step 3: Commit**

```bash
git add test/atlas_tracker/state_vector_parser_test.exs
git commit -m "Add integration test for StateVectorParser with live Horizons data"
```

---

### Task 6: Manual Smoke Test — End-to-End 3D Visualization

**Step 1: Start the Phoenix server**

```bash
mix phx.server
```

**Step 2: Open browser**

Navigate to `http://localhost:4000`

**Step 3: Verify 3D scene loads**

- The left panel should show a dark 3D scene with the Sun (yellow sphere) at center
- 8 planet orbits visible as colored rings
- Small planet markers on each orbit
- A faint grid on the ecliptic plane
- Mouse drag rotates the camera, scroll zooms

**Step 4: Fetch trajectory**

- Click "Fetch 3I/ATLAS"
- After 1-3 seconds, a red line should appear showing the hyperbolic trajectory through the solar system
- The trajectory should pass near Earth's orbit (perihelion at 1.36 AU)
- Help text "Drag to rotate, scroll to zoom, right-click to pan" should appear

**Step 5: Verify Wolfram panel still works**

- Enter `40 + 2` in the Wolfram input
- Click "Evaluate"
- Should display `42`

**Step 6: Success criteria check**

- [x] 3D scene renders with Sun and all 8 planet orbits
- [x] OrbitControls work (drag/zoom/pan)
- [x] Clicking "Fetch 3I/ATLAS" draws the trajectory as a red line
- [x] Trajectory passes through the inner solar system at the right scale
- [x] Wolfram eval panel continues working
- [x] No JS console errors
