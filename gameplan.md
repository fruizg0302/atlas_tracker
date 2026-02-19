# Wolfram Kernel Pool + 3I/ATLAS Trajectory Analysis

## Project Vision

This document describes an architecture for building an **interactive astronomical knowledge graph explorer** powered by a pool of local Wolfram Language kernels, with **3I/ATLAS (C/2025 N1)** as the primary demonstration dataset. 3I/ATLAS is the third confirmed interstellar object to pass through our solar system (discovered July 1, 2025), and represents an ideal showcase: its hyperbolic trajectory, retrograde near-ecliptic alignment, and anomalous non-gravitational acceleration make it both computationally interesting and scientifically compelling.

---

## Why 3I/ATLAS as the Demo Dataset

3I/ATLAS has several properties that make it ideal for showcasing the kernel pool architecture:

- **Eccentricity \~6.08** — the highest of any known interstellar object (1I/ʻOumuamua: 1.2, 2I/Borisov: 3.4), making its near-straight path visually dramatic in 3D
- **Retrograde, near-ecliptic trajectory** — tilted only 5° from the ecliptic, which is the source of active scientific debate (Loeb et al. vs. mainstream consensus)
- **Rich public ephemeris data** — available via JPL Horizons REST API in real-time
- **Multiple comparison subjects** — all three known ISOs can be plotted side-by-side
- **Non-gravitational acceleration** — measured outgassing forcing (A1/A2 parameters from MPC) that requires real computation to model, not just a lookup

The data is current (perihelion was October 29, 2025), publicly available, and will generate interest at any technical talk or hackathon through 2026.

---

## Why the Kernel Pool is Superior to the API

The Wolfram Engine gives you **unrestricted computational power** versus the API's pre-canned pods. Instead of parsing `"distance from Earth | 548 light years"` plaintext, you can execute arbitrary Wolfram Language code:

```wolfram
(* Fetch orbital elements directly — structured data *)
AstronomicalData["C/2025 N1", "OrbitalElements"]

(* Query JPL Horizons for state vectors *)
Import["https://ssd.jpl.nasa.gov/api/horizons.api?format=json&COMMAND='C/2025 N1'&EPHEM_TYPE='VECTORS'...", "JSON"]

(* Compare all three ISOs *)
EntityValue[
  {"1I/ʻOumuamua", "2I/Borisov", "C/2025 N1"},
  {"Eccentricity", "Inclination", "PerihelionDistance"}
]
```

For the graph explorer and trajectory analysis, kernels unlock capabilities the API cannot provide:

1. **Trajectory integration in Wolfram Language itself** — numerical integration of equations of motion, both forward and backward in time, to reconstruct origin and future path
2. **Computed relationships** — "Find all stars within 50 light-years of 3I/ATLAS's inferred origin direction" or "Stars with kinematics consistent with the thick galactic disk" require computation, not lookups
3. **Image generation** — HR diagrams, orbit visualizations in 3D, velocity-vs-time plots generated on-demand

---

## Core Analysis Goals

The tech demo should showcase computational queries impossible with the static API:

### 1. Trajectory Reconstruction

Plot the hyperbolic path through the solar system in 3D, overlaid with planetary orbits on the ecliptic plane. Show how the nearly-straight trajectory (eccentricity >> 1) differs visually from bound comet orbits.

```wolfram
(* Orbital elements from JPL — hyperbolic case *)
q = Quantity[1.36, "AstronomicalUnit"];   (* perihelion distance *)
e = 6.08;                                  (* eccentricity *)
i = Quantity[175.1, "AngularDegrees"];    (* inclination — retrograde *)

(* Hyperbolic orbit parametric equations *)
a = q / (e - 1);  (* semi-major axis — negative for hyperbola *)
hyperbolicR[theta_] := a (e^2 - 1) / (1 + e Cos[theta])

ParametricPlot3D[
  {hyperbolicR[theta] Cos[theta], hyperbolicR[theta] Sin[theta], 0},
  {theta, -Pi*0.45, Pi*0.45},
  PlotStyle -> Red,
  AxesLabel -> {"x (AU)", "y (AU)", "z (AU)"}
]
```

