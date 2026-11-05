# Production Foundations — Design Spec

**Date:** 2026-11-04
**Status:** Approved design, pending implementation plan
**Program:** Atlas Tracker improvements, sub-project 1 of 4

## Background

Atlas Tracker is a Phoenix 1.8 / LiveView 1.1 app that fetches interstellar-object state
vectors from JPL Horizons, renders a three.js solar system via a JS hook, and evaluates
Wolfram Language through a supervised port GenServer. The project is heading toward
production use, deployed as a Docker container, with CI on GitHub Actions. The Wolfram
kernel is an **optional** production feature: the app must boot and serve without it.

### Current pain points (verified against the code)

- `TrackerLive` uses raw `Task.start` + `send` + `handle_info` with a manual
  `trajectories_pending` counter instead of LiveView 1.1 async primitives.
- The template is not wrapped in `<Layouts.app flash={@flash}>`, so flashes never render,
  and the Wolfram form is a raw `<form>`/`<input>` instead of `to_form` + `<.input>`.
- `KernelWorker` raises in `init` when the kernel path is missing (currently always, on
  any non-macOS machine, because `config.exs` hardcodes a macOS path) and crash-loops
  under the supervisor in dev and test.
- `HorizonsClient` has no retries, no explicit timeouts, and no caching; every page load
  hits JPL three times for data that is effectively immutable.
- `kernel_worker_test.exs` waits with `Process.sleep(6_000)`; there are no stubbed-HTTP
  tests and only a single smoke-level LiveView test.
- No CI, no Dockerfile; `mix.exs` says `elixir: "~> 1.15"` while the README requires
  1.18+. Local toolchain: Elixir 1.20.5 / OTP 29 (mise).

## Decisions locked in during brainstorming

1. Wolfram optionality via a **resilient worker with availability states** (approach A),
   not conditional supervision.
2. Horizons caching via a **small ETS-backed `TrajectoryCache` with TTL** (approach A),
   not Req's built-in cache and not Nebulex.
3. Deployment target is a **Docker container**; a Dockerfile is in scope.
4. **GitHub Actions CI** running the precommit checks is in scope.

## Scope

In: KernelWorker resilience, TrackerLive idiom modernization, Horizons hardening +
caching, runtime configuration, test overhaul, credo/dialyxir, Dockerfile, CI.

Out (deferred to later sub-projects): kernel pool / queued evaluations (SP4), any
JavaScript or three.js changes (SP3), physics/epoch correctness (SP2), auth, rate
limiting, LiveDashboard, docker-compose.

## Design

### 1. KernelWorker: resilient state machine

States: `:warming` → `:ready`, plus `:unavailable`.

- `init/1` does not raise. A new `start_kernel/1` helper validates the configured path
  and opens the port inside `try/rescue`. On success: status `:warming`, pre-warm sent.
  On failure: log one clear warning, status `:unavailable`, schedule `:retry_kernel` via
  `Process.send_after/3` (default 30_000 ms, configurable via `:kernel_retry_ms`).
- `handle_info(:retry_kernel, ...)`: if still `:unavailable`, attempt `start_kernel/1`
  again; repeat the schedule on failure. Installing a kernel on a running node heals
  the app without restart.
- Port exit while running: reply `{:error, :kernel_crashed}` to the in-flight caller (if
  any), transition to `:unavailable`, schedule retry. The GenServer itself stays alive;
  supervisor restarts remain for genuine GenServer bugs only.
- Typed errors from `evaluate/3`: `{:error, :unavailable}`, `{:error, :not_ready}`
  (warming), `{:error, :busy}` (another call in flight), `{:error, :kernel_crashed}`,
  `{:error, :parse_error}`. Busy stays a rejection; queuing/pooling is SP4.
- New public API:
  - `status(pid \\ __MODULE__) :: :warming | :ready | :unavailable`
  - `subscribe(pid \\ self())` — subscriber receives `{:kernel_status, worker_pid, status}`
    immediately and on every transition; the worker monitors subscribers and prunes them
    on `:DOWN`.
  - `start_link` options: `:name`, `:kernel_path` (override, for tests), `:retry_ms`,
    `:notify` (pid or list of pids, same messages as `subscribe/1`).
