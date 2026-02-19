defmodule AtlasTrackerWeb.TrackerLiveTest do
  use AtlasTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag timeout: 60_000

  test "renders the tracker page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Atlas Tracker"
    assert html =~ "Fetch 3I/ATLAS"
    assert html =~ "Evaluate"
  end
end