### 2. Velocity Profile

3I/ATLAS reached 68 km/s at perihelion (October 29, 2025) — faster than both previous ISOs. Use vis-viva for the hyperbolic case to compute speed at any point along the trajectory:

```wolfram
(* Vis-viva for hyperbolic orbit *)
GM = Quantity[1.327e20, "Meters^3/Seconds^2"];
v[r_] := Sqrt[GM (2/r - 1/a)]

Plot[
  UnitConvert[v[r], "Kilometers/Seconds"],
  {r, Quantity[0.5, "AU"], Quantity[10, "AU"]},
  PlotLabel -> "3I/ATLAS Speed vs Distance from Sun",
  AxesLabel -> {"Distance (AU)", "Speed (km/s)"}
]
```

### 3. Backtrack Origin Direction

Integrate the trajectory backwards to find the incoming asymptotic direction — what point in the sky did 3I/ATLAS come from? Current estimates point toward the galactic thick disk, suggesting an age of 9–13 billion years.

```wolfram
(* Asymptotic incoming velocity vector *)
vInf = Sqrt[GM / (-a)];   (* hyperbolic excess velocity *)
(* Convert to equatorial coordinates for sky map *)
```

### 4. Non-Gravitational Acceleration Analysis

MPC data includes non-gravitational parameters (outgassing forcing) measured at 3.7σ significance. Model and visualize the effect on trajectory:

```wolfram
(* Non-gravitational acceleration model — Marsden formalism *)
A1 = (* value from MPC *); A2 = (* value from MPC *);
g[r_] := 0.111262 (r/2.808)^(-2.15) (1 + (r/2.808)^5.093)^(-4.6142)

nongravForce[r_] := {A1 * g[r], A2 * g[r], 0}  (* radial, transverse, normal *)
```

### 5. Three-ISO Comparative Visualization

Build an interactive graph comparing all three confirmed interstellar objects — trajectories, physical properties, and population statistics:

```wolfram
isos = {"1I/ʻOumuamua", "2I/Borisov", "C/2025 N1"};
properties = {"Eccentricity", "PerihelionDistance", "IncomingVelocity", "EstimatedSize"};

Grid[
  Prepend[
    Table[EntityValue[iso, prop], {iso, isos}, {prop, properties}],
    properties
  ],
  Frame -> All
]
```

### 6. Statistical Significance of Ecliptic Alignment

Reproduce and critique the Loeb et al. analysis: what is the probability that 3I/ATLAS arrived with a trajectory inclined only 5° from the ecliptic by chance? Generate a Monte Carlo simulation of random ISO trajectories:

```wolfram
(* Monte Carlo: probability of 5° or less ecliptic alignment *)
n = 100000;
randomInclinations = RandomVariate[UniformDistribution[{0, 180}], n];
P = Count[randomInclinations, i_ /; i <= 5 || i >= 175] / n
(* Compare to 3I/ATLAS at 175.1° (= 4.9° from retrograde ecliptic) *)
```

---

## Architecture: Kernel Pool with JPL Horizons Integration

### The GenServer Wrapper Pattern

Each `KernelWorker` GenServer owns a Port to a `WolframKernel` OS process and manages its lifecycle:

