defmodule AtlasTracker.StateVectorParserTest do
  use ExUnit.Case, async: true

  alias AtlasTracker.StateVectorParser

  @sample_result """
  Some header text
  $$SOE
  2460949.500000000 = A.D. 2025-Oct-01 00:00:00.0000 TDB
   X =-1.473031599831380E+08 Y =-2.077370683445942E+08 Z = 2.175281990054543E+07
   VX=-2.224863603945271E+01 VY= 6.241298060062839E+01 VZ=-3.046970847863886E+00
   LT= 8.525554763125925E+02 RG= 2.555897018251128E+08 RR=-3.816458707505653E+01
  2460956.500000000 = A.D. 2025-Oct-08 00:00:00.0000 TDB
   X =-1.605173434215324E+08 Y =-1.696801359571860E+08 Z = 1.987642809082884E+07
   VX=-2.140034910681917E+01 VY= 6.344658110564275E+01 VZ=-3.161249979338084E+00
   LT= 7.819374093574131E+02 RG= 2.344189379534111E+08 RR=-3.153896926392922E+01
  $$EOE
  Some footer text
  """

  test "parses state vectors into positions in AU" do
    {:ok, positions} = StateVectorParser.parse(@sample_result)

    assert length(positions) == 2

    [first | _] = positions
    assert_in_delta first.x, -1.473_031_599_831_380e8 / 1.496e8, 0.01
    assert_in_delta first.y, -2.077_370_683_445_942e8 / 1.496e8, 0.01
    assert_in_delta first.z, 2.175_281_990_054_543e7 / 1.496e8, 0.01
  end

  test "returns error when no SOE/EOE markers found" do
    assert {:error, :no_ephemeris_data} = StateVectorParser.parse("no data here")
  end

  test "returns empty list for empty SOE/EOE block" do
    result = "$$SOE\n$$EOE"
    assert {:ok, []} = StateVectorParser.parse(result)
  end

  @tag :horizons
  test "parses real JPL Horizons response" do
    {:ok, %{"result" => result_text}} =
      AtlasTracker.HorizonsClient.fetch_state_vectors(
        "C/2025 N1",
        "2025-07-01",
        "2026-06-01",
        "7d"
      )

    {:ok, positions} = AtlasTracker.StateVectorParser.parse(result_text)

    # ~52 weeks of weekly data
    assert length(positions) >= 48
    assert length(positions) <= 55

    # All positions should be reasonable AU values (within 50 AU of Sun)
    for pos <- positions do
      distance = :math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
      assert distance < 50.0, "Position #{inspect(pos)} is unreasonably far: #{distance} AU"
      assert distance > 0.1, "Position #{inspect(pos)} is unreasonably close: #{distance} AU"
    end
  end
end
