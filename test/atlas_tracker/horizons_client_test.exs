defmodule AtlasTracker.HorizonsClientTest do
  use ExUnit.Case, async: false

  alias AtlasTracker.HorizonsClient

  @fixture File.read!(Path.expand("../fixtures/horizons_success.txt", __DIR__))

  setup do
    previous = Application.fetch_env(:atlas_tracker, :horizons_req_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atlas_tracker, :horizons_req_options, value)
        :error -> Application.delete_env(:atlas_tracker, :horizons_req_options)
      end
    end)

    :ok
  end

  defp stub(fun) do
    Application.put_env(:atlas_tracker, :horizons_req_options,
      plug: fun,
      retry_delay: fn _ -> 0 end,
      retry_log_level: false
    )
  end

  defp fetch do
    HorizonsClient.fetch_state_vectors("C/2025 N1", "2025-07-01", "2025-07-02", "1d")
  end

  test "sends the expected query and returns fixture data" do
    stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["COMMAND"] == "'C/2025 N1'"
      assert conn.query_params["CENTER"] == "'500@10'"
      assert conn.query_params["START_TIME"] == "2025-07-01"
      assert conn.query_params["STOP_TIME"] == "2025-07-02"
      assert conn.query_params["STEP_SIZE"] == "1d"
      Req.Test.json(conn, %{"signature" => %{"version" => "1.2"}, "result" => @fixture})
    end)

    assert {:ok, %{"result" => @fixture}} = fetch()
  end

  test "retries HTTP 500 twice" do
    counter = start_supervised!({Agent, fn -> 0 end})

    stub(fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 500, "unavailable")
    end)

    assert {:error, {:http_error, 500}} = fetch()
    assert Agent.get(counter, & &1) == 3
  end

  test "retries transient failure then succeeds" do
    counter = start_supervised!({Agent, fn -> 0 end})

    stub(fn conn ->
      attempt = Agent.get_and_update(counter, &{&1, &1 + 1})

      if attempt == 0,
        do: Plug.Conn.send_resp(conn, 503, "unavailable"),
        else: Req.Test.json(conn, %{"result" => @fixture})
    end)

    assert {:ok, %{"result" => @fixture}} = fetch()
    assert Agent.get(counter, & &1) == 2
  end

  test "does not retry HTTP 400" do
    counter = start_supervised!({Agent, fn -> 0 end})

    stub(fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    assert {:error, {:http_error, 400}} = fetch()
    assert Agent.get(counter, & &1) == 1
  end

  test "preserves HTTP 200 application error bodies" do
    stub(&Req.Test.json(&1, %{"result" => "No matches found"}))
    assert {:ok, %{"result" => "No matches found"}} = fetch()
  end

  test "returns transport exceptions" do
    stub(&Req.Test.transport_error(&1, :timeout))
    assert {:error, %Req.TransportError{reason: :timeout}} = fetch()
  end

  @tag :horizons
  @tag timeout: 90_000
  test "fetches state vectors for 3I/ATLAS" do
    assert {:ok, %{"result" => result}} = fetch()
    assert String.contains?(result, "$$SOE")
    assert String.contains?(result, "$$EOE")
  end

  @tag :horizons
  @tag timeout: 90_000
  test "returns error for invalid object" do
    assert {:ok, %{"result" => result}} =
             HorizonsClient.fetch_state_vectors(
               "NONEXISTENT/OBJECT",
               "2025-07-01",
               "2025-08-01",
               "7d"
             )

    refute String.contains?(result, "$$SOE")
  end
end
