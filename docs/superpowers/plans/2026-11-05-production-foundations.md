# Production Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Atlas Tracker boot without Wolfram, fetch trajectories reliably, and ship as a tested Docker release with CI.

**Architecture:** Keep the supervised kernel worker alive through availability transitions. Route Horizons requests through a single-flight ETS cache, and use LiveView async callbacks for independent trajectory and evaluation results. Keep deployment configuration at runtime.

**Tech Stack:** Phoenix 1.8, LiveView 1.1, Elixir 1.20.5 / OTP 29, Req, ETS, ExUnit, Credo, Dialyxir, Docker, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-04-production-foundations-design.md`

## Global Constraints

- Elixir requirement: `elixir: "~> 1.18"`; CI and Docker pin Elixir 1.20.5 / OTP 29.
- Wolfram is optional. No kernel pool, evaluation queue, authentication, rate limiting, LiveDashboard, or docker-compose in this sub-project.
- No JavaScript, three.js, physics, or epoch changes.
- Use Req, with `retry: :safe_transient`, `max_retries: 2`, `receive_timeout: 15_000`, and `connect_options: [timeout: 10_000]`.
- Default kernel retry: `30_000` ms. Default cache TTL: `86_400_000` ms. Test application cache TTL: `0`.
- LiveView templates begin with `<Layouts.app flash={@flash}>`; forms use `to_form`, `<.form>`, and `<.input>`.
- Use Tailwind for new/modified UI, no new daisyUI components, inline scripts, or external script/link dependencies.
- Tests start processes with `start_supervised!`; no `Process.sleep/1` or `Process.alive?/1`. Synchronize with messages, monitors, and same-sender `:sys.get_state/1` barriers.
- Real-service tests remain tagged `:wolfram` / `:horizons`, excluded by default and in CI.
- Finish with `mix precommit`; CI also checks formatting without rewriting files. Credo uses default rules, not `--strict`.
- Each commit step requires reviewing staged diff/status. Do not push or create a PR without authorization.

## Review Focus

1. Port exits racing with writes or late messages must not kill the worker or strand an evaluation caller (Task 1).
2. A crashed cache fetch must release every waiter; later requests and unrelated keys must still work (Task 3).
3. Horizons may return HTTP 200 with an error, missing `result`, or a non-string `result`; each object must finish loading without crashing the page (Tasks 2 and 4).
4. Adding the app layout must not squeeze the existing full-width solar system into its default `max-w-2xl` container (Task 4).
5. The release must serve HTTP without Wolfram, preserve runtime settings, and include built static assets despite `.dockerignore` (Task 6).

## File Responsibilities and Dependency Order

- `kernel_worker.ex`: kernel process lifecycle, framed JSON, subscribers, typed evaluation errors.
- `config/{config,runtime,test}.exs`: optional kernel path, retry/TTL overrides, isolated test defaults.
- `horizons_client.ex`: bounded HTTP retries/timeouts and Req test injection.
- `trajectory_cache.ex`: ETS ownership, expiry, monitored single-flight fetches, telemetry.
- `application.ex`: supervise the cache before the endpoint.
- `tracker_live.ex`: async orchestration, form state, availability UI, per-object errors.
- `components/layouts.ex`: optional full-width content mode; preserve the existing default.
- `test/support/fake_kernel.sh`: executable, line-oriented fake protocol peer; no Wolfram requirement.
- `test/fixtures/horizons_success.txt`: short recorded Horizons result used by offline tests.
- Worker/client/cache/LiveView test files: behavioral tests for their respective boundaries.
- `mix.exs`, `mix.lock`, `.credo.exs`, `.gitignore`, `.github/workflows/ci.yml`: analysis tooling and CI.
- `Dockerfile`, `.dockerignore`, generated `rel/` scripts, `README.md`: reproducible release and operator instructions.

Tasks 1–3 establish the APIs consumed by Task 4. Task 5 validates the whole app. Task 6 packages the verified result.

---

### Task 1: Resilient Optional Kernel

**Files:** Modify `lib/atlas_tracker/kernel_worker.ex`, `config/config.exs`, `config/runtime.exs`, `config/test.exs`, `test/atlas_tracker/kernel_worker_test.exs`; create `test/support/fake_kernel.sh`, `test/atlas_tracker/kernel_worker_integration_test.exs`, `test/atlas_tracker/runtime_config_test.exs`.

**Interfaces:**
- Preserve `start_link(opts \\ [])` and `evaluate(worker, code, timeout \\ 30_000)`.
- Add `status(worker \\ __MODULE__) :: :warming | :ready | :unavailable`.
- Add `subscribe(subscriber \\ self(), worker \\ __MODULE__) :: :ok`. Existing spec calls `subscribe/0,1` target the named application worker; `/2` isolates unit tests.
- `start_link` accepts `:name`, `:kernel_path`, `:retry_ms`, and `:notify` (pid or list).
- Subscribers receive `{:kernel_status, worker_pid, status}` immediately and on transitions.
- Evaluation returns `{:ok, decoded}` or `{:error, :unavailable | :not_ready | :busy | :kernel_crashed | :parse_error}`.

- [ ] **Step 1: Write deterministic protocol/lifecycle tests and the fake peer.**

  Fake script: POSIX shell, executable bit committed, `IFS= read -r line` loop. Match `1 + 1` → JSON `2`, `fail_me` → `{"error":"evaluation failed"}`, default → `42`; frame with `__START__` / `__END__`.

  Add test controls before the default case: `hold_me` emits no frame, `exit_me` exits nonzero, `bad_json` emits a framed invalid JSON value. All test workers are unnamed unless a fixed test name is explicitly needed.

  Tests and required assertions:
  - `"notifies warming then ready"`: receive both status messages, then `assert KernelWorker.status(worker) == :ready`.
  - `"returns decoded results and Wolfram error objects"`: `assert {:ok, 42} = evaluate(worker, "40 + 2")`; `assert {:ok, %{"error" => _}} = evaluate(worker, "fail_me")`.
  - `"rejects a second evaluation"`: submit `hold_me` using `:gen_server.send_request/2` from the test process, synchronize with `:sys.get_state/1`, then `assert {:error, :busy} = evaluate(worker, "40 + 2")`.
  - `"rejects evaluation while warming"`: use a temporary fake executable that reads input without replying to pre-warm; assert `{:error, :not_ready}`.
  - `"normalizes invalid JSON and remains usable"`: `bad_json` returns `{:error, :parse_error}`; the next arithmetic evaluation succeeds.
  - `"boots unavailable for missing configuration, bad paths, and non-executable files"`: assert immediate `:unavailable` notification and `{:error, :unavailable}` from evaluation; use explicit paths or restore any changed application env.
  - `"survives an executable that exits"`: use `/bin/false`, await `:unavailable`, then successfully call `status(worker)`.
  - `"releases an in-flight caller when the port exits"`: evaluate `exit_me`; assert `{:error, :kernel_crashed}`, an unavailable notification, and a responsive worker.
  - `"ignores stale port messages and handles a closed-port write"`: capture the old test port, close it before a queued evaluation is handled, and assert the caller gets `{:error, :kernel_crashed}` without worker termination; after retry, replay old-port data/exit messages and assert the new worker status/result is unaffected. Use explicit mailbox ordering, not timing delays.
  - `"reassembles split frames"`: inject partial marker/JSON messages for a held evaluation using the test port identity, then assert exactly one decoded reply after the final chunk.
  - `"heals when a kernel appears"`: use a unique temporary nonexistent path and `retry_ms: 50`, install/chmod the fake script there, then `assert_receive {:kernel_status, ^worker, :ready}, 5_000`.
  - `"subscribes immediately and removes dead subscribers"`: call `subscribe(subscriber, worker)`, assert current/transition notifications; monitor subscriber shutdown and synchronize before checking that its monitor is removed.

  In `runtime_config_test.exs`, use `Config.Reader` with controlled environment variables and restore them on exit. Add `"unset path preserves test override"` asserting `/nonexistent/wolfram/kernel`, and `"runtime overrides apply"` asserting a supplied temporary path, retry `17`, and TTL `23`. Run serially because environment variables are global.

- [ ] **Step 2: Run the new worker tests and record the expected failures.**

  Run: `mix test test/atlas_tracker/kernel_worker_test.exs`
  Expected: failures for missing APIs/options and the current crashing initialization.

- [ ] **Step 3: Implement the worker state machine.**

  `init/1` builds state, monitors initial subscribers, and attempts startup without raising. Validate the path and rescue port-open/write failures. Pre-warm into `:warming`; accept valid framed pre-warm JSON before entering `:ready`. Failed startup/pre-warm or port death enters `:unavailable`, clears stale port/buffer/caller state, and maintains only one retry timer. Do not repeat the unavailable warning on every identical retry.

  Emit the existing Wolfram wrapper as one line plus a terminating newline. Keep the expression itself intact, including string literals; do not flatten user code with a whitespace replacement. Preserve framing across arbitrary data chunks. Ignore messages belonging to an old port after retry; handle port exits and command failures without a second caller reply. Monitor subscribers and demonitor them when removed. Guard termination cleanup for absent/already-closed ports.

- [ ] **Step 4: Implement runtime configuration.**

  Remove the hardcoded path from `config.exs`. In all environments, apply `WOLFRAM_KERNEL_PATH` only when set; read optional `KERNEL_RETRY_MS` / `TRAJECTORY_CACHE_TTL_MS` overrides as integers. Set test defaults to `/nonexistent/wolfram/kernel` and TTL `0`.

- [ ] **Step 5: Preserve real integration coverage without sleeps and verify the task.**

  Move real arithmetic/list/map/error tests into the new integration file, tagged `:wolfram`, reading `WOLFRAM_KERNEL_PATH` and awaiting `:notify` readiness. Remove the obsolete skipped/sleeping supervision test; ordinary unit coverage must not need Wolfram.

  Run: `mix test test/atlas_tracker/kernel_worker_test.exs test/atlas_tracker/runtime_config_test.exs`
  Expected: zero failures, no real kernel needed.

- [ ] **Step 6: Commit the task.**

  Stage only this task's listed files; review staged diff/status.
  Commit: `git commit -m "Make Wolfram kernel optional and resilient"`

### Task 2: Bounded, Offline-Testable Horizons Requests

**Files:** Modify `lib/atlas_tracker/horizons_client.ex`, `test/atlas_tracker/horizons_client_test.exs`; create `test/fixtures/horizons_success.txt`.

**Interfaces:**
- Preserve `HorizonsClient.fetch_state_vectors(object, start, stop, step) :: {:ok, map} | {:error, reason}`.
- Read `Application.get_env(:atlas_tracker, :horizons_req_options, [])` per call, merged over default Req options.
- Preserve `{:error, {:http_error, status}}` for non-success HTTP and `{:error, exception}` for transport failures. Successful maps remain unmodified, even when Horizons reports an application error.

- [ ] **Step 1: Record a small real fixture and write failing stubbed tests.**

  Record a short public Horizons result containing `$$SOE` / `$$EOE`; note query parameters in a fixture header. Fixture acquisition is a one-time authoring step, never part of tests.

  Remove the module-wide live-service tag; retain the two live cases with individual `@tag :horizons`. Make env-mutating tests serial, saving/restoring the prior config including whether it existed.

  Untagged tests use `plug:` functions returning JSON and no sockets. Set `retry_delay` to return `0` in their restored test config:
  - `"sends the expected query and returns fixture data"`: verify `COMMAND`, `CENTER`, dates, and step; assert `{:ok, %{"result" => ^fixture}}`.
  - `"retries HTTP 500 twice"`: count stub calls with a supervised Agent, override `retry_delay` to return `0`, assert `{:error, {:http_error, 500}}` and count `3`.
  - `"retries transient failures but not HTTP 400"`: transient-then-200 succeeds; HTTP 400 returns its status with count `1`.
  - `"preserves HTTP 200 application error bodies"`: return `%{"result" => "No matches found"}` and assert the unchanged successful map.
  - `"returns transport exceptions"`: inject a Req test transport error and assert the same error type instead of an exit.

- [ ] **Step 2: Verify the retry tests fail before implementation.**

  Run: `mix test test/atlas_tracker/horizons_client_test.exs`
  Expected: failures because the configured stub/retry options are not used.

- [ ] **Step 3: Implement request options without changing query semantics.**

  Apply the exact Req defaults from Global Constraints, then merge `horizons_req_options`. Keep JPL parameters and response tuples compatible. Do not turn HTTP-200 application errors into HTTP errors.

- [ ] **Step 4: Verify the client tests pass offline.**

  Run: `mix test test/atlas_tracker/horizons_client_test.exs`
  Expected: zero failures, two live tests excluded, retries have no real backoff delay.

- [ ] **Step 5: Commit the task.**

  Stage the three listed files; review staged diff/status.
  Commit: `git commit -m "Add bounded retries and offline Horizons tests"`

### Task 3: Single-Flight Trajectory Cache

**Files:** Create `lib/atlas_tracker/trajectory_cache.ex`, `test/atlas_tracker/trajectory_cache_test.exs`; modify `lib/atlas_tracker/application.ex`.

**Interfaces:**
- `TrajectoryCache.start_link(opts \\ [])`: `:name`, `:table`, `:ttl_ms`, `:fetch_fun`; default fetch function is `&HorizonsClient.fetch_state_vectors/4`.
- `fetch(object, start, stop, step, opts \\ []) :: {:ok, body} | {:error, reason}`. `/4` uses the named app cache/table; `/5` accepts `server:` and `table:` for isolated tests.
- Key: `{object, start, stop, step}`; ETS entry: `{key, body, expires_at_ms}` using monotonic milliseconds.
- Events: `[:atlas_tracker, :trajectory_cache, :hit | :miss | :fetch]`. Hits/misses measure `%{count: 1}`; fetch measures `%{duration: native_time}` with metadata `%{key: key, result: :ok | :error}`.

- [ ] **Step 1: Write failing cache behavior tests.**

  Start isolated caches/tables with fixed test-only names, supervised counter Agents, and injected fetch functions. Assert:
  - `"miss then hit"`: two identical calls return the same body; underlying call count is `1`.
  - `"keys include all query fields"`: change each key field independently; each variation triggers a fetch.
  - `"zero TTL never caches"`: two sequential calls with `ttl_ms: 0` produce count `2`.
  - `"expired entries are swept on insert"`: insert an explicitly expired entry into the public test table, fetch another key, then assert the expired entry is gone.
  - `"single flight shares one result"`: the injected function sends `{:fetch_started, self()}` then awaits a release message. Submit two requests from the test using `:gen_server.send_request/2`, synchronize with `:sys.get_state/1`, release the fetch, and assert both responses and count `1`.
  - `"different keys fetch independently"`: hold one key, complete another before releasing the first.
  - `"failures are not cached"`: two sequential returned errors produce count `2`.
  - `"fetch crash releases all waiters and allows retry"`: crash a held fetch with two waiters, assert two `{:error, :fetch_crashed}` replies, then fetch successfully.
  - `"late callers reuse a completed value"`: queue a miss after the direct read but after insertion; server-side freshness recheck prevents a duplicate fetch.
  - `"missing fast-path table falls back to the server"`: use a nonexistent lookup-table option against a running isolated server; assert the fetch succeeds rather than raising from ETS.
  - `"emits telemetry"`: attach/detach a unique handler, assert hit/miss counts plus nonnegative fetch duration and correct result metadata.

- [ ] **Step 2: Run the tests to establish red.**

  Run: `mix test test/atlas_tracker/trajectory_cache_test.exs`
  Expected: failure because `TrajectoryCache` does not exist.

- [ ] **Step 3: Implement ETS ownership and monitored fetches.**

  Own a public named `:set` table with `read_concurrency: true`. Read directly on the fast path; missing tables during a cache restart count as misses rather than raising `ArgumentError`. Recheck freshness in the server before starting a fetch.

  Track waiters by key and monitored tasks by reference. Use unlinked monitored tasks; send results back, insert only successful results, sweep expired entries, reply to all waiters, then demonitor/flush. A task `:DOWN` without a handled result replies `{:error, :fetch_crashed}` and removes pending state. Ignore late results for a cleared reference. Use the spec's `60_000` ms server-call timeout.

  Add the cache child before the Endpoint; its default TTL comes from `:trajectory_cache_ttl_ms`. Test-app TTL `0` was established in Task 1. No extra dependencies.

- [ ] **Step 4: Verify cache and client behavior.**

  Run: `mix test test/atlas_tracker/trajectory_cache_test.exs test/atlas_tracker/horizons_client_test.exs`
  Expected: zero failures; crash tests do not terminate the cache.

- [ ] **Step 5: Commit the task.**

  Stage the three listed files; review staged diff/status.
  Commit: `git commit -m "Cache trajectory requests with single-flight fetches"`

### Task 4: Async Tracker and Availability UI

**Files:** Modify `lib/atlas_tracker_web/live/tracker_live.ex`, `lib/atlas_tracker_web/components/layouts.ex`, `test/atlas_tracker_web/live/tracker_live_test.exs`.

**Interfaces:**
- Consume Tasks 1–3 APIs. Keep all three existing object IDs, date ranges, labels, and the `SolarSystem` hook unchanged.
- Trajectory tasks: `start_async(socket, {:trajectory, id}, fun)`; evaluation task: `start_async(socket, :wolfram_eval, fun)`.
- Success push: `"trajectory_data"` with `%{id: id, label: label, positions: positions}`.
- Failure push: `"trajectory_error"` with `%{id: id, label: label}` plus an error flash.
- DOM IDs: `tracker`, `trajectory-loading`, `solar-system`, `wolfram-form`, `wolfram-code`, `wolfram-submit`, `wolfram-result`, `kernel-unavailable`, `kernel-warming`, `check-kernel`.
- Layout: add `full_width` boolean attr, default `false`; tracker opts in, existing callers retain their width.

- [ ] **Step 1: Replace the smoke test with offline, selector-based tests.**

  Restore global Req config after every serial test. Use Task 2's fixture in stubs and Task 1's unavailable application worker. Use `assert_push_event`, `render_async`, `has_element?`, `element`, and form helpers, not raw HTML substring assertions.

  Tests and assertions:
  - `"renders the app layout and full-width tracker"`: `#flash-group`, `#tracker`, and `#solar-system[phx-hook='SolarSystem'][phx-update='ignore']` exist; the tracker's layout container lacks `max-w-2xl`.
  - `"unavailable kernel disables evaluation"`: banner and `#check-kernel` exist; both input and submit are disabled. Clicking check again preserves the unavailable state.
  - `"server rejects evaluation when unavailable"`: submit directly through `render_submit(view, "evaluate_wolfram", %{"wolfram" => %{"code" => "40 + 2"}})` to test the server despite disabled controls; assert an unavailable notice and no result.
  - `"loads all trajectories independently"`: assert success events for `3i_atlas`, `1i_oumuamua`, `2i_borisov`, then no `#trajectory-loading`.
  - `"one failed object does not suppress the others"`: stub one command with 500 and two with success; assert one error event, two success events, visible error flash, and loading completed.
  - `"handles invalid successful bodies and async exits"`: exercise missing `result`, non-string `result`, no ephemeris markers, and an exiting fetch; each produces an error event and clears its pending ID.
  - `"updates kernel status live"`: send the worker's status-notification shape to the view; assert warming UI, then ready controls. Stale notifications from another worker must not change the UI.
  - `"preserves form input after failure"`: submitting code updates the form value even when evaluation fails.

  Add focused callback tests using a `Phoenix.LiveView.Socket` with initialized assigns for successful evaluation (`wolfram_result == "42"`), busy/not-ready info flashes, error/exit flashes, and clearing `wolfram_loading`. These exercise outcomes not reachable against the deliberately unavailable app worker without replacing global supervision. Also exercise the trajectory `{:exit, reason}` callback directly; a cache fetch crash is normally normalized to a returned error before reaching LiveView.

