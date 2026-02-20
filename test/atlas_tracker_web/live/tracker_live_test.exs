defmodule AtlasTrackerWeb.TrackerLiveTest do
  use AtlasTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag timeout: 60_000

  test "renders the tracker page with 3D canvas", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Atlas Tracker"
    assert html =~ "3I/ATLAS Trajectory"
    assert html =~ "Evaluate"
    assert html =~ "phx-hook=\"SolarSystem\""
  end
end
