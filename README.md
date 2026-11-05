# Atlas Tracker

Explore the trajectories of **3I/ATLAS (C/2025 N1)**, **1I/'Oumuamua**, and **2I/Borisov** in an interactive three.js solar system. Built with Phoenix LiveView and JPL Horizons, with optional local Wolfram computation.

## Requirements and Setup

- Elixir **1.18+**; CI uses **Elixir 1.20.5 / OTP 29**.
- Wolfram Engine or Mathematica is **optional**. The app and trajectories work without it.

```bash
git clone git@github.com:fruizg0302/atlas_tracker.git
cd atlas_tracker
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000). All three trajectories load automatically. Responses are cached for 24 hours; concurrent requests for the same trajectory share a fetch. Requests retry transient failures twice with explicit connection and response timeouts.

### Optional Wolfram Kernel

Set the executable path before starting the app:

```bash
export WOLFRAM_KERNEL_PATH="/path/to/WolframKernel"
mix phx.server
```

Common locations:

- macOS, Mathematica: `/Applications/Mathematica.app/Contents/MacOS/WolframKernel`
- macOS, Wolfram Engine: `/Applications/Wolfram Engine.app/Contents/MacOS/WolframKernel`
- Linux: `/usr/local/Wolfram/WolframEngine/14.0/Executables/WolframKernel`

The panel stays disabled while the kernel warms up. If the executable is missing or exits, the worker stays available to the application and retries startup automatically. The panel updates when the kernel recovers. “Check again” refreshes the displayed status; it does not bypass the retry interval.

Try `40 + 2`, `{1, 2, 3}`, or `<|"a" -> 1, "b" -> "hello"|>` once the kernel is ready. Results display as formatted JSON. One evaluation runs at a time; busy requests receive a notice rather than entering a queue.

**Security:** Wolfram expressions execute arbitrary code. This app has no authentication or rate limiting. Keep it on a trusted network, especially when enabling the kernel. Dependency security advisories must also be reviewed before public deployment.

## Runtime Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `WOLFRAM_KERNEL_PATH` | Unset | Optional executable path. Missing/invalid paths do not prevent startup. |
| `KERNEL_RETRY_MS` | `30000` | Kernel startup retry interval, in milliseconds. |
| `TRAJECTORY_CACHE_TTL_MS` | `86400000` | Response cache TTL in milliseconds; `0` disables retention. |
| `SECRET_KEY_BASE` | Required in production | Cookie/signing secret; generate with `mix phx.gen.secret`. |
| `PHX_HOST` | `example.com` in production | Public hostname used for generated URLs. |
| `PORT` | `4000` | HTTP listening port. |
| `PHX_SERVER` | Unset locally; `true` in Docker | Set to enable the HTTP server in a release. |

Numeric overrides must contain valid integers. Use a positive retry interval and a nonnegative cache TTL. An unset kernel-path variable preserves environment-specific configuration.

## Docker

The multi-stage image builds assets and an Elixir release, then runs as a non-root user on Debian bookworm. Wolfram is not bundled.

```bash
docker build -t atlas_tracker .
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
docker run --rm --init --name atlas_tracker \
  -p 127.0.0.1:4000:4000 \
  -e SECRET_KEY_BASE \
  -e PHX_HOST=localhost \
  atlas_tracker
```

Open [localhost:4000](http://localhost:4000). The kernel-unavailable banner is expected in this image; trajectories still load. Stop the foreground container with Ctrl+C.

For deployment, set `PHX_HOST` to your domain and terminate TLS at a trusted reverse proxy. Production enables HTTPS redirects based on `X-Forwarded-Proto`; the proxy must set that header correctly. Localhost is excluded for local HTTP smoke tests. Avoid publicly publishing the raw HTTP port, and manage secrets outside the image/build context. Enabling Wolfram in a container requires a separately installed, licensed, compatible runtime and an accessible executable.

## Checks and Tests

```bash
# Compile with warnings as errors, format, Credo, and offline tests
mix precommit

# Check formatting without rewriting files
mix format --check-formatted

# Type analysis; the first run builds PLTs
mix dialyzer

# Offline suite: fake kernel, stubbed HTTP, cache and LiveView tests
mix test

# Real Wolfram tests, opt-in
WOLFRAM_KERNEL_PATH=/path/to/WolframKernel mix test --include wolfram

# Live Horizons tests, opt-in and requiring network access
mix test --include horizons
```

The test application deliberately uses an invalid kernel path and a zero cache TTL. Unit tests create isolated workers/caches; real-service tests are excluded by default.

GitHub Actions runs separate **test** and **Dialyzer** jobs on Elixir 1.20.5 / OTP 29. The test job checks compilation, formatting, Credo, and the offline suite. PLTs under `priv/plts` are cached and ignored by Git.

## Architecture

- **KernelWorker:** supervised, resilient port owner with `:warming`, `:ready`, and `:unavailable` states, status subscriptions, and framed JSON results.
- **HorizonsClient:** Req-based HTTP client with bounded retries/timeouts and injectable request options for tests.
- **TrajectoryCache:** public read-concurrent ETS table, monotonic TTL, single-flight monitored fetches, and hit/miss/fetch telemetry.
- **TrackerLive:** independent async trajectory/evaluation tasks, per-object error events/flashes, and live kernel-availability controls.