- [ ] **Step 2: Establish red for layout, failure, and async paths.**

  Run: `mix test test/atlas_tracker_web/live/tracker_live_test.exs`
  Expected: selector/event failures with current raw forms and message-driven tasks.

- [ ] **Step 3: Modernize the template and async trajectory flow.**

  Begin the template with `<Layouts.app flash={@flash} full_width>`. Add only the optional layout width mode, not a layout redesign. Use fully styled Tailwind input classes and unique IDs.

  Initialize the form as `to_form(%{"code" => "40 + 2"}, as: :wolfram)`. Track `trajectories_pending` as a `MapSet` of IDs, separate from `wolfram_loading`. On connected mount, subscribe to kernel updates and start one cache task per object; disconnected mount does not fetch.

  Handle `{:ok, {:ok, body}}`, `{:ok, {:error, reason}}`, and `{:exit, reason}` in `handle_async/3`. Validate the result field before parsing; route parse errors and malformed bodies through one helper that flashes and pushes the error event. Remove the completed ID on every outcome. Derive loading count from the set.

- [ ] **Step 4: Implement async evaluation and status handling.**

  Handle nested `wolfram` params; preserve the form value. Guard unavailable/warming status on the server as well as disabling controls. Ignore repeat submit events while `wolfram_loading` is true.

  Async success pretty-prints JSON. `:busy` / `:not_ready` use info flashes; other failures and async exits use error flashes. Every completed outcome clears `wolfram_loading`, independently of trajectory loading. Status messages must match the subscribed worker PID.