- Wire protocol change: the Wolfram wrapper is emitted as a **single line** (statements
  joined with `;`), which Wolfram accepts identically. This enables a line-oriented fake
  kernel for tests. The `__START__`/`__END__` framing is unchanged.
- `terminate/2` closes the port when one is open (guard `is_port`).

### 2. TrajectoryCache (new module `AtlasTracker.TrajectoryCache`)

- GenServer, named, started in the application supervision tree before the Endpoint.
- Owns a public, `:read_concurrency` ETS table (`:named_table`, `:set`). Callers read ETS
  directly; entries are `{key, body, expires_at_ms}` using monotonic time.
- API: `fetch(object, start, stop, step) :: {:ok, body} | {:error, reason}`.
  - Fresh hit: return from ETS. Miss or expired: `GenServer.call(cache, {:fetch, key}, 60_000)`.
- Single-flight: server state holds `pending :: %{key => [GenServer.from()]}`. The first
  caller for a key spawns an unlinked `Task` running the fetch function and monitors it;
  later callers for the same key are appended to the waiters list. On success: insert
  into ETS, reply `{:ok, body}` to all waiters, demonitor. On task `:DOWN`: reply
  `{:error, :fetch_crashed}`. Fetch failures (returned errors, not crashes) are not
  cached.
- TTL: default 86_400_000 ms (24 h), configurable via `:trajectory_cache_ttl_ms`.
  Expiry is lazy (checked on read); entries swept on insert.
- `start_link` options: `:name`, `:table`, `:ttl_ms`, `:fetch_fun` (default
  `&HorizonsClient.fetch_state_vectors/4`) for test isolation.
- Telemetry: `:telemetry.execute` for `[:atlas_tracker, :trajectory_cache, :hit]`,
  `[:... , :miss]`, and `[:... , :fetch]` (with `:duration` and `:result` metadata).
- Test env sets `:trajectory_cache_ttl_ms` to `0` (never caches) so the app-level cache
  cannot leak state between tests; real caching behavior is covered by unit tests.

### 3. HorizonsClient hardening

- `Req.get` gains: `retry: :safe_transient`, `max_retries: 2`, `receive_timeout: 15_000`,
  `connect_options: [timeout: 10_000]`.
- Merges `Application.get_env(:atlas_tracker, :horizons_req_options, [])` into the
  request options at call time, so tests inject a `plug:` stub.
- Error normalization kept minimal: `{:error, {:http_error, status}}` for non-200,
  `{:error, exception}` for transport errors. (LiveView already inspects reasons.)

### 4. TrackerLive modernization

- `render/1` wraps content in `<Layouts.app flash={@flash}>`.
- Wolfram form rebuilt with `to_form/2` (`as: :wolfram`), `<.form>`, and `<.input>`.
  Unique DOM ids on the form and submit button.
- Trajectory loading: one `start_async(socket, {:trajectory, obj.id}, fn ->
  TrajectoryCache.fetch(...) end)` per interstellar object. Matching `handle_async/3`
  clauses:
  - success: parse via `StateVectorParser`, then `push_event("trajectory_data", ...)`
    on parse success; on parse failure, add to the error flow below;
  - fetch failure / parse failure / task exit: `put_flash(:error, "...#{label}...")`
    **and** `push_event("trajectory_error", %{id: id, label: label})` (the push event
    makes failure paths deterministically testable via `assert_push_event/3`).
- Pending state: `:trajectories_pending` becomes a `MapSet` of ids; the loading banner
  shows `MapSet.size`; loading ends when empty. No manual counter arithmetic, no
  `Task.start`.
- Wolfram evaluation: `start_async(socket, :wolfram_eval, ...)`. A `:wolfram_loading`
  boolean assign disables the submit button while in flight. Results:
  - `{:ok, decoded}`: pretty-printed JSON into `:wolfram_result` as today;
  - `{:error, :busy}` / `{:error, :not_ready}`: `put_flash(:info, ...)` with a
    "busy or still starting" message (distinct from evaluation errors);
  - `{:error, reason}`: `put_flash(:error, ...)`.
