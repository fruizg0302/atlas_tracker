defmodule AtlasTracker.KernelWorkerTest do
  use ExUnit.Case, async: false

  @moduletag :wolfram
  @moduletag timeout: 60_000

  setup do
    worker = start_supervised!(AtlasTracker.KernelWorker)
    # Wait for pre-warm to complete
    Process.sleep(6_000)
    %{worker: worker}
  end

  test "evaluates a simple arithmetic expression", %{worker: worker} do
    assert {:ok, 42} = AtlasTracker.KernelWorker.evaluate(worker, "40 + 2")
  end

  test "evaluates and returns a JSON list", %{worker: worker} do
    assert {:ok, [1, 2, 3]} = AtlasTracker.KernelWorker.evaluate(worker, "{1, 2, 3}")
  end

  test "evaluates and returns a JSON object", %{worker: worker} do
    assert {:ok, %{"a" => 1, "b" => "hello"}} =
             AtlasTracker.KernelWorker.evaluate(worker, "<|\"a\" -> 1, \"b\" -> \"hello\"|>")
  end

  test "returns error for invalid expression", %{worker: worker} do
    assert {:ok, %{"error" => _}} = AtlasTracker.KernelWorker.evaluate(worker, "1/0")
  end
end