- [ ] **Step 5: Verify the modernized page offline.**

  Run: `mix test test/atlas_tracker_web/live/tracker_live_test.exs test/atlas_tracker`
  Expected: zero failures; no untagged test calls JPL or starts Wolfram.

- [ ] **Step 6: Commit the task.**

  Stage the three listed files; review staged diff/status.
  Commit: `git commit -m "Modernize tracker async loading and kernel availability UI"`

### Task 5: Static Analysis and CI

**Files:** Modify `mix.exs`, `mix.lock`, `.gitignore`; create `.credo.exs`, `.github/workflows/ci.yml`. Make only verified analysis fixes in existing Elixir files if required.

**Interfaces:**
- Add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` and `{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}`.
- Configure `dialyzer: [plt_file: {:no_warn, "priv/plts/atlas_tracker.plt"}]`; ignore `/priv/plts/`.
- `precommit`: `["compile --warnings-as-errors", "deps.unlock --unused", "format", "credo", "test"]`.

- [ ] **Step 1: Add tooling and inspect task help before use.**

  Set the Elixir requirement to `~> 1.18`, add dependencies/config/ignore, and run `mix deps.get`. Read `mix help credo.gen.config` and `mix help dialyzer`; generate `.credo.exs` with `mix credo.gen.config`.

- [ ] **Step 2: Establish and fix analysis failures.**

  Run `mix credo` and `mix dialyzer`. Record actual failures; fix verified issues without unrelated restructuring. Scope generated/vendor code if needed instead of globally disabling useful checks.
  Expected after fixes: zero Credo issues causing failure and zero Dialyzer warnings.

- [ ] **Step 3: Add two GitHub Actions jobs.**

  Trigger on pushes and pull requests. Both jobs: checkout, `erlef/setup-beam@v1` with Elixir `1.20.5` and OTP `29`, dependency/build cache keyed by OS/toolchain/`mix.lock`, then `mix deps.get`.

  Test job runs, in order: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, `mix test`. Dialyzer job additionally caches `priv/plts` with toolchain/lockfile keys and runs `mix dialyzer`. Preserve default integration-tag exclusions. Do not add credentials or publish anything.

- [ ] **Step 4: Run local equivalents and commit.**

  Run: `mix precommit`, `mix format --check-formatted`, `mix dialyzer`.
  Expected: all exit `0`. CI can only be called green after a user-authorized push and observed runs; local checks are not CI evidence.

  Stage listed files and any narrowly justified analysis fixes; review staged diff/status.
  Commit: `git commit -m "Add Credo Dialyzer and GitHub Actions checks"`

### Task 6: Docker Release and Operator Documentation

**Files:** Create `Dockerfile`, `.dockerignore`, generated `rel/overlays/bin/{server,migrate}` if produced; modify `README.md`. Include other generator output only after reviewing that it is needed.

**Interfaces:**
- Runtime vars: `WOLFRAM_KERNEL_PATH` (optional), `KERNEL_RETRY_MS` (default `30000`), `TRAJECTORY_CACHE_TTL_MS` (default `86400000`), `SECRET_KEY_BASE` (required in prod), `PHX_HOST`, `PORT` (default `4000`), `PHX_SERVER`.
- Runner: `debian:bookworm-slim`, non-root, `PHX_SERVER=true`, `EXPOSE 4000`, `CMD ["/app/bin/atlas_tracker", "start"]`.

- [ ] **Step 1: Generate the release scaffold and make the image reproducible.**

  Read `mix help phx.gen.release`; run `mix phx.gen.release --docker`. Review generated files before accepting them. Use a verified `hexpm/elixir` tag for Elixir 1.20.5 / OTP 29 / bookworm-slim, not a guessed tag. If the exact combination is unavailable, stop and report the incompatibility instead of silently changing the approved versions.

  Keep builder/runner Debian compatibility, required runtime libraries, production-only deps, asset deployment, and a release with no Wolfram installation. Keep vendor assets, including `assets/vendor/three.module.js`, in build context. No npm dependency installation is needed by the current asset bundle.

  `.dockerignore` excludes `.git`, `.worktrees`, `deps`, `_build`, `assets/node_modules`, `priv/static/assets`, `priv/static/cache_manifest.json`, `priv/plts`, `test`, and `docs`; exclude local secret files too. Build assets inside the image.

- [ ] **Step 2: Build and smoke-test the container.**

  Run: `docker build -t atlas_tracker:production-foundations .`.
  Start a uniquely named disposable container with a freshly generated secret passed through an environment variable, `PHX_HOST=localhost`, no kernel path, and a loopback-only published port. Never print the secret or commit it.

  Request `/` with Req and assert HTTP 200, `#kernel-unavailable`, `#solar-system`, and valid bundled JS/CSS responses. Respect existing localhost SSL exclusions; do not disable production SSL protections to make the test pass. Check the runtime user is non-root. Check the container stays up while kernel retries occur, using logs/status or kernel status calls rather than sleeps in tests.

  Where network access permits, use a browser to verify all three trajectories arrive over the live connection; an HTTP-only smoke test does not prove async trajectory success. Stop/remove only the container created for this task.

