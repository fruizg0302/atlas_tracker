# Phase 1: Single-Kernel Prototype — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Phoenix LiveView app with a single Wolfram kernel managed via an Elixir Port, validating the data pipeline: JPL Horizons -> Elixir -> Wolfram -> browser.

**Architecture:** KernelWorker GenServer wraps a long-lived Port to WolframKernel. HorizonsClient fetches data via Req. TrackerLive ties both together in a LiveView page. KernelWorker is supervised under the application tree.

**Tech Stack:** Elixir 1.18.3 / OTP 27, Phoenix LiveView, Req (HTTP), WolframKernel via Port

---

### Task 1: Scaffold Phoenix Project

**Files:**
- Create: entire `atlas_tracker/` Phoenix project structure

**Step 1: Generate Phoenix app**

```bash
cd /Volumes/MacintoshEDD/workspace/PERSONAL
mix phx.new atlas_tracker --live --no-ecto --no-mailer --no-dashboard
```

Select `Y` when prompted. We skip Ecto (no database), mailer, and dashboard — they aren't needed for Phase 1.

**Step 2: Install dependencies**

```bash
cd /Volumes/MacintoshEDD/workspace/PERSONAL/atlas_tracker
mix deps.get
```

**Step 3: Add Req dependency**

Edit `mix.exs`, add to `deps`:

```elixir
{:req, "~> 0.5"}
```

Then run:

```bash
mix deps.get
```

**Step 4: Verify the app compiles and tests pass**

```bash
mix compile
mix test
```

Expected: All default Phoenix tests pass.

**Step 5: Add wolfram_kernel_path to config**

Edit `config/config.exs`, add after the existing config block:

```elixir
config :atlas_tracker,
  wolfram_kernel_path: "/Volumes/MacintoshEDD/Applications/Wolfram.app/Contents/MacOS/WolframKernel"
```

**Step 6: Commit**

```bash
git add -A
git commit -m "Scaffold Phoenix LiveView app with Req dependency"
```

---

### Task 2: KernelWorker GenServer — Core Port Communication

**Files:**
- Create: `lib/atlas_tracker/kernel_worker.ex`
- Create: `test/atlas_tracker/kernel_worker_test.exs`

**Step 1: Write the failing test for basic evaluation**

Create `test/atlas_tracker/kernel_worker_test.exs`:

```elixir
defmodule AtlasTracker.KernelWorkerTest do
  use ExUnit.Case, async: false

  @moduletag :wolfram
  @moduletag timeout: 60_000

  setup do
    worker = start_supervised!(AtlasTracker.KernelWorker)
    # Wait for pre-warm to complete
    Process.sleep(6_000)
    %{worker: worker}
  end

  test "evaluates a simple arithmetic expression", %{worker: worker} do
    assert {:ok, 42} = AtlasTracker.KernelWorker.evaluate(worker, "40 + 2")
  end

  test "evaluates and returns a JSON list", %{worker: worker} do
    assert {:ok, [1, 2, 3]} = AtlasTracker.KernelWorker.evaluate(worker, "{1, 2, 3}")
  end

  test "evaluates and returns a JSON object", %{worker: worker} do
    assert {:ok, %{"a" => 1, "b" => "hello"}} =
             AtlasTracker.KernelWorker.evaluate(worker, "<|\"a\" -> 1, \"b\" -> \"hello\"|>")
  end

  test "returns error for invalid expression", %{worker: worker} do
    assert {:ok, %{"error" => _}} = AtlasTracker.KernelWorker.evaluate(worker, "1/0")
  end
end
```

**Step 2: Run the test to verify it fails**

```bash
mix test test/atlas_tracker/kernel_worker_test.exs --trace
```

Expected: FAIL — module `AtlasTracker.KernelWorker` not found.

**Step 3: Implement KernelWorker**

Create `lib/atlas_tracker/kernel_worker.ex`:

