defmodule PhotonNode.Run do
  @moduledoc """
  One `unreal-agent-runner` process, owned through a Port.

  Stdout is JSONL: persisted session items plus a final `{"type":"error"}`
  event on failure. Stderr is merged in, so any line that is not JSON is
  surfaced as a `stderr` event. Each event is appended to the session's
  `PhotonNode.EventLog` and then handed to `PhotonNode.Connection`, which
  forwards it to the server if connected. The run itself never depends on
  the connection, so it survives the server going away.
  """

  use GenServer, restart: :temporary

  alias PhotonNode.{Connection, EventLog}

  # Lines can carry base64 images, so read in large chunks and reassemble.
  @line_bytes 1_048_576

  def start_link(spec) do
    GenServer.start_link(__MODULE__, spec,
      name: {:via, Registry, {PhotonNode.RunRegistry, spec.session_id}}
    )
  end

  def interrupt(pid), do: GenServer.cast(pid, :interrupt)

  @impl true
  def init(spec) do
    port =
      Port.open({:spawn_executable, spec.executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        {:line, @line_bytes},
        {:args, spec.args},
        {:cd, spec.cd},
        {:env, Enum.map(spec.env, fn {k, v} -> {to_charlist(k), v && to_charlist(v)} end)}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Connection.notify({:run_started, spec.session_id})

    {:ok,
     %{session_id: spec.session_id, port: port, os_pid: os_pid, partial: [], last_error: nil}}
  end

  @impl true
  def handle_cast(:interrupt, state) do
    # The runner treats SIGINT as cancellation and exits 130.
    System.cmd("kill", ["-INT", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | partial: [state.partial, chunk]}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary([state.partial, chunk])
    state = %{state | partial: []}

    case decode(line, state) do
      nil ->
        {:noreply, state}

      event ->
        record(state.session_id, event)
        last_error = if event["type"] == "error", do: event["message"], else: state.last_error
        {:noreply, %{state | last_error: last_error}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    record(state.session_id, %{"type" => "exit", "status" => status, "at" => now()})
    Connection.notify({:run_finished, state.session_id, status})
    {:stop, :normal, state}
  end

  @doc "Appends an event to the session log and forwards it."
  def record(session_id, event) do
    offset = EventLog.append(session_id, event)
    Connection.notify({:event, session_id, offset, event})
    offset
  end

  defp decode("", _state), do: nil

  defp decode(line, state) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        event

      _ ->
        # The runner repeats its error event on stderr as "<name>: <message>".
        if state.last_error && String.ends_with?(line, ": " <> state.last_error),
          do: nil,
          else: %{"type" => "stderr", "message" => line}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
