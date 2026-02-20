defmodule AtlasTrackerWeb.TrackerLive do
  use AtlasTrackerWeb, :live_view

  alias AtlasTracker.StateVectorParser

  # Interstellar objects to fetch from JPL Horizons
  @interstellar_objects [
    %{id: "3i_atlas",   object: "C/2025 N1",  start: "2025-07-01", stop: "2026-06-01", step: "7d", label: "3I/ATLAS"},
    %{id: "1i_oumuamua", object: "1I",         start: "2017-06-01", stop: "2018-06-01", step: "7d", label: "1I/'Oumuamua"},
    %{id: "2i_borisov",  object: "2I",         start: "2019-06-01", stop: "2020-06-01", step: "7d", label: "2I/Borisov"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:wolfram_input, "40 + 2")
      |> assign(:wolfram_result, nil)
      |> assign(:loading, nil)
      |> assign(:error, nil)
      |> assign(:trajectories_pending, 0)

    # Auto-fetch all interstellar trajectories on connected mount
    if connected?(socket) do
      pid = self()

      for obj <- @interstellar_objects do
        Task.start(fn ->
          result =
            AtlasTracker.HorizonsClient.fetch_state_vectors(
              obj.object,
              obj.start,
              obj.stop,
              obj.step
            )

          send(pid, {:trajectory_result, obj.id, obj.label, result})
        end)
      end

      {:ok, assign(socket, loading: :horizons, trajectories_pending: length(@interstellar_objects))}
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
          <h2 class="text-xl font-semibold">Interstellar Visitors</h2>
          <%= if @loading == :horizons do %>
            <span class="text-sm text-gray-400 animate-pulse">Loading trajectories (<%= @trajectories_pending %> remaining)...</span>
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
  def handle_info({:trajectory_result, id, label, {:ok, %{"result" => result_text}}}, socket) do
    pending = socket.assigns.trajectories_pending - 1

    socket =
      case StateVectorParser.parse(result_text) do
        {:ok, positions} ->
          socket
          |> push_event("trajectory_data", %{id: id, label: label, positions: positions})

        {:error, _reason} ->
          assign(socket, :error, "Failed to parse #{label} trajectory data")
      end

    loading = if pending <= 0, do: nil, else: :horizons
    {:noreply, assign(socket, loading: loading, trajectories_pending: pending)}
  end

  def handle_info({:trajectory_result, _id, label, {:error, reason}}, socket) do
    pending = socket.assigns.trajectories_pending - 1
    loading = if pending <= 0, do: nil, else: :horizons

    {:noreply,
     socket
     |> assign(:error, "Horizons error for #{label}: #{inspect(reason)}")
     |> assign(loading: loading, trajectories_pending: pending)}
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
