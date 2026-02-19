defmodule AtlasTracker.HorizonsClientTest do
  use ExUnit.Case, async: true

  @moduletag :horizons
  @moduletag timeout: 30_000

  test "fetches state vectors for 3I/ATLAS" do
    result =
      AtlasTracker.HorizonsClient.fetch_state_vectors(
        "C/2025 N1",
        "2025-07-01",
        "2025-08-01",
        "7d"
      )

    assert {:ok, %{"result" => result_str}} = result
    assert is_binary(result_str)
    assert String.contains?(result_str, "$$SOE")
    assert String.contains?(result_str, "$$EOE")
  end

  test "returns error for invalid object" do
    result =
      AtlasTracker.HorizonsClient.fetch_state_vectors(
        "NONEXISTENT/OBJECT",
        "2025-07-01",
        "2025-08-01",
        "7d"
      )

    # Horizons returns 200 with an error message in the result field
    assert {:ok, %{"result" => result_str}} = result
    refute String.contains?(result_str, "$$SOE")
  end
end
