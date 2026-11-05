import Config

config :atlas_tracker,
  wolfram_kernel_path: "/nonexistent/wolfram/kernel",
  trajectory_cache_ttl_ms: 0

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :atlas_tracker, AtlasTrackerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JMOtr9uEK0fgnL+9cO0IeHJV7UGmMQjB2d69AbITkoqA7piZX9PaGZLFFfZY27EW",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