```elixir
defmodule AtlasTracker.KernelWorker do
  use GenServer
  require Logger

  @start_marker "__START__"
  @end_marker "__END__"

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def evaluate(pid, code, timeout \\ 30_000) do
    GenServer.call(pid, {:evaluate, code}, timeout)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    kernel_path = Application.get_env(:atlas_tracker, :wolfram_kernel_path)

    port =
      Port.open(
        {:spawn_executable, kernel_path},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout,
         args: ["-noprompt", "-run"]]
      )

    state = %{
      port: port,
      buffer: "",
      caller: nil,
      status: :initializing
    }

    # Pre-warm the kernel
    send(self(), :pre_warm)
    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate, code}, from, %{status: :ready, caller: nil} = state) do
    send_to_kernel(state.port, code)
    {:noreply, %{state | caller: from, buffer: ""}}
  end

  def handle_call({:evaluate, _code}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:evaluate, _code}, _from, %{caller: caller} = state)
      when caller != nil do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_info(:pre_warm, state) do
    send_to_kernel(state.port, "1 + 1")
    {:noreply, %{state | status: :warming, buffer: ""}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    case extract_result(buffer) do
      {:ok, json_str, _rest} ->
        handle_result(json_str, state)

      :incomplete ->
        {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("WolframKernel exited with status #{status}")

    if state.caller do
      GenServer.reply(state.caller, {:error, :kernel_crashed})
    end

    {:stop, {:kernel_exit, status}, %{state | port: nil, caller: nil}}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp send_to_kernel(port, code) do
    wrapped = """
    WriteString[$Output, "#{@start_marker}\\n"];
    Module[{result},
      result = Quiet[Check[#{code}, $Failed]];
      If[result === $Failed,
        WriteString[$Output, ExportString[<|"error" -> "evaluation failed"|>, "JSON"]],
        WriteString[$Output, ExportString[result, "JSON"]]
      ]
    ];
    WriteString[$Output, "\\n#{@end_marker}\\n"]
    """

    Port.command(port, wrapped)
  end

  defp extract_result(buffer) do
    case {String.contains?(buffer, @start_marker), String.contains?(buffer, @end_marker)} do
      {true, true} ->
        [_before, rest] = String.split(buffer, @start_marker, parts: 2)
        [json_str, remainder] = String.split(rest, @end_marker, parts: 2)
        {:ok, String.trim(json_str), remainder}

      _ ->
        :incomplete
    end
  end

  defp handle_result(json_str, %{status: :warming} = state) do
    case Jason.decode(json_str) do
      {:ok, _result} ->
        Logger.info("WolframKernel pre-warmed successfully")
        {:noreply, %{state | status: :ready, buffer: ""}}

      {:error, _} ->
        Logger.error("Pre-warm failed to parse: #{inspect(json_str)}")
        {:noreply, %{state | status: :ready, buffer: ""}}
    end
  end

  defp handle_result(json_str, %{caller: caller} = state) when caller != nil do
    result =
      case Jason.decode(json_str) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> {:error, :parse_error}
      end

    GenServer.reply(caller, result)
    {:noreply, %{state | caller: nil, buffer: ""}}
  end

  defp handle_result(_json_str, state) do
    {:noreply, %{state | buffer: ""}}
  end
end
```

**Step 4: Run the tests**

```bash
mix test test/atlas_tracker/kernel_worker_test.exs --trace
```

Expected: All 4 tests pass. Note: these tests are slow (6s warmup per test) because each starts a fresh kernel.

**Step 5: Commit**

```bash
git add lib/atlas_tracker/kernel_worker.ex test/atlas_tracker/kernel_worker_test.exs
git commit -m "Add KernelWorker GenServer for Wolfram kernel Port communication"
```

---

### Task 3: Add KernelWorker to Supervision Tree

**Files:**
- Modify: `lib/atlas_tracker/application.ex`

**Step 1: Write a test that the app starts with a named KernelWorker**

Add to `test/atlas_tracker/kernel_worker_test.exs`:

```elixir
  describe "supervised" do
    @tag :skip
    # This test validates the supervision tree starts the worker.
    # Run manually: mix test --only supervised
    @tag :supervised
    test "KernelWorker is started by the application" do
      # Give it time to pre-warm
      Process.sleep(8_000)
      pid = Process.whereis(AtlasTracker.KernelWorker)
      assert is_pid(pid)
      assert {:ok, 42} = AtlasTracker.KernelWorker.evaluate(pid, "40 + 2")
    end
  end
```

**Step 2: Add KernelWorker as a supervised child**

In `lib/atlas_tracker/application.ex`, add `{AtlasTracker.KernelWorker, name: AtlasTracker.KernelWorker}` to the children list, **before** the Endpoint:

```elixir
children = [
  AtlasTrackerWeb.Telemetry,
  {AtlasTracker.KernelWorker, name: AtlasTracker.KernelWorker},
  {DNSCluster, query: Application.get_env(:atlas_tracker, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: AtlasTracker.PubSub},
  # ...existing children...
  AtlasTrackerWeb.Endpoint
]
```

**Step 3: Update KernelWorker.start_link to accept keyword opts**