- [ ] **Step 3: Update README to match the implemented app.**

  Document optional Wolfram setup through `WOLFRAM_KERNEL_PATH`, supported Elixir floor and tested toolchain, automatic loading of all three trajectories, availability behavior, cache/HTTP behavior, and the runtime-var table. Replace the obsolete click-to-fetch instructions and mandatory-kernel wording.

  Include Docker build/run examples, production secret generation without a literal secret, loopback publication for local testing, reverse-proxy/TLS expectations, `mix precommit`, `mix dialyzer`, and opt-in integration commands. Explain that Wolfram is not bundled and CI has separate test/Dialyzer jobs.

- [ ] **Step 4: Run final acceptance checks and commit.**

  Run: `mix precommit`, `mix format --check-formatted`, `mix dialyzer`.
  Expected: all exit `0`; no `Process.sleep/1` or `Process.alive?/1` remains in tests. Review the complete intended diff for scope and preserve all JavaScript/physics code unchanged.

  Run real Wolfram/Horizons integration tests only when their prerequisites are available; otherwise report them skipped. Report Docker and CI checks as unavailable if their tools/services cannot be exercised, never as passing.

  Stage only reviewed release/docs files; review staged diff/status.
  Commit: `git commit -m "Add Docker release and production setup documentation"`

## Execution Handoff

Review the plan before implementation. Choose native execution or subagent-driven execution; do not start application changes before that choice. Recommended: **native**, because the six tasks share lifecycle, configuration, and LiveView interfaces and the approved spec already fixes the architecture.

No PR, push, deployed container, or other external write is authorized by this plan alone.
