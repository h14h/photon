defmodule PhotonNode.Harness.ModelRequest do
  @moduledoc """
  Model requests, as workers: each one is a task under
  `PhotonNode.Harness.TaskSupervisor` that runs `PhotonCore.LLM.stream/3`
  and streams its deltas to the hub as live events. `LLM.stream/3` blocks
  for the whole request and sleeps between retries, which is why it runs
  here and not in the coordinator.

  The task is linked to the coordinator that starts it
  (`Task.Supervisor.async/2`), so it dies with that coordinator whatever
  state the coordinator crashed in (verification finding F1). The
  coordinator traps exits, so the task's answer arrives as a message, and a
  crash as a `:DOWN`.

  Live deltas go to `PhotonNode.Harness.Link.live/2` (the hub connection's
  `live/2`, a plain send that is dropped when the hub isn't connected): they are never stored, and the
  answer itself is recorded in the log once the request finishes.
  """

  alias PhotonCore.LLM
  alias PhotonNode.Config
  alias PhotonNode.Harness.Link

  @typedoc "A running request: the task's monitor reference and pid."
  @type t :: %{ref: Task.ref(), pid: pid()}

  @doc "Starts the request for `turn_id` of a session, linked to the caller."
  @spec start(String.t(), String.t(), LLM.request()) :: t()
  def start(session_id, turn_id, request) do
    config = config()

    task =
      Task.Supervisor.async(PhotonNode.Harness.TaskSupervisor, fn ->
        LLM.stream(request, config, fn event ->
          Link.live(session_id, live_event(turn_id, event))
        end)
      end)

    %{ref: task.ref, pid: task.pid}
  end

  @doc "Cancels a request, dropping any answer it already sent."
  @spec cancel(t() | nil) :: :ok
  def cancel(nil), do: :ok

  def cancel(%{ref: ref, pid: pid}) do
    Process.demonitor(ref, [:flush])
    # :not_found means the request already finished; the demonitor above
    # flushed its answer.
    _ = Task.Supervisor.terminate_child(PhotonNode.Harness.TaskSupervisor, pid)
    :ok
  end

  @doc "Where model requests go: the hub's relay, unless configured otherwise (tests)."
  @spec config() :: LLM.config()
  def config do
    case Application.get_env(:photon_node, :llm) do
      nil -> hub_relay(PhotonNode.config())
      config -> config
    end
  end

  defp hub_relay(node) do
    %{provider: "relay", base_url: Config.llm_base_url(node), api_key: node.token}
  end

  @doc "The live event the hub gets for one streamed model event."
  @spec live_event(String.t(), LLM.event()) :: map()
  def live_event(turn_id, {:text, delta}),
    do: %{"type" => "text", "turn" => turn_id, "delta" => delta}

  def live_event(turn_id, {:reasoning, delta}),
    do: %{"type" => "reasoning", "turn" => turn_id, "delta" => delta}

  def live_event(turn_id, {:tool_call, index, name, delta}) do
    %{
      "type" => "tool_call",
      "turn" => turn_id,
      "index" => index,
      "name" => name,
      "delta" => delta
    }
  end

  def live_event(turn_id, {:web_search, id, action}),
    do: %{"type" => "web_search", "turn" => turn_id, "id" => id, "action" => action}

  def live_event(turn_id, {:retry, attempt, delay, error}) do
    %{
      "type" => "retry",
      "turn" => turn_id,
      "attempt" => attempt,
      "delay_ms" => delay,
      "message" => Exception.message(error)
    }
  end
end
