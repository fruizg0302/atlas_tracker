defmodule AtlasTracker.KernelWorkerTest do
  use ExUnit.Case, async: true

  alias AtlasTracker.KernelWorker

  @moduletag :tmp_dir
  @fake Path.expand("../support/fake_kernel.sh", __DIR__)

  defp ready_worker(opts \\ []) do
    worker =
      start_supervised!({KernelWorker, Keyword.merge([kernel_path: @fake, notify: self()], opts)})

    assert_receive {:kernel_status, ^worker, :warming}
    assert_receive {:kernel_status, ^worker, :ready}, 2_000
    worker
  end

  test "notifies warming then ready" do
    worker = ready_worker()
    assert KernelWorker.status(worker) == :ready
  end

  test "returns decoded results and Wolfram error objects" do
    worker = ready_worker()
    assert {:ok, 42} = KernelWorker.evaluate(worker, "40 + 2")
    assert {:ok, 2} = KernelWorker.evaluate(worker, "1 + 1")
    assert {:ok, %{"error" => "evaluation failed"}} = KernelWorker.evaluate(worker, "fail_me")
  end

  test "rejects a second evaluation" do
    worker = ready_worker()
    :gen_server.send_request(worker, {:evaluate, "hold_me"})
    _ = :sys.get_state(worker)
    assert {:error, :busy} = KernelWorker.evaluate(worker, "40 + 2")
  end

  test "rejects evaluation while warming", %{tmp_dir: dir} do
    path = Path.join(dir, "warming")
    File.write!(path, "#!/bin/sh\nwhile IFS= read -r line; do :; done\n")
    File.chmod!(path, 0o755)
    worker = start_supervised!({KernelWorker, kernel_path: path, notify: self()})
    assert_receive {:kernel_status, ^worker, :warming}
    assert {:error, :not_ready} = KernelWorker.evaluate(worker, "40 + 2")
  end

  test "normalizes invalid JSON and remains usable" do
    worker = ready_worker()
    assert {:error, :parse_error} = KernelWorker.evaluate(worker, "bad_json")
    assert {:ok, 42} = KernelWorker.evaluate(worker, "40 + 2")
  end

  test "boots unavailable for missing configuration, bad paths, and non-executable files", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "not-executable")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o644)

    for {path, id} <- Enum.with_index([nil, Path.join(dir, "absent"), path]) do
      worker = start_supervised!({KernelWorker, kernel_path: path, notify: self()}, id: id)
      assert_receive {:kernel_status, ^worker, :unavailable}
      assert {:error, :unavailable} = KernelWorker.evaluate(worker, "40 + 2")
    end
  end

  test "survives an executable that exits" do
    worker = start_supervised!({KernelWorker, kernel_path: "/bin/false", notify: self()})
    assert_receive {:kernel_status, ^worker, :unavailable}, 2_000
    assert KernelWorker.status(worker) == :unavailable
  end

  test "releases an in-flight caller when the port exits" do
    worker = ready_worker()
    assert {:error, :kernel_crashed} = KernelWorker.evaluate(worker, "exit_me")
    assert_receive {:kernel_status, ^worker, :unavailable}
    assert KernelWorker.status(worker) == :unavailable
  end

  test "ignores stale port messages and handles a closed-port write" do
    worker = ready_worker(retry_ms: 50)
    port = :sys.get_state(worker).port
    :ok = :sys.suspend(worker)
    request = :gen_server.send_request(worker, {:evaluate, "40 + 2"})
    Port.close(port)
    :ok = :sys.resume(worker)
    assert {:reply, {:error, :kernel_crashed}} = :gen_server.wait_response(request, 2_000)
    assert_receive {:kernel_status, ^worker, :unavailable}
    assert_receive {:kernel_status, ^worker, :ready}, 2_000
    send(worker, {port, {:data, "__START__\n999\n__END__\n"}})
    send(worker, {port, {:exit_status, 1}})
    assert {:ok, 42} = KernelWorker.evaluate(worker, "40 + 2")
  end

  test "reassembles split frames" do
    worker = ready_worker()
    request = :gen_server.send_request(worker, {:evaluate, "hold_me"})
    port = :sys.get_state(worker).port

    for chunk <- ["noise__STA", "RT__\n{\"value\":", "42}\n__EN", "D__\n"] do
      send(worker, {port, {:data, chunk}})
    end

    assert {:reply, {:ok, %{"value" => 42}}} = :gen_server.wait_response(request, 2_000)
    assert {:ok, 42} = KernelWorker.evaluate(worker, "40 + 2")
  end

  test "heals when a kernel appears", %{tmp_dir: dir} do
    path = Path.join(dir, "kernel")
    worker = start_supervised!({KernelWorker, kernel_path: path, retry_ms: 50, notify: self()})
    assert_receive {:kernel_status, ^worker, :unavailable}
    File.cp!(@fake, path)
    File.chmod!(path, 0o755)
    assert_receive {:kernel_status, ^worker, :ready}, 5_000
    assert {:ok, 42} = KernelWorker.evaluate(worker, "40 + 2")
  end

  test "subscribes immediately and removes dead subscribers" do
    worker = ready_worker()
    assert :ok = KernelWorker.subscribe(self(), worker)
    assert_receive {:kernel_status, ^worker, :ready}
    subscriber = start_supervised!({Agent, fn -> nil end})
    assert :ok = KernelWorker.subscribe(subscriber, worker)
    ref = Process.monitor(subscriber)
    stop_supervised!(Agent)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :shutdown}
    _ = :sys.get_state(worker)
    refute Map.has_key?(:sys.get_state(worker).subscribers, subscriber)
    assert {:error, :kernel_crashed} = KernelWorker.evaluate(worker, "exit_me")
    assert_receive {:kernel_status, ^worker, :unavailable}
  end
end
