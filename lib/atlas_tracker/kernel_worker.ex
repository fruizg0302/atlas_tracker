defmodule AtlasTracker.KernelWorker do
  use GenServer
  require Logger

  @start_marker "__START__"
  @end_marker "__END__"

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def evaluate(pid, code, timeout \\ 30_000) do
    GenServer.call(pid, {:evaluate, code}, timeout)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    kernel_path = Application.get_env(:atlas_tracker, :wolfram_kernel_path)

    port =
      Port.open(
        {:spawn_executable, kernel_path},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout,
         args: ["-noprompt", "-run"]]
      )

    state = %{
      port: port,
      buffer: "",
      caller: nil,
      status: :initializing
    }

    # Pre-warm the kernel
    send(self(), :pre_warm)
    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate, code}, from, %{status: :ready, caller: nil} = state) do
    send_to_kernel(state.port, code)
    {:noreply, %{state | caller: from, buffer: ""}}
  end

  def handle_call({:evaluate, _code}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:evaluate, _code}, _from, %{caller: caller} = state)
      when caller != nil do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_info(:pre_warm, state) do
    send_to_kernel(state.port, "1 + 1")
    {:noreply, %{state | status: :warming, buffer: ""}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    case extract_result(buffer) do
      {:ok, json_str, _rest} ->
        handle_result(json_str, state)

      :incomplete ->
        {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("WolframKernel exited with status #{status}")

    if state.caller do
      GenServer.reply(state.caller, {:error, :kernel_crashed})
    end

    {:stop, {:kernel_exit, status}, %{state | port: nil, caller: nil}}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp send_to_kernel(port, code) do
    wrapped = """
    WriteString[$Output, "#{@start_marker}\\n"];
    Module[{result},
      result = Quiet[Check[#{code}, $Failed]];
      If[result === $Failed,
        WriteString[$Output, ExportString[<|"error" -> "evaluation failed"|>, "JSON"]],
        WriteString[$Output, ExportString[result, "JSON"]]
      ]
    ];
    WriteString[$Output, "\\n#{@end_marker}\\n"]
    """

    Port.command(port, wrapped)
  end

  defp extract_result(buffer) do
    case {String.contains?(buffer, @start_marker), String.contains?(buffer, @end_marker)} do
      {true, true} ->
        [_before, rest] = String.split(buffer, @start_marker, parts: 2)
        [json_str, remainder] = String.split(rest, @end_marker, parts: 2)
        {:ok, String.trim(json_str), remainder}

      _ ->
        :incomplete
    end
  end

  defp handle_result(json_str, %{status: :warming} = state) do
    case Jason.decode(json_str) do
      {:ok, _result} ->
        Logger.info("WolframKernel pre-warmed successfully")
        {:noreply, %{state | status: :ready, buffer: ""}}

      {:error, _} ->
        Logger.error("Pre-warm failed to parse: #{inspect(json_str)}")
        {:noreply, %{state | status: :ready, buffer: ""}}
    end
  end

  defp handle_result(json_str, %{caller: caller} = state) when caller != nil do
    result =
      case Jason.decode(json_str) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> {:error, :parse_error}
      end

    GenServer.reply(caller, result)
    {:noreply, %{state | caller: nil, buffer: ""}}
  end

  defp handle_result(_json_str, state) do
    {:noreply, %{state | buffer: ""}}
  end
end
