defmodule AtlasTrackerWeb.PageController do
  use AtlasTrackerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
