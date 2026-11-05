defmodule AtlasTracker.KernelWorker do
  @moduledoc """
  Owns an optional Wolfram kernel and broadcasts its availability.
  """
  use GenServer

  require Logger

  @start_marker "__START__"
  @end_marker "__END__"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def evaluate(pid, code, timeout \\ 30_000) do
    GenServer.call(pid, {:evaluate, code}, timeout)
  end

  def status(pid \\ __MODULE__), do: GenServer.call(pid, :status)

  def subscribe(subscriber \\ self(), worker \\ __MODULE__) do
    GenServer.call(worker, {:subscribe, subscriber})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      kernel_path:
        Keyword.get(opts, :kernel_path, Application.get_env(:atlas_tracker, :wolfram_kernel_path)),
      retry_ms:
        Keyword.get(
          opts,
          :retry_ms,
          Application.get_env(:atlas_tracker, :kernel_retry_ms, 30_000)
        ),
      retry_timer: nil,
      subscribers: %{},
      buffer: "",
      caller: nil,
      status: nil,
      warned?: false
    }

    state =
      opts
      |> Keyword.get(:notify, [])
      |> List.wrap()
      |> Enum.reduce(state, &add_subscriber(&2, &1))

    {:ok, start_kernel(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:subscribe, subscriber}, _from, state) do
    state = add_subscriber(state, subscriber)
    send(subscriber, {:kernel_status, self(), state.status})
    {:reply, :ok, state}
  end

  def handle_call({:evaluate, code}, from, %{status: :ready, caller: nil} = state) do
    state = %{state | caller: from, buffer: ""}

    case send_to_kernel(state.port, code) do
      :ok -> {:noreply, state}
      :error -> {:noreply, unavailable(state)}
    end
  end

  def handle_call({:evaluate, _}, _from, state) do
    reason =
      case state.status do
        :unavailable -> :unavailable
        :warming -> :not_ready
        :ready -> :busy
      end

    {:reply, {:error, reason}, state}
  end

  @impl true
  def handle_info(:retry_kernel, %{status: :unavailable} = state) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    {:noreply, start_kernel(%{state | retry_timer: nil})}
  end

  def handle_info(:retry_kernel, state), do: {:noreply, state}

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_port(port) do
    buffer = state.buffer <> data

    case extract_result(buffer) do
      {:ok, json, rest} -> {:noreply, handle_result(Jason.decode(json), %{state | buffer: rest})}
      :incomplete -> {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state) when is_port(port) do
    {:noreply, unavailable(state)}
  end

  def handle_info({:EXIT, port, _}, %{port: port} = state) when is_port(port) do
    {:noreply, unavailable(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    subscribers =
      if Map.get(state.subscribers, pid) == ref do
        Map.delete(state.subscribers, pid)
      else
        state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close_port(state.port)

  defp start_kernel(state) do
    with true <- executable?(state.kernel_path),
         {:ok, port} <- open_port(state.kernel_path) do
      state = transition(%{state | port: port, buffer: ""}, :warming)

      case send_to_kernel(port, "1 + 1") do
        :ok -> state
        :error -> unavailable(state)
      end
    else
      _ -> unavailable(state)
    end
  end

  defp executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp executable?(_), do: false

  defp open_port(path) do
    {:ok,
     Port.open({:spawn_executable, path}, [
       :binary,
       :exit_status,
       :use_stdio,
       :stderr_to_stdout,
       args: ["-noprompt", "-run"]
     ])}
  rescue
    _ -> :error
  end

  defp send_to_kernel(port, code) do
    wrapped =
      [
        ~s(WriteString[$Output, "#{@start_marker}\\n"]),
        ~s(Module[{result}, result = Quiet[Check[#{code}, $Failed]]; If[result === $Failed, WriteString[$Output, ExportString[<|"error" -> "evaluation failed"|>, "JSON"]], WriteString[$Output, ExportString[result, "JSON"]]]]),
        ~s(WriteString[$Output, "\\n#{@end_marker}\\n"])
      ]
      |> Enum.join(";")

    true = Port.command(port, wrapped <> "\n")
    :ok
  rescue
    _ -> :error
  end

  defp extract_result(buffer) do
    with [_, rest] <- :binary.split(buffer, @start_marker),
         [json, remainder] <- :binary.split(rest, @end_marker) do
      {:ok, String.trim(json), remainder}
    else
      _ -> :incomplete
    end
  end

  defp handle_result({:ok, _}, %{status: :warming} = state) do
    transition(%{state | warned?: false}, :ready)
  end

  defp handle_result({:error, _}, %{status: :warming} = state), do: unavailable(state)

  defp handle_result(result, %{caller: caller} = state) when not is_nil(caller) do
    reply =
      case result do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, :parse_error}
      end

    GenServer.reply(caller, reply)
    %{state | caller: nil}
  end

  defp handle_result(_, state), do: state

  defp unavailable(state) do
    close_port(state.port)
    if state.caller, do: GenServer.reply(state.caller, {:error, :kernel_crashed})

    unless state.warned? do
      Logger.warning("Wolfram kernel unavailable; retrying startup automatically")
    end

    timer = state.retry_timer || Process.send_after(self(), :retry_kernel, state.retry_ms)

    state
    |> Map.merge(%{port: nil, caller: nil, buffer: "", retry_timer: timer, warned?: true})
    |> transition(:unavailable)
  end

  defp transition(%{status: status} = state, status), do: state

  defp transition(state, status) do
    Enum.each(state.subscribers, fn {pid, _} ->
      send(pid, {:kernel_status, self(), status})
    end)

    %{state | status: status}
  end

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
    end
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp close_port(_), do: :ok
end