```elixir
defmodule AstroGraph.KernelWorker do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil)
  end

  def init(_) do
    port = Port.open(
      {:spawn_executable, wolfram_kernel_path()},
      [:binary, :exit_status, :use_stdio, :stderr_to_stdout,
       args: ["-noprompt", "-run"]]
    )
    {:ok, %{port: port, pending: %{}}}
  end

  def evaluate(pid, code, timeout \\ 30_000) do
    GenServer.call(pid, {:eval, code}, timeout)
  end

  def handle_call({:eval, code}, from, %{port: port, pending: pending} = state) do
    ref = make_ref()
    wrapped = ~s(
      Print["START_OUTPUT"];
      Print[ExportString[#{code}, "JSON"]];
      Print["END_OUTPUT"];
    )
    Port.command(port, wrapped)
    {:noreply, %{state | pending: Map.put(pending, ref, {from, []})}}
  end

  def handle_info({port, {:data, data}}, %{port: port, pending: pending} = state) do
    [{ref, {from, buffer}}] = Enum.take(pending, 1)
    accumulated = buffer ++ [data]
    case extract_between_markers(IO.iodata_to_binary(accumulated)) do
      {:ok, json} ->
        GenServer.reply(from, {:ok, Jason.decode!(json)})
        {:noreply, %{state | pending: Map.delete(pending, ref)}}
      :incomplete ->
        {:noreply, %{state | pending: Map.put(pending, ref, {from, accumulated})}}
    end
  end

  def terminate(_reason, %{port: port}), do: Port.close(port)
end
```

### Poolboy Integration

```elixir
# In application.ex
poolboy_config = [
  name: {:local, :wolfram_pool},
  worker_module: AstroGraph.KernelWorker,
  size: 4,
  max_overflow: 2
]

children = [
  :poolboy.child_spec(:wolfram_pool, poolboy_config)
]
```

### JPL Horizons Data Fetching from LiveView

```elixir
def handle_event("fetch_3iatlas_trajectory", _params, socket) do
  result = :poolboy.transaction(:wolfram_pool, fn worker ->
    KernelWorker.evaluate(worker, ~s(
      url = "https://ssd.jpl.nasa.gov/api/horizons.api?" <>
        "format=json&COMMAND='C/2025 N1'&OBJ_DATA='YES'" <>
        "&MAKE_EPHEM='YES'&EPHEM_TYPE='VECTORS'" <>
        "&CENTER='500@10'&START_TIME='2025-07-01'" <>
        "&STOP_TIME='2026-06-01'&STEP_SIZE='7d'";
      Import[url, "JSON"]
    ))
  end)
  {:noreply, update_trajectory(socket, result)}
end

def handle_event("compare_isos", _params, socket) do
  result = :poolboy.transaction(:wolfram_pool, fn worker ->
    KernelWorker.evaluate(worker, ~s(
      isos = {"1I/Oumuamua", "2I/Borisov", "C/2025 N1"};
      Table[
        {iso, AstronomicalData[iso, "Eccentricity"],
              AstronomicalData[iso, "PerihelionDistance"]},
        {iso, isos}
      ]
    ))
  end)
  {:noreply, update_comparison(socket, result)}
end
```

---

## Data Sources

| Source                    | Access Method                    | Data Available                                |
| ------------------------- | -------------------------------- | --------------------------------------------- |
| JPL Horizons REST API     | `Import[url, "JSON"]` in Wolfram | State vectors, orbital elements, ephemeris    |
| Minor Planet Center       | HTTP + JSON parsing              | Astrometric observations, non-grav parameters |
| `AstronomicalData`        | Native Wolfram function          | Cross-referenced catalog properties           |
| `WolframAlpha` (fallback) | `ServiceConnect`                 | Pre-computed pod data for sanity checks       |

---

## What Queries to Demonstrate

| Query                                   | Wolfram Code Pattern                 | "Wow Factor"                         |
| --------------------------------------- | ------------------------------------ | ------------------------------------ |
| Live position of 3I/ATLAS right now     | `Import[horizons_url, "JSON"]`       | Real-time data, not cached           |
| Speed at any distance from Sun          | `Sqrt[GM*(2/r - 1/a)]` with vis-viva | Shows orbital mechanics              |
| Ecliptic alignment probability          | `RandomVariate` Monte Carlo          | Reproduces contested science paper   |
| Stars near inferred origin              | `GeoNearest` / `EntityClass` query   | Spatial graph traversal              |
| All three ISO trajectories side-by-side | `ParametricPlot3D` overlay           | Unique to kernel computation         |
| Non-gravitational force modeling        | Marsden formalism                    | PhD-level computation in the browser |

