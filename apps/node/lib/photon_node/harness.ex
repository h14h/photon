defmodule PhotonNode.Harness do
  @moduledoc """
  The node's agent harness, an Elixir port of Unreal Labs' unreal-agent, and
  its API: `deliver/3`, `stop/1`, `delete/1` and `resume_all/0`. This
  module validates what callers send, once, and hands it to the processes
  behind it.

  Behind the API, by layer:

    * functional core (no processes, no I/O):
      `PhotonNode.Harness.Session` (one session's state machine),
      `PhotonNode.Harness.Context` (model input), `PhotonNode.Harness.Inbox`
      (input validation and dedupe), the translators in
      `PhotonNode.Harness.Tools` and `PhotonNode.Harness.Image`, with the
      operation snapshots and output bounds the hub shares
      (`PhotonCore.Operation`, `PhotonCore.Output`)
    * boundary: `PhotonNode.Harness.Coordinator`, the server that runs a
      session; `PhotonNode.Harness.Store`, its append-only log;
      `PhotonNode.Harness.Ops`, the API over operation processes, and
      `PhotonNode.Harness.Ops.Owner`, the contract for whatever owns them;
      `PhotonNode.Harness.Skills` and `PhotonNode.Harness.Env`, which read
      the machine
    * workers: model requests (`PhotonNode.Harness.ModelRequest`) and
      operation processes (`PhotonNode.Harness.Ops.Shell`,
      `PhotonNode.Harness.Ops.Job`)
    * lifecycle: the `PhotonNode` supervisor

  Model requests go through the hub's relay, which holds the provider
  credentials. Sessions survive node restarts: a session that was working
  when the node stopped, or had input it hadn't started on, is resumed from
  its log on boot.
  """

  # The harness: this API, the servers and workers behind it, and its
  # functional core as strict sub-boundaries that depend on nothing else.
  # `Link` is the contract a hub link implements. `Ops`, `Ops.Owner` and
  # `Env` are for the executor, which runs the hub's operations: it starts,
  # finds and cancels them, owns them, and reads the shell to run commands
  # with.
  use Boundary,
    deps: [PhotonNode, PhotonNode.Config, PhotonCore, PhotonCore.LLM, PhotonCore.LLM.Error, Jason],
    exports: [Link, Ops, Ops.Owner, Env]

  require Logger

  alias PhotonNode.Harness.{Coordinator, Inbox, Link, ModelRequest, Session, Store}

  @session_config_keys ~w(model reasoning system_prompt disallowed_tools workspace)

  @doc """
  Delivers an input to a session, creating the session (with `config`) if
  it doesn't exist and starting its coordinator if it isn't running. With a
  `config`, changed settings are recorded before the input. Returns once
  the input is in the session's log (see `Coordinator.deliver/3`).

  Config keys: `"model"`, `"reasoning"`, `"system_prompt"`,
  `"disallowed_tools"`, `"workspace"` (fixed when the session is created).
  """
  @spec deliver(String.t(), map(), map() | nil) :: :ok | {:error, String.t()}
  def deliver(session_id, input, config \\ nil)

  # A hub's stop comes through its outbox like a message, so it may arrive
  # again after a reconnect: one already in the log is a repeat, and a
  # session with nothing to stop refuses it, which tells the hub to stop
  # resending it. Whether it is working comes from its log, since an idle
  # coordinator lingers a moment before it exits.
  def deliver(
        session_id,
        %{"kind" => "control", "payload" => %{"mode" => "hard"}} = stop,
        _config
      ) do
    with :ok <- valid_id(session_id),
         :ok <- Inbox.validate(stop) do
      cond do
        not Store.exists?(session_id) -> {:error, "session #{session_id} doesn't exist"}
        working_session?(session_id) -> Coordinator.deliver(session_id, nil, stop)
        logged?(session_id, stop["id"]) -> :ok
        true -> {:error, "session #{session_id} isn't working, so there's nothing to stop"}
      end
    end
  end

  def deliver(session_id, input, config) do
    with :ok <- valid_id(session_id),
         :ok <- Inbox.validate(input),
         :ok <- ensure_session(session_id, input, config || %{}) do
      Coordinator.deliver(session_id, config, input)
    end
  end

  @doc """
  Stops a session's work now: cancels its model request and operations.

  The hard stop goes through the same delivery as an input, so it returns
  once the stop is in the session's log, and a coordinator that dies first
  doesn't take it along. A session with no coordinator running gets one if
  its log says it was working (it is about to be restarted, or the node
  hasn't resumed it yet); one that isn't working has nothing to stop.
  """
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    if valid_id(session_id) == :ok and stoppable?(session_id) do
      case Coordinator.deliver(session_id, nil, stop_input()) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("couldn't stop session #{session_id}: #{reason}")
      end
    else
      :ok
    end

    :ok
  end

  defp stop_input do
    %{
      "id" => PhotonCore.ID.new("stop_"),
      "kind" => "control",
      "payload" => %{"mode" => "hard", "reason" => "stopped from the hub"}
    }
  end

  defp working_session?(id), do: Store.exists?(id) and working?(id)

  @doc "Deletes a session: stops it and removes its log and operation files."
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(session_id) do
    with :ok <- valid_id(session_id) do
      Coordinator.shutdown(session_id)
      Store.delete(session_id)
    end
  end

  @doc """
  A session's log records from `offset` on, paired with their offsets: what
  the hub link replays after a join or a resync.
  """
  @spec records_from(String.t(), non_neg_integer()) :: [{non_neg_integer(), Store.log_record()}]
  defdelegate records_from(session_id, offset), to: Store, as: :read_from

  @doc "Starts the coordinators of sessions that were working when the node stopped."
  @spec resume_all() :: :ok
  def resume_all do
    for id <- Store.list(), working?(id), do: resume(id)
    :ok
  end

  defp resume(id) do
    Logger.info("resuming session #{id}")

    case Coordinator.ensure_started(id) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("couldn't resume session #{id}: #{inspect(reason)}")
    end
  end

  defp stoppable?(id), do: Coordinator.whereis(id) != nil or working_session?(id)

  defp logged?(id, input_id) do
    id
    |> Store.read()
    |> Enum.any?(&match?(%{"kind" => "input", "data" => %{"id" => ^input_id}}, &1))
  end

  @doc "Where model requests go: the hub's relay, unless configured otherwise (tests)."
  @spec llm_config() :: PhotonCore.LLM.config()
  defdelegate llm_config, to: ModelRequest, as: :config

  @spec valid_id(term()) :: :ok | {:error, String.t()}
  def valid_id(id),
    do: if(PhotonCore.ID.valid?(id), do: :ok, else: {:error, "invalid session id"})

  @doc """
  Whether a session is mid-work, from its records or its ID: the last
  run-state record is "running", or an external input was logged after the
  last model response or stop (`Session.working?/1`).
  """
  @spec working?([map()] | String.t()) :: boolean()
  def working?(records) when is_list(records), do: Session.working?(records)
  def working?(id), do: working?(Store.read(id))

  defp ensure_session(id, input, config), do: ensure_session(id, input, config, Store.exists?(id))

  defp ensure_session(_id, _input, _config, true = _exists), do: :ok
  defp ensure_session(id, %{"kind" => "external"}, config, false), do: create_session(id, config)
  defp ensure_session(id, _input, _config, false), do: {:error, "session #{id} doesn't exist"}

  defp create_session(id, config) do
    config = Map.take(config, @session_config_keys)

    with :ok <- check_workspace(config["workspace"]) do
      {store, header} = Store.create(id, config)
      :ok = Store.close(store)
      Link.event(id, 0, header)
    end
  end

  defp check_workspace(nil), do: :ok
  defp check_workspace(""), do: :ok

  defp check_workspace(dir) do
    if File.dir?(Path.expand(dir)),
      do: :ok,
      else: {:error, "workspace #{dir} is not a directory on this node"}
  end
end