- Kernel status UI: `:kernel_status` assign (`:warming | :ready | :unavailable`).
  On connected mount the LiveView calls `KernelWorker.subscribe/1` and renders:
  - `:ready` → form enabled;
  - `:warming` → disabled form, "Kernel starting…" note;
  - `:unavailable` → warning banner ("Wolfram kernel unavailable — the rest of the app
    works without it"), disabled form, and a "Check again" button
    (`phx-click="check_kernel"`) that re-reads `KernelWorker.status/1`.
  Status transitions pushed by the worker's subscribe messages update the UI live.

### 5. Configuration and deployment

- `config/config.exs`: remove the hardcoded `wolfram_kernel_path`.
- `config/runtime.exs` (all envs): set `wolfram_kernel_path` from
  `WOLFRAM_KERNEL_PATH` only when the var is present (`if path = System.get_env(...)`),
  so env-specific config (e.g. the deliberate bad path in `test.exs`) still stands when
  the var is unset; unset/invalid = worker boots `:unavailable`, app still serves.
  Optional `KERNEL_RETRY_MS` and `TRAJECTORY_CACHE_TTL_MS` env overrides with the
  defaults above.
- `config/test.exs`: `wolfram_kernel_path: "/nonexistent/wolfram/kernel"` (app-level
  worker deliberately `:unavailable`) and `trajectory_cache_ttl_ms: 0`.
- Dockerfile via `mix phx.gen.release --docker`, adjusted:
  - builder from the `hexpm/elixir` 1.20.5 / OTP 29 / bookworm-slim line and
    `debian:bookworm-slim` runner (exact tags as generated by `phx.gen.release`);
  - non-root user, `PHX_SERVER=true`, `EXPOSE 4000`,
    `CMD ["/app/bin/atlas_tracker", "start"]`;
  - no Wolfram in the image (optional feature);
  - `.dockerignore`: `.git`, `deps`, `_build`, `assets/node_modules`,
    `priv/static/assets`, `priv/static/cache_manifest.json`, `test`, `docs`.
- README: env-var table (`WOLFRAM_KERNEL_PATH` optional; `SECRET_KEY_BASE`, `PHX_HOST`,
  `PORT`, `PHX_SERVER` for prod), Docker build/run instructions, CI note.

### 6. CI and tooling

- `mix.exs`: `elixir: "~> 1.18"` (1.20.5 satisfies it); add
  `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` and
  `{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}`; dialyzer PLTs under
  `priv/plts`; `precommit` becomes
  `["compile --warnings-as-errors", "deps.unlock --unused", "format", "credo", "test"]`
  (credo with default rules, not `--strict`).
- `.credo.exs` via `mix credo.gen.config`; fix what it flags or scope the config, so
  precommit stays green.
- `.github/workflows/ci.yml`, two jobs on `ubuntu-latest`, both using
  `erlef/setup-beam@v1` pinned to Elixir 1.20.5 / OTP 29 (matching the Dockerfile):
  - `test`: checkout, deps cache, `mix deps.get`, `mix compile --warnings-as-errors`,
    `mix format --check-formatted`, `mix credo`, `mix test`;
  - `dialyzer`: checkout, deps + PLT cache, `mix dialyzer`.
  - Integration-tagged tests (`:wolfram`, `:horizons`) stay excluded in CI.

### 7. Testing plan

No `Process.sleep/1` anywhere; readiness and transitions are driven by `:notify` /
`subscribe` messages and `assert_receive` with timeouts.

- **`test/support/fake_kernel.sh`** (new, executable): POSIX sh loop, one line in → one
  framed JSON response out. Pattern-matched canned answers: line contains `1 + 1` → `2`;
  contains `fail_me` → `{"error": "evaluation failed"}`; anything else → `42`.
- **`kernel_worker_test.exs`** (rewritten, untagged, fast):
  - boots ready against the fake kernel (`:notify` + `assert_receive {:kernel_status, _, :ready}`);
  - evaluate roundtrip returns the canned JSON (tests framing, not math);
  - `fail_me` maps to `{:ok, %{"error" => _}}` (matches real-kernel error semantics);
  - concurrent evaluate → `{:error, :busy}`;
  - path to `/bin/false` → `:unavailable` via notify, no crash;
  - retry-heals: start with a nonexistent tmp path (`retry_ms: 50`), write the fake
    kernel script to that path, `assert_receive {:kernel_status, _, :ready}, 5_000`.
  - The existing real-Wolfram tests stay `@tag :wolfram`, rewritten to use `:notify`
    instead of sleeps; they read the path from `WOLFRAM_KERNEL_PATH` and are run
    manually with that var set.
- **`trajectory_cache_test.exs`** (new): miss-then-hit with an `Agent`-counted
  `fetch_fun`; expiry with `ttl_ms: 0`; single-flight: blocking `fetch_fun` (waits on a
  message from the test, no sleep) with two concurrent fetchers asserts one underlying
  fetch and two `{:ok, _}` results; failed fetches are not cached.
- **`horizons_client_test.exs`**: keep the two tagged live tests; add untagged tests with
  a `plug:` stub (via `Application.put_env(:atlas_tracker, :horizons_req_options, ...)`):
  success from `test/fixtures/horizons_success.txt`; 500 response (stub counts the
  retried calls, asserts `{:error, {:http_error, 500}}`).
- **`tracker_live_test.exs`** (expanded, untagged; endpoint stubs Horizons via
  `horizons_req_options`):
  - page renders inside the app layout (flash group present);
  - kernel-`:unavailable` banner and disabled form (test env guarantees this);
  - submitting evaluation shows the unavailable notice, deterministically (call fails
    immediately);
  - success path: `assert_push_event(view, "trajectory_data", %{id: "3i_atlas"})` for
    each object, then final DOM assertions (loading banner gone);
  - failure path (stub 500s): `assert_push_event(view, "trajectory_error", ...)` and the
    error flash renders.
- **`test/fixtures/horizons_success.txt`** (new): a small real Horizons response
  (short date range) containing `$$SOE`/`$$EOE`.

### 8. Error-handling matrix

| Condition | Worker/client behavior | UI behavior |
| --- | --- | --- |
| Kernel path missing/invalid | `:unavailable`, retry every 30 s | Banner, disabled form, auto-heals |
| Kernel starting | `:warming` → `{:error, :not_ready}` | "Kernel starting…", disabled form |
| Eval while another in flight | `{:error, :busy}` | Info flash "Kernel is busy…" |
| Kernel dies mid-eval | caller gets `{:error, :kernel_crashed}`, worker → `:unavailable` + retry | Error flash |
| Wolfram-side failure | `{:ok, %{"error" => _}}` | Pretty-printed result (as today) |
| Horizons 500/timeout | 2 retries, then typed error | Per-object error flash + `trajectory_error` event; other objects still render |
| Horizons parse failure | `{:error, :no_ephemeris_data}` | Same per-object error flow |
| All data cached | ETS hit, no HTTP | Instant render |

## File-level change list

- `lib/atlas_tracker/kernel_worker.ex` — rewrite internals; add `status/1`,
  `subscribe/1`, `:notify`/`:kernel_path`/`:retry_ms` options, single-line protocol.
- `lib/atlas_tracker/trajectory_cache.ex` — new.
- `lib/atlas_tracker/horizons_client.ex` — retry/timeout options, env merge.
- `lib/atlas_tracker/application.ex` — add `TrajectoryCache` child.
- `lib/atlas_tracker_web/live/tracker_live.ex` — rewrite per section 4.
- `config/config.exs`, `config/runtime.exs`, `config/test.exs` — per section 5.
- `mix.exs` — Elixir requirement, new deps, precommit, dialyzer config.
- `.credo.exs` — generated.
- `.github/workflows/ci.yml` — new.
- `Dockerfile`, `.dockerignore` — new (via `mix phx.gen.release --docker`, adjusted).
- `test/support/fake_kernel.sh`, `test/atlas_tracker/trajectory_cache_test.exs`,
  `test/fixtures/horizons_success.txt` — new.
- `test/atlas_tracker/kernel_worker_test.exs`,
  `test/atlas_tracker/horizons_client_test.exs`,
  `test/atlas_tracker_web/live/tracker_live_test.exs` — rewritten/expanded.
- `README.md` — env vars, Docker, CI.

## Verification

1. `mix precommit` green locally (now includes credo).
2. `mix test` fast suite green without Wolfram and without network.
3. `WOLFRAM_KERNEL_PATH=/path/to/WolframKernel mix test --include wolfram` green on a
   machine with a kernel.
4. `docker build` succeeds; container boots with no `WOLFRAM_KERNEL_PATH` set, serves
   `/`, and shows the kernel-unavailable banner with working trajectories.
5. CI green on the PR, both jobs.