---

## Critical Implementation Details

### Output Parsing

Wrap every evaluation with markers to reliably delimit async port output:

```wolfram
Print["START_OUTPUT"];
Print[ExportString[result, "JSON"]];
Print["END_OUTPUT"];
```

Parse between markers in `handle_info/2`. For trajectory data, 3I/ATLAS state vectors are large — expect 5–15 KB JSON payloads per query.

### Kernel Licensing

Each kernel process requires a Wolfram Engine license. The **free Wolfram Engine** (non-production use) supports running multiple kernels on one machine. Kernel paths:

- **macOS**: `/Applications/Wolfram Engine.app/Contents/MacOS/WolframKernel`
- **Linux**: `/usr/local/Wolfram/WolframEngine/13.0/Executables/WolframKernel`

### Startup and Memory

Kernels take 2–5 seconds to initialize; pre-warm with a dummy evaluation during app startup. Each kernel uses 200–400 MB RAM — with 4 kernels, budget \~1.5 GB. Monitor with `:erlang.memory()`.

### Input Sanitization

```elixir
# UNSAFE — never interpolate raw user input into Wolfram expressions
code = ~s(AstronomicalData["#{user_input}", "Distance"])

# SAFE — whitelist known entity names or sanitize
@allowed_objects ~w[C/2025\ N1 1I/Oumuamua 2I/Borisov Betelgeuse]
if user_input in @allowed_objects, do: proceed()
```

### Timeout Handling

Some astronomical queries — especially Monte Carlo simulations or fetching full ephemeris tables — can take 30–60 seconds. Set appropriate GenServer call timeouts and show loading states in LiveView.

---

## Architecture Comparison

| Aspect                       | Wolfram Kernel Pool                   | Wolfram Alpha API          |
| ---------------------------- | ------------------------------------- | -------------------------- |
| **Query flexibility**        | Arbitrary Wolfram Language + JPL REST | Pre-defined pod types only |
| **3I/ATLAS trajectory data** | Full state vector integration         | Summary text only          |
| **Rate limits**              | None (local computation)              | 2,000/month free tier      |
| **Latency**                  | 100–500ms (local eval)                | 1–3s (network + compute)   |
| **Result structure**         | Full data structures + JSON           | Plaintext + images         |
| **Monte Carlo simulations**  | Yes, arbitrary                        | No                         |
| **Custom visualizations**    | Generated SVG/PNG on-demand           | Static pre-rendered images |
| **Demo "wow factor"**        | ⭐⭐⭐⭐⭐                            | ⭐⭐⭐                     |

---

## Implementation Roadmap

1. **Phase 1** — Single-kernel prototype validating JPL Horizons REST access and basic `AstronomicalData` queries from Elixir via Port
2. **Phase 2** — Add Poolboy, implement output parsing with START/END_OUTPUT markers, validate concurrent queries
3. **Phase 3** — LiveView UI: 3D trajectory plot (D3 or Three.js hooks), velocity profile chart, ISO comparison table
4. **Phase 4** — Monte Carlo ecliptic alignment simulation, non-gravitational force modeling, interactive "explore origin direction" feature
5. **Phase 5** — Polish, loading states, error handling, kernel crash recovery via OTP supervision

---

## Conclusion

**Build the kernel pool version.** The architecture follows established OTP patterns (Poolboy for resource pooling, Port for external processes, GenServer for state management), and 3I/ATLAS provides a compelling, current, scientifically rich dataset that cannot be fully explored via the Wolfram Alpha API alone.

The ability to say _"I'm querying a computational engine pool via OTP-supervised GenServers to reconstruct the trajectory of a 13-billion-year-old interstellar comet in real time"_ is a sentence that wins hackathons and technical talks. The Monte Carlo reproduction of the Loeb ecliptic alignment controversy alone — live, in a browser, from a Phoenix LiveView — is worth the implementation effort.

Start with a single-kernel prototype to validate Port communication and the JPL Horizons data pipeline, then add Poolboy once the basics work.
