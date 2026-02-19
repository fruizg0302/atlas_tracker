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
