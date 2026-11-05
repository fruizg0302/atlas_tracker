defmodule AtlasTracker.KernelWorkerIntegrationTest do
  use ExUnit.Case, async: true

  alias AtlasTracker.KernelWorker

  @moduletag :wolfram
  @moduletag timeout: 60_000

  setup do
    path = System.fetch_env!("WOLFRAM_KERNEL_PATH")
    worker = start_supervised!({KernelWorker, kernel_path: path, notify: self()})
    assert_receive {:kernel_status, ^worker, :ready}, 30_000
    %{worker: worker}
  end

  test "evaluates arithmetic", %{worker: worker} do
    assert {:ok, 42} = KernelWorker.evaluate(worker, "40 + 2")
  end

  test "returns a JSON list", %{worker: worker} do
    assert {:ok, [1, 2, 3]} = KernelWorker.evaluate(worker, "{1, 2, 3}")
  end

  test "returns a JSON object", %{worker: worker} do
    assert {:ok, %{"a" => 1, "b" => "hello"}} =
             KernelWorker.evaluate(worker, ~s(<|"a" -> 1, "b" -> "hello"|>))
  end

  test "returns Wolfram-side errors", %{worker: worker} do
    assert {:ok, %{"error" => _}} = KernelWorker.evaluate(worker, "1/0")
  end
end
