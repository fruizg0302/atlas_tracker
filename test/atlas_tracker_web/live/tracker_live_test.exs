defmodule AtlasTrackerWeb.TrackerLiveTest do
  use AtlasTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AtlasTracker.KernelWorker
  alias AtlasTrackerWeb.TrackerLive

  @fixture File.read!(Path.expand("../../fixtures/horizons_success.txt", __DIR__))
  @ids ~w(3i_atlas 1i_oumuamua 2i_borisov)
  @moduletag :capture_log

  setup do
    previous = Application.fetch_env(:atlas_tracker, :horizons_req_options)
    stub(&Req.Test.json(&1, %{"result" => @fixture}))

    application_worker = Process.whereis(KernelWorker)
    Process.unregister(KernelWorker)

    on_exit(fn -> Process.register(application_worker, KernelWorker) end)

    worker =
      start_supervised!(
        {KernelWorker,
         name: KernelWorker, kernel_path: "/nonexistent/wolfram/kernel", retry_ms: 60_000}
      )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atlas_tracker, :horizons_req_options, value)
        :error -> Application.delete_env(:atlas_tracker, :horizons_req_options)
      end
    end)

    %{worker: worker}
  end

  defp stub(fun) do
    Application.put_env(:atlas_tracker, :horizons_req_options,
      plug: fun,
      retry_delay: fn _ -> 0 end,
      retry_log_level: false
    )
  end

  defp open(conn) do
    {:ok, view, _} = live(conn, "/")
    render_async(view, 2_000)
    view
  end

  test "renders the app layout and full-width tracker", %{conn: conn} do
    view = open(conn)
    assert has_element?(view, "#flash-group")
    assert has_element?(view, "#tracker")
    assert has_element?(view, "#app-content:not(.max-w-2xl)")
    assert has_element?(view, "#solar-system[phx-hook='SolarSystem'][phx-update='ignore']")
  end

  test "unavailable kernel disables evaluation", %{conn: conn} do
    view = open(conn)
    assert has_element?(view, "#kernel-unavailable")
    assert has_element?(view, "#wolfram-code[disabled]")
    assert has_element?(view, "#wolfram-submit[disabled]")
    view |> element("#check-kernel") |> render_click()
    assert has_element?(view, "#kernel-unavailable")
  end

  test "server rejects evaluation when unavailable and preserves form input", %{conn: conn} do
    view = open(conn)
    render_submit(view, "evaluate_wolfram", %{"wolfram" => %{"code" => "123 + 4"}})
    render_async(view)
    assert has_element?(view, "#flash-error", "unavailable")
    assert has_element?(view, "#wolfram-code[value='123 + 4']")
    refute has_element?(view, "#wolfram-result")
  end

  test "loads all trajectories independently", %{conn: conn} do
    view = open(conn)

    for id <- @ids do
      assert_push_event(view, "trajectory_data", %{id: ^id, positions: [_, _]})
    end

    refute has_element?(view, "#trajectory-loading")
  end

  test "one failed object does not suppress the others", %{conn: conn} do
    stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["COMMAND"] == "'C/2025 N1'" do
        Plug.Conn.send_resp(conn, 500, "unavailable")
      else
        Req.Test.json(conn, %{"result" => @fixture})
      end
    end)

    view = open(conn)
    assert_push_event(view, "trajectory_error", %{id: "3i_atlas"})
    assert_push_event(view, "trajectory_data", %{id: "1i_oumuamua"})
    assert_push_event(view, "trajectory_data", %{id: "2i_borisov"})
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#trajectory-loading")
  end

  for {name, body} <- [
        {"missing result", %{}},
        {"non-string result", %{"result" => nil}},
        {"no ephemeris", %{"result" => "No matches found"}}
      ] do
    test "finishes loading for #{name}", %{conn: conn} do
      body = unquote(Macro.escape(body))
      stub(&Req.Test.json(&1, body))
      view = open(conn)
      for id <- @ids, do: assert_push_event(view, "trajectory_error", %{id: ^id})
      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#trajectory-loading")
    end
  end

  test "finishes loading when a cache fetch crashes", %{conn: conn} do
    stub(fn _ -> exit(:broken_fetch) end)
    view = open(conn)
    for id <- @ids, do: assert_push_event(view, "trajectory_error", %{id: ^id})
    refute has_element?(view, "#trajectory-loading")
  end

  test "updates kernel status live and ignores other workers", %{conn: conn} do
    view = open(conn)
    worker = Process.whereis(KernelWorker)
    send(view.pid, {:kernel_status, worker, :warming})
    assert has_element?(view, "#kernel-warming")
    send(view.pid, {:kernel_status, worker, :ready})
    assert has_element?(view, "#wolfram-submit:not([disabled])")
    send(view.pid, {:kernel_status, self(), :unavailable})
    refute has_element?(view, "#kernel-unavailable")
  end

  test "worker termination disables evaluation and check again survives absence", %{conn: conn} do
    stop_supervised!(KernelWorker)
    worker = start_ready_kernel()
    view = open(conn)
    assert has_element?(view, "#wolfram-submit:not([disabled])")

    ref = Process.monitor(worker)
    stop_supervised!(KernelWorker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert has_element?(view, "#kernel-unavailable")
    assert has_element?(view, "#wolfram-submit[disabled]")
    view |> element("#check-kernel") |> render_click()
    assert has_element?(view, "#kernel-unavailable")

    replacement = start_ready_kernel()
    send(view.pid, :reconnect_kernel)
    assert has_element?(view, "#wolfram-submit:not([disabled])")
    send(view.pid, {:kernel_status, worker, :unavailable})
    refute has_element?(view, "#kernel-unavailable")
    send(view.pid, {:kernel_status, replacement, :warming})
    assert has_element?(view, "#kernel-warming")
  end

  test "mount tolerates an absent worker and reconnects when it starts", %{conn: conn} do
    stop_supervised!(KernelWorker)
    view = open(conn)
    assert has_element?(view, "#kernel-unavailable")
    view |> element("#check-kernel") |> render_click()
    start_ready_kernel()
    send(view.pid, :reconnect_kernel)
    assert has_element?(view, "#wolfram-submit:not([disabled])")
  end

  defp start_ready_kernel do
    worker =
      start_supervised!(
        {KernelWorker,
         name: KernelWorker,
         kernel_path: Path.expand("../../support/fake_kernel.sh", __DIR__),
         notify: self()}
      )

    assert_receive {:kernel_status, ^worker, :ready}, 2_000
    worker
  end

  defp socket(assigns \\ %{}) do
    Phoenix.Component.assign(
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}},
      Map.merge(
        %{
          wolfram_loading: true,
          wolfram_result: nil,
          trajectories_pending: MapSet.new(["3i_atlas"])
        },
        assigns
      )
    )
  end

  test "evaluation success clears only its own loading state" do
    {:noreply, result} = TrackerLive.handle_async(:wolfram_eval, {:ok, {:ok, 42}}, socket())
    assert result.assigns.wolfram_result == "42"
    refute result.assigns.wolfram_loading
    assert result.assigns.trajectories_pending == MapSet.new(["3i_atlas"])
  end

  for reason <- [:busy, :not_ready] do
    test "evaluation #{reason} is an info notice" do
      {:noreply, result} =
        TrackerLive.handle_async(:wolfram_eval, {:ok, {:error, unquote(reason)}}, socket())

      assert Phoenix.Flash.get(result.assigns.flash, :info)
      refute result.assigns.wolfram_loading
    end
  end

  for outcome <- [{:ok, {:error, :kernel_crashed}}, {:exit, :evaluation_crashed}] do
    test "evaluation failure #{inspect(outcome)} clears loading" do
      {:noreply, result} =
        TrackerLive.handle_async(:wolfram_eval, unquote(Macro.escape(outcome)), socket())

      assert Phoenix.Flash.get(result.assigns.flash, :error)
      refute result.assigns.wolfram_loading
    end
  end

  test "trajectory task exit clears its pending ID" do
    {:noreply, result} =
      TrackerLive.handle_async({:trajectory, "3i_atlas"}, {:exit, :failed}, socket())

    assert result.assigns.trajectories_pending == MapSet.new()
    assert Phoenix.Flash.get(result.assigns.flash, :error)
  end

  test "repeat evaluation submissions do not start another task" do
    original = socket()

    assert {:noreply, ^original} =
             TrackerLive.handle_event(
               "evaluate_wolfram",
               %{"wolfram" => %{"code" => "123"}},
               original
             )
  end
end
