defmodule Photon.NodeSessions do
  @moduledoc """
  The hub's side of agent sessions on nodes.

  A session lives on one node, which holds its canonical log. The hub keeps a
  copy in step by offset: `ingest/4` stores only the next expected record, so
  replays after a reconnect are idempotent and gaps are re-requested.

  Inputs go through an outbox (`Photon.NodeSessions.Input`): stored first,
  then pushed to the node if it is connected, and pushed again whenever it
  reconnects until its log shows them accepted. Only queued inputs are
  pushed, so one the node refused is never sent again. A stop is an input
  too (a hard stop), so it reaches a node that was offline, in order with
  the messages around it. When a session goes
  idle, every input it accepted is settled with the session's answer, and
  the durable signal `"node_input:" <> input_id` fires, which is what the
  assistant's tools and watchers wait on.

  Every write goes through `Photon.Durable.Store`, the hub's one line of
  commits, so settling inputs and recording their signals is one commit: a
  hub that stops in between can't settle an input without its signal (the
  node never resends a record the hub holds). Broadcasts and pushes happen
  after the commit. The rules for the copy are `Photon.NodeSessions.Mirror`.

  Pushes to nodes are plain messages to the node's channel process (see
  `Photon.Nodes.command/3`). One that is lost (the connection drops) is
  recovered by the outbox, which is resent on the next join. A delete is
  still sent once and not stored, so a node that is offline then keeps its
  copy of the session.

  PubSub: `subscribe/0` (`topic/0`) carries `:node_sessions_changed`;
  `subscribe/1` (`topic/1`) carries `{:node_event, id, record}` and
  `{:node_live, id, data}`.
  """

  use Boundary,
    deps: [
      Photon.Durable,
      Photon.Events,
      Photon.Nodes,
      Photon.Repo,
      Photon.Settings,
      PhotonCore,
      Ecto
    ],
    exports: [Event, Input, Session]

  import Ecto.Query

  alias Photon.{Durable, Events, Nodes, Repo}
  alias Photon.Durable.Tx
  alias Photon.NodeSessions.{Event, Input, Mirror, Session}
  alias PhotonCore.Message

  @topic "node_sessions"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec topic(String.t()) :: String.t()
  def topic(id), do: "node_session:" <> id

  @doc "Subscribes to `:node_sessions_changed`: a session was created, deleted or changed status."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @doc "Subscribes to one session's records and live output."
  @spec subscribe(String.t()) :: :ok
  def subscribe(id), do: Events.subscribe(topic(id))

  defp broadcast, do: Events.broadcast(@topic, :node_sessions_changed)

  ## Reading

  @spec get(String.t()) :: Session.t() | nil
  def get(id), do: Repo.get(Session, id)

  @doc "Sessions, newest first; `node_id` limits them to one node."
  @spec list(String.t() | nil, pos_integer()) :: [Session.t()]
  def list(node_id \\ nil, limit \\ 100) do
    query = from(s in Session, order_by: [desc: s.updated_at], limit: ^limit)
    query = if node_id, do: where(query, [s], s.node_id == ^node_id), else: query
    Repo.all(query)
  end

  @doc "How many sessions a node has, counting up to `limit`."
  @spec count(String.t(), pos_integer()) :: non_neg_integer()
  def count(node_id, limit) do
    sessions = from(s in Session, where: s.node_id == ^node_id, limit: ^limit, select: s.id)
    Repo.aggregate(subquery(sessions), :count)
  end

  @doc "A session's records in order."
  @spec events(String.t()) :: [map()]
  def events(id) do
    query =
      from(e in Event, where: e.session_id == ^id, order_by: [asc: e.offset], select: e.record)

    Repo.all(query)
  end

  @spec input(String.t()) :: Input.t() | nil
  def input(id), do: Repo.get(Input, id)

  @doc "The next offset the hub expects for each of a node's sessions."
  @spec sync_for(String.t()) :: %{String.t() => non_neg_integer()}
  def sync_for(node_id) do
    query = from(s in Session, where: s.node_id == ^node_id, select: {s.id, s.next_offset})
    query |> Repo.all() |> Map.new()
  end

  ## Starting and steering work

  @doc """
  Starts a session on a node with `prompt`. Options: `:id` (makes creation
  idempotent), `:input_id`, `:title`, `:origin` (`"assistant"` or
  `"user"`), `:config` (model settings; defaults from `Photon.Settings`).
  Returns `{:ok, session, input}`.
  """
  @spec start(String.t(), Message.content(), keyword()) ::
          {:ok, Session.t(), Input.t()} | {:error, String.t()}
  def start(node_id, prompt, opts \\ []) do
    id = opts[:id] || PhotonCore.ID.new("ns_")
    config = opts[:config] || Photon.Settings.node_config(Photon.Settings.load())

    new =
      Mirror.session(id, node_id, prompt, Keyword.put(opts, :config, config), DateTime.utc_now())

    session =
      Durable.commit(fn _tx ->
        Repo.insert!(new, on_conflict: :nothing, conflict_target: :id)
        get(id)
      end)

    broadcast()

    with {:ok, input} <- send_input(id, prompt, input_id: opts[:input_id]) do
      {:ok, session, input}
    end
  end

  @doc "Sends another message to a session. Options: `:input_id`."
  @spec send_input(String.t(), Message.content(), keyword()) ::
          {:ok, Input.t()} | {:error, String.t()}
  def send_input(session_id, content, opts \\ []) do
    case get(session_id) do
      nil ->
        {:error, "no session #{session_id}"}

      session ->
        id = opts[:input_id] || PhotonCore.ID.new("in_")
        queue_input(session, Mirror.external_input(id, content))
    end
  end

  defp queue_input(session, %{"id" => id} = input) do
    stored =
      Durable.commit(fn _tx ->
        now = DateTime.utc_now()
        entry = Mirror.queued_input(id, session.id, input, now)
        Repo.insert!(entry, on_conflict: :nothing, conflict_target: :id)
        session |> Ecto.Changeset.change(updated_at: DateTime.utc_now()) |> Repo.update!()
        input(id)
      end)

    broadcast()

    # A repeated send (a tool call rerun after a restart) pushes only an
    # input the node hasn't accepted or refused yet.
    :ok = if stored.state == "queued", do: push_input(session, stored.input), else: :ok
    {:ok, stored}
  end

  defp push_input(session, input) do
    command = Mirror.input_command(session, input)

    # An offline node gets every queued input when it next joins
    # (resend_queued/1), so :offline here loses nothing.
    _ = Nodes.command(session.node_id, "input", command)
    :ok
  end

  @doc "Resends every input a node hasn't accepted yet (after it connects)."
  @spec resend_queued(String.t()) :: :ok
  def resend_queued(node_id) do
    query =
      from(i in Input,
        join: s in Session,
        on: s.id == i.session_id,
        where: s.node_id == ^node_id and i.state == "queued",
        order_by: [asc: i.inserted_at],
        select: {s, i}
      )

    query |> Repo.all() |> Enum.each(fn {session, input} -> push_input(session, input.input) end)
  end

  @doc """
  Asks the session's node to stop its work. The stop is queued like a
  message, so a node that is offline stops the session when it reconnects;
  a node whose session isn't working by then refuses it. Options:
  `:input_id`, which makes a repeat (a tool call rerun after a restart) the
  same stop. nil for an unknown session.
  """
  @spec stop(String.t(), keyword()) :: {:ok, Input.t()} | nil
  def stop(session_id, opts \\ []) do
    with %Session{} = session <- get(session_id) do
      queue_input(session, Mirror.stop_input(opts[:input_id] || PhotonCore.ID.new("stop_")))
    end
  end

  @doc "Deletes a session here and asks its node to delete it there."
  @spec delete(String.t()) :: :ok
  def delete(session_id) do
    with %Session{} = session <- get(session_id) do
      # Known limit: hub commands aren't stored, so a node that is offline
      # now keeps its copy of the session (docs/verification.md, "Limits").
      _ = Nodes.command(session.node_id, "delete_session", %{"session_id" => session_id})

      Durable.commit(fn _tx ->
        Repo.delete_all(from(e in Event, where: e.session_id == ^session_id))
        Repo.delete_all(from(i in Input, where: i.session_id == ^session_id))
        Repo.delete!(session)
      end)

      broadcast()
    end

    :ok
  end

  ## From nodes

  @doc """
  Accepts one record from `node_id` at `offset` in the session's log.

  Returns `:ok` when stored, `:duplicate` for an offset already held,
  `{:gap, expected}` when records are missing, or `:ignored` when the
  session is unknown or belongs to another node.
  """
  @spec ingest(String.t(), String.t(), integer(), term()) ::
          :ok | :duplicate | {:gap, non_neg_integer()} | :ignored
  def ingest(id, node_id, offset, record) do
    record = Mirror.normalize(record)

    case Durable.commit(&ingest_tx(&1, id, node_id, offset, record)) do
      {:ok, status_changed?} ->
        Events.broadcast(topic(id), {:node_event, id, record})
        if status_changed?, do: broadcast(), else: :ok

      other ->
        other
    end
  end

  defp ingest_tx(tx, id, node_id, offset, record) do
    session = get(id)

    case Mirror.place(session, node_id, offset) do
      :next -> {:ok, store(tx, session, offset, record)}
      other -> other
    end
  end

  # Stores the record and applies its effect; returns whether the session's
  # status changed. Settled inputs' signals go in the same commit.
  defp store(tx, session, offset, record) do
    Repo.insert!(%Event{session_id: session.id, offset: offset, record: record})
    session = session |> Ecto.Changeset.change(next_offset: offset + 1) |> Repo.update!()
    apply_effect(tx, session, Mirror.effect(record))
  end

  defp apply_effect(_tx, _session, {:accept_input, input_id}) do
    query = from(i in Input, where: i.id == ^input_id and i.state == "queued")
    Repo.update_all(query, set: [state: "accepted", updated_at: DateTime.utc_now()])

    false
  end

  defp apply_effect(_tx, session, {:status, changes}), do: update_status(session, changes)

  defp apply_effect(tx, session, {:settle, changes, answer, failure}) do
    update_status(session, changes)
    :ok = settle_inputs(tx, session.id, answer, failure)
    true
  end

  defp apply_effect(_tx, _session, :none), do: false

  defp settle_inputs(tx, session_id, answer, failure) do
    query = from(i in Input, where: i.session_id == ^session_id and i.state == "accepted")
    accepted = Repo.all(query)

    Enum.each(accepted, fn input ->
      input
      |> Ecto.Changeset.change(state: "done", answer: answer, failure: failure)
      |> Repo.update!()

      Tx.signal(
        tx,
        Mirror.signal_key(input.id),
        Mirror.signal_payload(session_id, answer, failure)
      )
    end)
  end

  @doc "The node refused an input (bad workspace, invalid ID, ...)."
  @spec reject_input(String.t(), String.t(), term(), String.t()) :: :ok
  def reject_input(session_id, input_id, reason, node_id) do
    reason = Mirror.reason_text(reason)
    status_changed? = Durable.commit(&reject_tx(&1, session_id, input_id, reason, node_id))
    if status_changed?, do: broadcast()
    :ok
  end

  # Only the node a session runs on can refuse its inputs.
  defp reject_tx(tx, session_id, input_id, reason, node_id) do
    input = input(input_id)

    if owned?(session_id, node_id) and Mirror.rejectable?(input, session_id),
      do: fail_input(tx, input, reason),
      else: false
  end

  @doc "Whether session `id` runs on node `node_id`."
  @spec owned?(String.t(), String.t()) :: boolean()
  def owned?(id, node_id) do
    Session |> where([s], s.id == ^id and s.node_id == ^node_id) |> Repo.exists?()
  end

  defp fail_input(tx, input, reason) do
    input |> Ecto.Changeset.change(state: "failed", failure: reason) |> Repo.update!()

    Tx.signal(
      tx,
      Mirror.signal_key(input.id),
      Mirror.signal_payload(input.session_id, nil, reason)
    )

    session = get(input.session_id)

    case Mirror.refused_session(session, input, reason) do
      nil -> false
      changes -> update_status(session, changes)
    end
  end

  @doc """
  Passes a node's live output (model text, command output) to the session's
  watchers. Never stored. A broadcast per message: the node samples command
  output and the model streams tokens, and a watcher that falls behind only
  misses intermediate text, which the stored records replace.
  """
  @spec live(String.t(), map()) :: :ok
  def live(id, data),
    do: Events.broadcast(topic(id), {:node_live, id, data})

  # Inside a commit: the change is announced (broadcast/0) after it.
  defp update_status(session, changes) do
    session
    |> Ecto.Changeset.change(Map.put(changes, :updated_at, DateTime.utc_now()))
    |> Repo.update!()

    true
  end
end
