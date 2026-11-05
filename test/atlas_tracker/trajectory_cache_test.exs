defmodule AtlasTracker.TrajectoryCacheTest do
  use ExUnit.Case, async: true

  alias AtlasTracker.TrajectoryCache

  @moduletag :capture_log
  @table :trajectory_cache_unit_table
  @key {"object", "start", "stop", "7d"}
  @body %{"result" => File.read!(Path.expand("../fixtures/horizons_success.txt", __DIR__))}

  setup do
    counter = start_supervised!({Agent, fn -> 0 end})
    %{counter: counter}
  end

  defp cache(counter, opts \\ [], fun \\ fn _, _, _, _ -> {:ok, @body} end) do
    fetch = fn a, b, c, d ->
      Agent.update(counter, &(&1 + 1))
      fun.(a, b, c, d)
    end

    server =
      start_supervised!(
        {TrajectoryCache,
         Keyword.merge(
           [name: :trajectory_cache_unit, table: @table, ttl_ms: 60_000, fetch_fun: fetch],
           opts
         )}
      )

    {server, [server: server, table: @table]}
  end

  defp fetch(opts, {a, b, c, d} \\ @key), do: TrajectoryCache.fetch(a, b, c, d, opts)

  test "miss then hit", %{counter: counter} do
    {_, opts} = cache(counter)
    assert {:ok, @body} = fetch(opts)
    assert {:ok, @body} = fetch(opts)
    assert Agent.get(counter, & &1) == 1
  end

  test "keys include all query fields", %{counter: counter} do
    {_, opts} = cache(counter)

    for key <- [
          @key,
          {"other", "start", "stop", "7d"},
          {"object", "other", "stop", "7d"},
          {"object", "start", "other", "7d"},
          {"object", "start", "stop", "1d"}
        ] do
      assert {:ok, _} = fetch(opts, key)
    end

    assert Agent.get(counter, & &1) == 5
  end

  test "zero TTL never caches", %{counter: counter} do
    {_, opts} = cache(counter, ttl_ms: 0)
    assert {:ok, _} = fetch(opts)
    assert {:ok, _} = fetch(opts)
    assert Agent.get(counter, & &1) == 2
  end

  test "expired entries are swept on insert", %{counter: counter} do
    {_, opts} = cache(counter)
    :ets.insert(@table, {:old, :body, System.monotonic_time(:millisecond) - 1})
    assert {:ok, _} = fetch(opts)
    assert :ets.lookup(@table, :old) == []
  end

  test "single flight shares one result", %{counter: counter} do
    parent = self()

    {server, _} =
      cache(counter, [], fn _, _, _, _ ->
        send(parent, {:fetch_started, self()})

        receive do
          :release -> {:ok, "shared"}
        end
      end)

    first = :gen_server.send_request(server, {:fetch, @key})
    second = :gen_server.send_request(server, {:fetch, @key})
    _ = :sys.get_state(server)
    assert_receive {:fetch_started, task}
    send(task, :release)
    assert {:reply, {:ok, "shared"}} = :gen_server.wait_response(first, 2_000)
    assert {:reply, {:ok, "shared"}} = :gen_server.wait_response(second, 2_000)
    assert Agent.get(counter, & &1) == 1
  end

  test "different keys fetch independently", %{counter: counter} do
    parent = self()

    {server, opts} =
      cache(counter, [], fn object, _, _, _ ->
        if object == "object" do
          send(parent, {:fetch_started, self()})

          receive do
            :release -> {:ok, "held"}
          end
        else
          {:ok, "independent"}
        end
      end)

    first = :gen_server.send_request(server, {:fetch, @key})
    assert_receive {:fetch_started, task}
    assert {:ok, "independent"} = fetch(opts, {"other", "start", "stop", "7d"})
    send(task, :release)
    assert {:reply, {:ok, "held"}} = :gen_server.wait_response(first, 2_000)
  end

  test "failures are not cached", %{counter: counter} do
    {_, opts} = cache(counter, [], fn _, _, _, _ -> {:error, :bad_gateway} end)
    assert {:error, :bad_gateway} = fetch(opts)
    assert {:error, :bad_gateway} = fetch(opts)
    assert Agent.get(counter, & &1) == 2
  end

  for {name, body} <- [
        {"application error", %{"error" => "temporarily unavailable"}},
        {"missing result", %{}},
        {"non-string result", %{"result" => nil}},
        {"no ephemeris", %{"result" => "No matches found"}},
        {"empty ephemeris", %{"result" => "$$SOE\n$$EOE"}}
      ] do
    test "#{name} does not prevent a recovered response from being cached", %{counter: counter} do
      invalid = unquote(Macro.escape(body))

      {_, opts} =
        cache(counter, [], fn _, _, _, _ ->
          {:ok, if(Agent.get(counter, & &1) == 1, do: invalid, else: @body)}
        end)

      assert {:ok, ^invalid} = fetch(opts)
      assert {:ok, @body} = fetch(opts)
      assert {:ok, @body} = fetch(opts)
      assert Agent.get(counter, & &1) == 2
    end
  end

  test "fetch crash releases all waiters and allows retry", %{counter: counter} do
    parent = self()

    {server, opts} =
      cache(counter, [], fn _, _, _, _ ->
        if Agent.get(counter, & &1) == 1 do
          send(parent, {:fetch_started, self()})

          receive do
            :release -> exit(:fetch_failed)
          end
        else
          {:ok, "recovered"}
        end
      end)

    first = :gen_server.send_request(server, {:fetch, @key})
    second = :gen_server.send_request(server, {:fetch, @key})
    _ = :sys.get_state(server)
    assert_receive {:fetch_started, task}
    send(task, :release)
    assert {:reply, {:error, :fetch_crashed}} = :gen_server.wait_response(first, 2_000)
    assert {:reply, {:error, :fetch_crashed}} = :gen_server.wait_response(second, 2_000)
    assert {:ok, "recovered"} = fetch(opts)
  end

  test "late callers reuse a completed value", %{counter: counter} do
    {server, opts} = cache(counter)
    assert {:ok, _} = fetch(opts)
    assert {:ok, _} = GenServer.call(server, {:fetch, @key})
    assert Agent.get(counter, & &1) == 1
  end

  test "missing fast-path table falls back to the server", %{counter: counter} do
    {_, opts} = cache(counter)
    assert {:ok, _} = fetch(Keyword.put(opts, :table, :missing_trajectory_table))
  end

  test "emits telemetry", %{counter: counter} do
    id = make_ref()
    events = for kind <- [:hit, :miss, :fetch], do: [:atlas_tracker, :trajectory_cache, kind]

    :telemetry.attach_many(
      id,
      events,
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    {_, opts} = cache(counter)
    assert {:ok, _} = fetch(opts)
    assert {:ok, _} = fetch(opts)
    assert_receive {:telemetry, [:atlas_tracker, :trajectory_cache, :miss], %{count: 1}, _}
    assert_receive {:telemetry, [:atlas_tracker, :trajectory_cache, :hit], %{count: 1}, _}

    assert_receive {:telemetry, [:atlas_tracker, :trajectory_cache, :fetch],
                    %{duration: duration}, %{result: :ok}}

    assert duration >= 0
  end
end
