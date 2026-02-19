defmodule AtlasTrackerWeb.Router do
  use AtlasTrackerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AtlasTrackerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AtlasTrackerWeb do
    pipe_through :browser

    live "/", TrackerLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", AtlasTrackerWeb do
  #   pipe_through :api
  # end
end
