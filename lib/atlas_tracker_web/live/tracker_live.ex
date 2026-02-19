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
