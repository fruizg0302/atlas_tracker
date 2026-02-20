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

    # Auto-fetch 3I/ATLAS trajectory on connected mount (avoids double-fetch)
    if connected?(socket) do
      pid = self()

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

      {:ok, assign(socket, :loading, :horizons)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full px-6 py-6">
      <h1 class="text-3xl font-bold mb-6">Atlas Tracker</h1>

      <%!-- Full-width 3D Solar System --%>
      <div class="border rounded-lg p-4 mb-8">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-xl font-semibold">3I/ATLAS Trajectory</h2>
          <%= if @loading == :horizons do %>
            <span class="text-sm text-gray-400 animate-pulse">Loading trajectory...</span>
          <% end %>
        </div>
        <div id="solar-system" phx-hook="SolarSystem" phx-update="ignore" class="w-full">
        </div>
      </div>

      <%!-- Wolfram Panel (below) --%>
      <div class="max-w-2xl border rounded-lg p-6">
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

      <%= if @error do %>
        <div class="mt-6 p-4 bg-red-50 border border-red-200 rounded text-red-800">
          <%= @error %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
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
