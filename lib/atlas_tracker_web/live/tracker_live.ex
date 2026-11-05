defmodule AtlasTrackerWeb.TrackerLive do
  use AtlasTrackerWeb, :live_view

  alias AtlasTracker.{KernelWorker, StateVectorParser, TrajectoryCache}

  @interstellar_objects [
    %{
      id: "3i_atlas",
      object: "C/2025 N1",
      start: "2025-07-01",
      stop: "2026-06-01",
      step: "7d",
      label: "3I/ATLAS"
    },
    %{
      id: "1i_oumuamua",
      object: "1I",
      start: "2017-06-01",
      stop: "2018-06-01",
      step: "7d",
      label: "1I/'Oumuamua"
    },
    %{
      id: "2i_borisov",
      object: "2I",
      start: "2019-06-01",
      stop: "2020-06-01",
      step: "7d",
      label: "2I/Borisov"
    }
  ]
  @labels Map.new(@interstellar_objects, &{&1.id, &1.label})

  @impl true
  def mount(_params, _session, socket) do
    worker = Process.whereis(KernelWorker)

    socket =
      socket
      |> assign(
        form: to_form(%{"code" => "40 + 2"}, as: :wolfram),
        wolfram_result: nil,
        wolfram_loading: false,
        kernel_worker: worker,
        kernel_status: KernelWorker.status(worker),
        trajectories_pending: MapSet.new()
      )

    socket =
      if connected?(socket) do
        KernelWorker.subscribe(self(), worker)
        pending = MapSet.new(@interstellar_objects, & &1.id)

        Enum.reduce(@interstellar_objects, assign(socket, :trajectories_pending, pending), fn obj,
                                                                                              socket ->
          start_async(socket, {:trajectory, obj.id}, fn ->
            TrajectoryCache.fetch(obj.object, obj.start, obj.stop, obj.step)
          end)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} full_width>
      <div id="tracker" class="w-full space-y-8">
        <h1 class="text-3xl font-bold tracking-tight">Atlas Tracker</h1>

        <section class="rounded-xl border border-slate-500/20 p-4 sm:p-6">
          <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-xl font-semibold">Interstellar Visitors</h2>
            <span
              :if={MapSet.size(@trajectories_pending) > 0}
              id="trajectory-loading"
              role="status"
              class="animate-pulse text-sm text-slate-500"
            >
              Loading trajectories ({MapSet.size(@trajectories_pending)} remaining)...
            </span>
          </div>
          <div id="solar-system" phx-hook="SolarSystem" phx-update="ignore" class="w-full"></div>
        </section>

        <section class="max-w-2xl rounded-xl border border-slate-500/20 p-6">
          <h2 class="mb-4 text-xl font-semibold">Wolfram Kernel</h2>
          <div
            :if={@kernel_status == :unavailable}
            id="kernel-unavailable"
            role="status"
            class="mb-5 rounded-lg border border-amber-400/30 bg-amber-400/10 p-4 text-sm"
          >
            <p>Wolfram kernel unavailable, the rest of the app works without it.</p>
            <button
              id="check-kernel"
              type="button"
              phx-click="check_kernel"
              class="mt-3 rounded-md border border-amber-500/40 px-3 py-1.5 font-medium transition hover:bg-amber-400/15"
            >
              Check again
            </button>
          </div>
          <p
            :if={@kernel_status == :warming}
            id="kernel-warming"
            role="status"
            class="mb-4 text-sm text-slate-500"
          >
            Kernel starting…
          </p>

          <.form for={@form} id="wolfram-form" phx-submit="evaluate_wolfram" class="space-y-3">
            <.input
              field={@form[:code]}
              id="wolfram-code"
              label="Wolfram expression"
              type="text"
              disabled={@kernel_status != :ready or @wolfram_loading}
              class="w-full rounded-lg border border-slate-500/30 bg-transparent px-3 py-2 font-mono text-sm outline-none transition focus:border-emerald-500 focus:ring-2 focus:ring-emerald-500/20 disabled:cursor-not-allowed disabled:opacity-50"
            />
            <button
              id="wolfram-submit"
              type="submit"
              disabled={@kernel_status != :ready or @wolfram_loading}
              class="rounded-lg bg-emerald-600 px-4 py-2 font-medium text-white transition hover:bg-emerald-700 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {if @wolfram_loading, do: "Evaluating...", else: "Evaluate"}
            </button>
          </.form>
          <pre
            :if={@wolfram_result}
            id="wolfram-result"
            class="mt-4 max-h-96 overflow-auto rounded-lg bg-slate-500/10 p-4 text-xs"
          >{@wolfram_result}</pre>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("check_kernel", _, socket) do
    {:noreply, assign(socket, :kernel_status, KernelWorker.status(socket.assigns.kernel_worker))}
  end

  def handle_event("evaluate_wolfram", _, %{assigns: %{wolfram_loading: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("evaluate_wolfram", %{"wolfram" => %{"code" => code}}, socket) do
    socket = assign(socket, :form, to_form(%{"code" => code}, as: :wolfram))

    socket =
      case socket.assigns.kernel_status do
        :ready ->
          worker = socket.assigns.kernel_worker

          socket
          |> assign(:wolfram_loading, true)
          |> start_async(:wolfram_eval, fn -> KernelWorker.evaluate(worker, code) end)

        :warming ->
          put_flash(socket, :info, "Wolfram kernel is still starting. Please try again shortly.")

        :unavailable ->
          put_flash(
            socket,
            :error,
            "Wolfram kernel unavailable. Trajectories still work without it."
          )
      end

    {:noreply, socket}
  end

  @impl true
  def handle_async({:trajectory, id}, outcome, socket) do
    socket =
      case outcome do
        {:ok, {:ok, %{"result" => text}}} when is_binary(text) ->
          case StateVectorParser.parse(text) do
            {:ok, positions} ->
              push_event(socket, "trajectory_data", %{
                id: id,
                label: Map.fetch!(@labels, id),
                positions: positions
              })

            {:error, reason} ->
              trajectory_error(socket, id, reason)
          end

        {:ok, {:error, reason}} ->
          trajectory_error(socket, id, reason)

        {:exit, reason} ->
          trajectory_error(socket, id, reason)

        _ ->
          trajectory_error(socket, id, :invalid_response)
      end

    {:noreply, update(socket, :trajectories_pending, &MapSet.delete(&1, id))}
  end

  def handle_async(:wolfram_eval, {:ok, {:ok, result}}, socket) do
    {:noreply,
     assign(socket, wolfram_result: Jason.encode!(result, pretty: true), wolfram_loading: false)}
  end

  def handle_async(:wolfram_eval, {:ok, {:error, reason}}, socket)
      when reason in [:busy, :not_ready] do
    {:noreply,
     socket
     |> assign(:wolfram_loading, false)
     |> put_flash(:info, "Wolfram kernel is busy or still starting. Please try again shortly.")}
  end

  def handle_async(:wolfram_eval, outcome, socket) do
    reason =
      case outcome do
        {:ok, {:error, reason}} -> reason
        {:exit, reason} -> reason
      end

    {:noreply,
     socket
     |> assign(:wolfram_loading, false)
     |> put_flash(:error, "Wolfram error: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:kernel_status, worker, status}, %{assigns: %{kernel_worker: worker}} = socket) do
    {:noreply, assign(socket, :kernel_status, status)}
  end

  def handle_info({:kernel_status, _, _}, socket), do: {:noreply, socket}

  defp trajectory_error(socket, id, reason) do
    label = Map.fetch!(@labels, id)

    socket
    |> put_flash(:error, "Horizons error for #{label}: #{inspect(reason)}")
    |> push_event("trajectory_error", %{id: id, label: label})
  end
end