The `start_link/1` already handles `name:` via `Keyword.take(opts, [:name])`. Verify it works when passed as `{AtlasTracker.KernelWorker, name: AtlasTracker.KernelWorker}` — this calls `start_link([name: AtlasTracker.KernelWorker])`.

Verify:

```bash
mix compile
```

**Step 4: Test the app starts**

```bash
mix test test/atlas_tracker/kernel_worker_test.exs --trace
```

Existing tests should still pass (they start their own worker). The supervised test is tagged `:skip` by default to avoid conflicts.

**Step 5: Commit**

```bash
git add lib/atlas_tracker/application.ex test/atlas_tracker/kernel_worker_test.exs
git commit -m "Add KernelWorker to application supervision tree"
```

---

### Task 4: HorizonsClient — JPL Horizons REST API

**Files:**
- Create: `lib/atlas_tracker/horizons_client.ex`
- Create: `test/atlas_tracker/horizons_client_test.exs`

**Step 1: Write the failing test**

Create `test/atlas_tracker/horizons_client_test.exs`:

```elixir
defmodule AtlasTracker.HorizonsClientTest do
  use ExUnit.Case, async: true

  @moduletag :horizons
  @moduletag timeout: 30_000

  test "fetches state vectors for 3I/ATLAS" do
    result =
      AtlasTracker.HorizonsClient.fetch_state_vectors(
        "C/2025 N1",
        "2025-07-01",
        "2025-08-01",
        "7d"
      )

    assert {:ok, %{"result" => result_str}} = result
    assert is_binary(result_str)
    assert String.contains?(result_str, "$$SOE")
    assert String.contains?(result_str, "$$EOE")
  end

  test "returns error for invalid object" do
    result =
      AtlasTracker.HorizonsClient.fetch_state_vectors(
        "NONEXISTENT/OBJECT",
        "2025-07-01",
        "2025-08-01",
        "7d"
      )

    # Horizons returns 200 with an error message in the result field
    assert {:ok, %{"result" => result_str}} = result
    refute String.contains?(result_str, "$$SOE")
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/atlas_tracker/horizons_client_test.exs --trace
```

Expected: FAIL — module not found.

**Step 3: Implement HorizonsClient**

Create `lib/atlas_tracker/horizons_client.ex`:

```elixir
defmodule AtlasTracker.HorizonsClient do
  @base_url "https://ssd.jpl.nasa.gov/api/horizons.api"

  def fetch_state_vectors(object, start_time, stop_time, step_size) do
    params = %{
      "format" => "json",
      "COMMAND" => "'#{object}'",
      "OBJ_DATA" => "YES",
      "MAKE_EPHEM" => "YES",
      "EPHEM_TYPE" => "VECTORS",
      "CENTER" => "'500@10'",
      "START_TIME" => start_time,
      "STOP_TIME" => stop_time,
      "STEP_SIZE" => step_size,
      "VEC_LABELS" => "YES"
    }

    case Req.get(@base_url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end
end
```

**Step 4: Run test to verify it passes**

```bash
mix test test/atlas_tracker/horizons_client_test.exs --trace
```

Expected: Both tests pass. Note: these hit the live JPL API, so they require internet access.

**Step 5: Commit**

```bash
git add lib/atlas_tracker/horizons_client.ex test/atlas_tracker/horizons_client_test.exs
git commit -m "Add HorizonsClient for JPL Horizons REST API access"
```

---

### Task 5: TrackerLive — LiveView UI

**Files:**
- Create: `lib/atlas_tracker_web/live/tracker_live.ex`
- Modify: `lib/atlas_tracker_web/router.ex`
- Create: `test/atlas_tracker_web/live/tracker_live_test.exs`

**Step 1: Write the failing test**

Create `test/atlas_tracker_web/live/tracker_live_test.exs`:

```elixir
defmodule AtlasTrackerWeb.TrackerLiveTest do
  use AtlasTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag timeout: 60_000

  test "renders the tracker page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Atlas Tracker"
    assert html =~ "Fetch 3I/ATLAS"
    assert html =~ "Evaluate"
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/atlas_tracker_web/live/tracker_live_test.exs --trace
```

Expected: FAIL — no route or module.

**Step 3: Create TrackerLive**

Create `lib/atlas_tracker_web/live/tracker_live.ex`:

