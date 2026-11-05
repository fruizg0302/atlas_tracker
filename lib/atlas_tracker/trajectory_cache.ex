defmodule AtlasTracker.TrajectoryCache do
  @moduledoc """
  Caches Horizons responses with a monotonic TTL and one fetch per pending key.
  """
  use GenServer

  alias AtlasTracker.HorizonsClient

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def fetch(object, start, stop, step, opts \\ []) do
    key = {object, start, stop, step}
    table = Keyword.get(opts, :table, __MODULE__)

    case lookup(table, key) do
      {:ok, body} ->
        count_event(:hit, key)
        {:ok, body}

      :miss ->
        count_event(:miss, key)
        GenServer.call(Keyword.get(opts, :server, __MODULE__), {:fetch, key}, 60_000)
    end
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, __MODULE__)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    {:ok,
     %{
       table: table,
       ttl_ms:
         Keyword.get(
           opts,
           :ttl_ms,
           Application.get_env(:atlas_tracker, :trajectory_cache_ttl_ms, 86_400_000)
         ),
       fetch_fun: Keyword.get(opts, :fetch_fun, &HorizonsClient.fetch_state_vectors/4),
       pending: %{},
       jobs: %{}
     }}
  end

  @impl true
  def handle_call({:fetch, key}, from, state) do
    case lookup(state.table, key) do
      {:ok, body} ->
        {:reply, {:ok, body}, state}

      :miss ->
        if Map.has_key?(state.pending, key) do
          {:noreply, update_in(state.pending[key], &[from | &1])}
        else
          {:noreply, start_fetch(state, key, from)}
        end
    end
  end

  @impl true
  def handle_info({:fetch_result, ref, result}, state) when is_map_key(state.jobs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_fetch(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) when is_map_key(state.jobs, ref) do
    {:noreply, finish_fetch(state, ref, {:error, :fetch_crashed})}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.jobs, fn {_, job} -> Process.exit(job.pid, :shutdown) end)
  end

  defp start_fetch(state, key, from) do
    owner = self()
    fetch_fun = state.fetch_fun

    {:ok, pid} =
      Task.start(fn ->
        receive do
          {:run, ref} ->
            result = apply(fetch_fun, Tuple.to_list(key))
            send(owner, {:fetch_result, ref, result})
        end
      end)

    ref = Process.monitor(pid)
    job = %{key: key, pid: pid, started: System.monotonic_time()}
    send(pid, {:run, ref})

    %{state | jobs: Map.put(state.jobs, ref, job), pending: Map.put(state.pending, key, [from])}
  end

  defp finish_fetch(state, ref, result) do
    {job, jobs} = Map.pop(state.jobs, ref)
    {waiters, pending} = Map.pop(state.pending, job.key)
    now = System.monotonic_time(:millisecond)

    case result do
      {:ok, body} ->
        :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
        :ets.insert(state.table, {job.key, body, now + state.ttl_ms})

      {:error, _} ->
        :ok
    end

    Enum.each(waiters, &GenServer.reply(&1, result))

    :telemetry.execute(
      [:atlas_tracker, :trajectory_cache, :fetch],
      %{duration: System.monotonic_time() - job.started},
      %{key: job.key, result: elem(result, 0)}
    )

    %{state | jobs: jobs, pending: pending}
  end

  defp lookup(table, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, body, expires}] when expires > now -> {:ok, body}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp count_event(kind, key) do
    :telemetry.execute([:atlas_tracker, :trajectory_cache, kind], %{count: 1}, %{key: key})
  end
end
