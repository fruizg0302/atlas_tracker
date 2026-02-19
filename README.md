# Atlas Tracker

Interactive astronomical knowledge graph explorer powered by a local Wolfram Language kernel, with **3I/ATLAS (C/2025 N1)** as the primary dataset. Built with Phoenix LiveView.

## Prerequisites

- **Elixir** 1.18+ / **OTP** 27+
- **Wolfram Engine** or **Mathematica** installed locally (the free [Wolfram Engine](https://www.wolfram.com/engine/) works)

## Setup

1. Clone the repo and install dependencies:

```bash
git clone git@github.com:fruizg0302/atlas_tracker.git
cd atlas_tracker
mix deps.get
```

2. Configure the Wolfram kernel path in `config/config.exs`:

```elixir
config :atlas_tracker,
  wolfram_kernel_path: "/path/to/your/WolframKernel"
```

Common paths:
- **macOS (Mathematica):** `/Applications/Mathematica.app/Contents/MacOS/WolframKernel`
- **macOS (Wolfram Engine):** `/Applications/Wolfram Engine.app/Contents/MacOS/WolframKernel`
- **Linux:** `/usr/local/Wolfram/WolframEngine/14.0/Executables/WolframKernel`

3. Start the server:

```bash
mix phx.server
```

4. Visit [`localhost:4000`](http://localhost:4000) in your browser.

The Wolfram kernel takes ~5 seconds to pre-warm on first startup. You'll see `WolframKernel pre-warmed successfully` in the logs when it's ready.

## Usage

The UI has two panels:

- **JPL Horizons** — Click "Fetch 3I/ATLAS" to retrieve state vectors from NASA's JPL Horizons API (July 2025 - June 2026, weekly intervals)
- **Wolfram Kernel** — Enter any Wolfram Language expression and click "Evaluate". Try:
  - `40 + 2` — basic arithmetic
  - `{1, 2, 3}` — returns a JSON list
  - `<|"a" -> 1, "b" -> "hello"|>` — returns a JSON object
  - `Module[{GM = 1.327*10^20, a = -(1.36 * 1.496*10^11)/(6.08 - 1), r = 1.36 * 1.496*10^11}, Sqrt[GM * (2/r - 1/a)] / 1000]` — vis-viva speed at perihelion (km/s)

## Running Tests

```bash
# Fast tests only (< 1 second)
mix test

# Include Wolfram kernel integration tests (requires running kernel)
mix test --include wolfram

# Include JPL Horizons API tests (requires internet)
mix test --include horizons

# All integration tests
mix test --include wolfram --include horizons
```

## Architecture

- **KernelWorker** — GenServer wrapping a long-lived `WolframKernel` process via Elixir Port. Uses `__START__`/`__END__` output markers with JSON serialization.
- **HorizonsClient** — HTTP client (Req) for the JPL Horizons REST API.
- **TrackerLive** — Phoenix LiveView connecting both data sources to the browser.
- **Supervision** — KernelWorker is supervised with `:permanent` restart strategy; kernel crashes trigger automatic recovery.