```elixir
defmodule AtlasTrackerWeb.TrackerLive do
  use AtlasTrackerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:wolfram_input, "40 + 2")
      |> assign(:wolfram_result, nil)
      |> assign(:horizons_result, nil)
      |> assign(:loading, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <h1 class="text-3xl font-bold mb-8">Atlas Tracker</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
        <%!-- Horizons Panel --%>
        <div class="border rounded-lg p-6">
          <h2 class="text-xl font-semibold mb-4">JPL Horizons</h2>
          <p class="text-sm text-gray-600 mb-4">
            Fetch 3I/ATLAS state vectors (July 2025 – June 2026, weekly)
          </p>
          <button
            phx-click="fetch_horizons"
            disabled={@loading == :horizons}
            class="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:opacity-50"
          >
            <%= if @loading == :horizons, do: "Fetching...", else: "Fetch 3I/ATLAS" %>
          </button>

          <%= if @horizons_result do %>
            <pre class="mt-4 p-4 bg-gray-50 rounded text-xs overflow-auto max-h-96"><%= @horizons_result %></pre>
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
  def handle_info({:horizons_result, {:ok, %{"result" => result}}}, socket) do
    {:noreply, socket |> assign(:horizons_result, result) |> assign(:loading, nil)}
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

**Step 4: Add route**

In `lib/atlas_tracker_web/router.ex`, replace the existing `get "/", PageController, :home` with:

```elixir
live "/", TrackerLive
```

This is inside the existing `scope "/", AtlasTrackerWeb` block that has the `:browser` pipeline.

**Step 5: Run the test**

```bash
mix test test/atlas_tracker_web/live/tracker_live_test.exs --trace
```

Expected: PASS — the page renders with the expected text. Note: this starts the full application (including KernelWorker), so it takes a few seconds.

**Step 6: Commit**

```bash
git add lib/atlas_tracker_web/live/tracker_live.ex lib/atlas_tracker_web/router.ex test/atlas_tracker_web/live/tracker_live_test.exs
git commit -m "Add TrackerLive with Horizons fetch and Wolfram evaluation UI"
```

---

### Task 6: Test Config — Exclude Slow Tags by Default

**Files:**
- Modify: `test/test_helper.exs`

**Step 1: Configure ExUnit to exclude slow tags by default**

Edit `test/test_helper.exs` to add tag exclusions:

```elixir
ExUnit.start(exclude: [:wolfram, :horizons, :supervised])
```

This way `mix test` runs fast (only unit tests), and you explicitly include integration tests:

```bash
mix test --include wolfram      # Wolfram kernel tests
mix test --include horizons     # JPL Horizons API tests
mix test --include wolfram --include horizons  # All integration tests
```

**Step 2: Verify**

```bash
mix test          # Should skip wolfram/horizons tests
mix test --include wolfram --include horizons  # Should run all
```

**Step 3: Remove or update default Phoenix page test**

The generated `test/atlas_tracker_web/controllers/page_controller_test.exs` will fail since we replaced the route. Delete it or update it.

Delete the file if it exists:

```bash
rm -f test/atlas_tracker_web/controllers/page_controller_test.exs
```

Also delete the PageController and its HTML module if they were generated, since TrackerLive replaces them:

```bash
rm -f lib/atlas_tracker_web/controllers/page_controller.ex
rm -f lib/atlas_tracker_web/controllers/page_html.ex
rm -rf lib/atlas_tracker_web/controllers/page_html/
```

**Step 4: Run all tests**

```bash
mix test
mix test --include wolfram --include horizons
```

**Step 5: Commit**

```bash
git add -A
git commit -m "Configure test tags for wolfram/horizons integration tests"
```

---

### Task 7: Manual Smoke Test — End-to-End Validation

**Step 1: Start the Phoenix server**

```bash
mix phx.server
```

**Step 2: Open browser**

Navigate to `http://localhost:4000`

**Step 3: Verify Wolfram evaluation**

- Enter `40 + 2` in the Wolfram input field
- Click "Evaluate"
- Should display `42` after a moment

**Step 4: Verify Horizons fetch**

- Click "Fetch 3I/ATLAS"
- Should display JPL Horizons state vector data after 1-3 seconds

**Step 5: Test vis-viva computation**

Enter this in the Wolfram input:

```
Module[{GM = 1.327*10^20, a = -(1.36 * 1.496*10^11)/(6.08 - 1), r = 1.36 * 1.496*10^11}, Sqrt[GM * (2/r - 1/a)] / 1000]
```

Should return approximately 35 (km/s at perihelion distance — the exact value depends on units).

**Step 6: Success criteria check**

- [x] KernelWorker starts, pre-warms, and evaluates Wolfram expressions
- [x] HorizonsClient fetches 3I/ATLAS state vectors from JPL
- [x] LiveView displays results from both data sources
- [x] Kernel crash triggers automatic restart (kill the kernel process via Activity Monitor and verify it recovers)
