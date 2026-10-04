defmodule Photon.NodeSessions.Mirror do
  @moduledoc """
  The rules of the hub's copy of a node session, as pure functions:

    * where a record from the node goes (`place/3`): the hub stores only
      the next offset it expects, from the node that owns the session, so
      replays are idempotent and gaps are noticed
    * what a stored record changes (`effect/1`): an `input` record accepts
      that input; a `state` record moves the session's status, and `idle`
      or `stopped` settles every accepted input with the session's answer
    * what the node refusing an input changes (`rejectable?/2`,
      `refused_session/3`)
    * the shapes the hub stores and sends: sessions, inputs, signal payloads

  `Photon.NodeSessions` applies these inside a durable commit.
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [Photon.NodeSessions.Input, Photon.NodeSessions.Session, PhotonCore]

  alias Photon.NodeSessions.{Input, Session}
  alias PhotonCore.Message

  @type placement :: :next | :duplicate | {:gap, non_neg_integer()} | :ignored

  @type effect ::
          {:accept_input, String.t()}
          | {:status, map()}
          | {:settle, map(), String.t() | nil, String.t() | nil}
          | :none

  @doc """
  A record as stored. One that isn't an object is still stored at its
  offset, wrapped, so the copy stays in step with the node's log.
  """
  @spec normalize(term()) :: map()
  def normalize(record) when is_map(record), do: record
  def normalize(record), do: %{"kind" => "invalid", "data" => record}

  @doc "Where a record at `offset` from `node_id` goes in `session`'s copy."
  @spec place(Session.t() | nil, String.t(), integer()) :: placement()
  def place(%Session{node_id: node_id, next_offset: offset}, node_id, offset), do: :next

  def place(%Session{node_id: node_id, next_offset: expected}, node_id, offset)
      when offset < expected,
      do: :duplicate

  def place(%Session{node_id: node_id, next_offset: expected}, node_id, _offset),
    do: {:gap, expected}

  def place(_session, _node_id, _offset), do: :ignored

  @doc "What storing `record` changes besides the copy itself."
  @spec effect(map()) :: effect()
  def effect(%{"kind" => "input", "data" => %{"id" => input_id}}) when is_binary(input_id),
    do: {:accept_input, input_id}

  def effect(%{"kind" => "state", "data" => %{"state" => "running"}}),
    do: {:status, %{status: "running"}}

  def effect(%{"kind" => "state", "data" => %{"state" => "stopped"} = data}) do
    answer = text(data["answer"]) || "Stopped before finishing."
    settle("stopped", answer, "stopped")
  end

  def effect(%{"kind" => "state", "data" => %{"state" => "idle"} = data}),
    do: settle("idle", text(data["answer"]), failure_text(data["failure"]))

  def effect(_record), do: :none

  defp settle(state, answer, failure),
    do: {:settle, %{status: state, last_answer: answer, last_failure: failure}, answer, failure}

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp failure_text(%{"message" => message}) when is_binary(message), do: message
  defp failure_text(message) when is_binary(message), do: message
  defp failure_text(_), do: nil

  @doc """
  Whether the node refusing `input` changes anything: only while it is
  still queued, for the session that refused it.
  """
  @spec rejectable?(Input.t() | nil, String.t()) :: boolean()
  def rejectable?(%Input{session_id: session_id, state: "queued"}, session_id), do: true
  def rejectable?(_input, _session_id), do: false

  @doc """
  What a refused input changes about its session: a session still pending
  (it never started) fails with its refused message; otherwise, or for a
  refused stop, nothing (nil).
  """
  @spec refused_session(Session.t() | nil, Input.t(), String.t()) :: map() | nil
  def refused_session(_session, %Input{input: %{"kind" => "control"}}, _reason), do: nil

  def refused_session(%Session{status: "pending"}, _input, reason),
    do: %{status: "failed", last_failure: reason}

  def refused_session(_session, _input, _reason), do: nil

  @doc "A refusal's reason as stored: text, or the term inspected."
  @spec reason_text(term()) :: String.t()
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(reason), do: inspect(reason)

  @doc "The signal that fires when an input settles; the assistant's tools wait on it."
  @spec signal_key(String.t()) :: String.t()
  def signal_key(input_id), do: "node_input:" <> input_id

  @doc "The payload of an input's signal."
  @spec signal_payload(String.t(), String.t() | nil, String.t() | nil) :: map()
  def signal_payload(session_id, answer, failure),
    do: %{"session_id" => session_id, "answer" => answer, "failure" => failure}

  @doc """
  A new session as the hub records it, before the node has said anything.
  Options: `:title`, `:origin` and `:config` (the model settings it runs with).
  """
  @spec session(String.t(), String.t(), Message.content(), keyword(), DateTime.t()) :: Session.t()
  def session(id, node_id, prompt, opts, now) do
    %Session{
      id: id,
      node_id: node_id,
      title: opts[:title] || title(prompt),
      origin: opts[:origin] || "user",
      config: Keyword.get(opts, :config, %{}),
      status: "pending",
      next_offset: 0,
      inserted_at: now,
      updated_at: now
    }
  end

  @doc "An outbox entry for an input not sent yet."
  @spec queued_input(String.t(), String.t(), map(), DateTime.t()) :: Input.t()
  def queued_input(id, session_id, input, now) do
    %Input{
      id: id,
      session_id: session_id,
      input: input,
      state: "queued",
      inserted_at: now,
      updated_at: now
    }
  end

  @doc "The input the node receives for a message with `content`."
  @spec external_input(String.t(), Message.content()) :: map()
  def external_input(id, content) do
    %{"id" => id, "kind" => "external", "payload" => %{"content" => Message.parts(content)}}
  end

  @doc """
  The input that stops a session's work now: a hard stop. It goes through
  the outbox like a message, so its `id` must be stable across retries.
  """
  @spec stop_input(String.t()) :: map()
  def stop_input(id) do
    %{
      "id" => id,
      "kind" => "control",
      "payload" => %{"mode" => "hard", "reason" => "stopped from the hub"}
    }
  end

  @doc "The `input` command's payload for a session."
  @spec input_command(Session.t(), map()) :: map()
  def input_command(%Session{} = session, input),
    do: %{"session_id" => session.id, "input" => input, "config" => session.config}

  @doc "A session title from its first prompt: one line, at most 60 characters."
  @spec title(Message.content()) :: String.t()
  def title(prompt) do
    text = prompt |> Message.text_of() |> String.trim() |> String.replace(~r/\s+/, " ")
    if String.length(text) > 60, do: String.slice(text, 0, 57) <> "...", else: text
  end
end
