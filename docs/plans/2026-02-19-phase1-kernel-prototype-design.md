# Phase 1 Design: Single-Kernel Prototype

## Overview

Build a Phoenix LiveView application with a single Wolfram kernel managed via an Elixir Port, validating the core data pipeline: JPL Horizons REST API -> Elixir -> Wolfram kernel computation -> browser.

## Decisions

- **Phoenix LiveView from the start** — avoids rewrite when adding UI in Phase 3
- **Elixir fetches HTTP, Wolfram computes** — separation of concerns; Elixir handles HTTP (caching, retries) while Wolfram focuses on computation
- **Elixir Port to WolframKernel** — long-lived process, no restart overhead per evaluation, directly extends to kernel pool in Phase 2

## Components

### KernelWorker GenServer

- Opens a Port to `WolframKernel -noprompt` on `init/1`
- Kernel path: `/Volumes/MacintoshEDD/Applications/Wolfram.app/Contents/MacOS/WolframKernel`
- Sends Wolfram code wrapped with `Print["__START__"]` / `Print["__END__"]` markers
- Accumulates Port output in `handle_info/2` until `__END__` marker is found
- Extracts content between markers and decodes JSON
- One pending evaluation at a time (sequential queue via GenServer mailbox)
- Pre-warms on startup with `1+1` to absorb 2-5s kernel init time
- Supervised with `restart: :permanent`

Note: `ExportString[..., "JSON"]` returns JSON wrapped in extra quotes when printed. Use `WriteString[$Output, ...]` instead of `Print` to avoid the quoting issue.

### HorizonsClient

- Uses `Req` to fetch from `https://ssd.jpl.nasa.gov/api/horizons.api`
- Single function: `fetch_state_vectors(object, start_time, stop_time, step_size)`
- Returns parsed JSON with position + velocity state vectors
- No caching in Phase 1

### TrackerLive (LiveView)

- Button to fetch 3I/ATLAS state vectors from JPL Horizons
- Button to evaluate a Wolfram expression (vis-viva speed computation)
- Results displayed as formatted JSON/text
- Loading state while kernel evaluates
- No 3D visualization — that's Phase 3

### Supervision Tree

```
Application
└── KernelWorker (restart: :permanent)
```

## Error Handling

- **Kernel crash**: Supervisor restarts, next evaluation waits for re-init
- **Kernel timeout**: GenServer call timeout (30s), caller gets `{:error, :timeout}`
- **Horizons API error**: `{:error, reason}` tuple, LiveView shows error message
- **Malformed Wolfram output**: `{:error, :parse_error}` if markers not found

## Environment

- Elixir 1.18.3 / OTP 27
- WolframScript 1.13.0 / Mathematica Student Edition
- Kernel at `/Volumes/MacintoshEDD/Applications/Wolfram.app/Contents/MacOS/WolframKernel`

## Success Criteria

1. KernelWorker starts, pre-warms, and evaluates arbitrary Wolfram expressions via Port
2. HorizonsClient fetches 3I/ATLAS state vectors from JPL
3. LiveView displays results from both data sources
4. Kernel crash triggers automatic restart via OTP supervisor
