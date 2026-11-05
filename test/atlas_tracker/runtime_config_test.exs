defmodule AtlasTracker.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @vars ~w(WOLFRAM_KERNEL_PATH KERNEL_RETRY_MS TRAJECTORY_CACHE_TTL_MS)

  setup do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  defp read_config do
    base = Config.Reader.read!(Path.expand("../../config/test.exs", __DIR__), env: :test)
    runtime = Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :test)
    Config.Reader.merge(base, runtime)[:atlas_tracker]
  end

  test "unset path preserves test override" do
    assert read_config()[:wolfram_kernel_path] == "/nonexistent/wolfram/kernel"
    assert read_config()[:trajectory_cache_ttl_ms] == 0
  end

  test "runtime overrides apply" do
    System.put_env("WOLFRAM_KERNEL_PATH", "/tmp/configured-kernel")
    System.put_env("KERNEL_RETRY_MS", "17")
    System.put_env("TRAJECTORY_CACHE_TTL_MS", "23")
    config = read_config()
    assert config[:wolfram_kernel_path] == "/tmp/configured-kernel"
    assert config[:kernel_retry_ms] == 17
    assert config[:trajectory_cache_ttl_ms] == 23
  end
end
