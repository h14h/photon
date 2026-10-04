defmodule Photon.Fixtures do
  @moduledoc """
  Test data builders, shared by the core and boundary tests. Each takes
  overrides for any field, so a test names only what it cares about. They
  build data only: nothing here touches the database or a process.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Photon.Durable.{Entry, Signal, Submission, TaskRecord}
  alias Photon.NodeSessions.{Input, Session}
  alias PhotonCore.Message

  @at ~U[2026-10-03 12:00:00.000000Z]

  @doc "A fixed point in time, for timestamps that must compare equal."
  def at, do: @at

  ## The durable harness

  @doc "A task record; a pending generation in conversation `c_1` by default."
  def task(overrides \\ []) do
    struct!(
      %TaskRecord{
        id: "t_1",
        kind: "generation",
        conversation_id: "c_1",
        owner_task_id: nil,
        background: false,
        status: "pending",
        phase: "request",
        input: %{},
        checkpoint: %{},
        waiting: nil,
        outcome: nil,
        runs: 0,
        abort_requested: false,
        request_id: nil,
        inserted_at: @at,
        updated_at: @at
      },
      overrides
    )
  end

  @doc "A tool task running `call` for generation `t_1`."
  def tool_task(call \\ call("wait"), overrides \\ []) do
    task(
      Keyword.merge(
        [id: "t_2", kind: "tool", owner_task_id: "t_1", phase: "run", input: %{"call" => call}],
        overrides
      )
    )
  end

  @doc "A transcript entry of `kind` with `data`."
  def entry(kind, data, overrides \\ []) do
    struct!(
      %Entry{id: "e_1", conversation_id: "c_1", seq: 1, kind: kind, data: data, inserted_at: @at},
      overrides
    )
  end

  def user_entry(text, overrides \\ []),
    do: entry("user", %{"message" => Message.user(text)}, overrides)

  def assistant_entry(text, calls \\ [], overrides \\ []),
    do: entry("assistant", %{"message" => Message.assistant(text, calls)}, overrides)

  def tool_result_entry(call_id, text, overrides \\ []) do
    {data_overrides, overrides} = Keyword.split(overrides, [:status, :details])

    entry(
      "tool_result",
      %{
        "message" => Message.tool_result(call_id, text),
        "name" => "wait",
        "status" => Keyword.get(data_overrides, :status, "ok"),
        "details" => Keyword.get(data_overrides, :details, %{})
      },
      overrides
    )
  end

  @doc "A tool call, as a model returns it."
  def call(name, args \\ %{}, id \\ "call_1"),
    do: %{"id" => id, "name" => name, "arguments" => Jason.encode!(args)}

  @doc "A submission; queued, from the user, by default."
  def submission(overrides \\ []) do
    struct!(
      %Submission{
        id: "s_1",
        conversation_id: "c_1",
        request_id: nil,
        mode: "follow_up",
        content: %{"parts" => Message.parts("hello"), "source" => %{"kind" => "user"}},
        status: "queued",
        inserted_at: @at,
        updated_at: @at
      },
      overrides
    )
  end

  @doc "A model response, as `PhotonCore.LLM.stream/3` returns it; overrides have string keys."
  def response(message \\ Message.assistant("hi"), overrides \\ %{}) do
    Map.merge(
      %{
        "message" => message,
        "usage" => %{"input" => 10, "output" => 5},
        "model" => "test",
        "stop" => "stop"
      },
      Map.new(overrides)
    )
  end

  @doc "A recorded signal."
  def signal(key \\ "go", payload \\ %{}),
    do: %Signal{key: key, payload: payload, inserted_at: @at}

  ## Node work and node sessions

  @doc "Node work as the assistant's watcher and tools describe it."
  def work(overrides \\ %{}) do
    Map.merge(
      %{"node" => "box", "title" => "Check disks", "session_id" => "ns_1", "input_id" => "in_1"},
      Map.new(overrides)
    )
  end

  @doc "The payload of a node input's signal."
  def node_answer(answer \\ "all good", failure \\ nil),
    do: %{"session_id" => "ns_1", "answer" => answer, "failure" => failure}

  @doc "The hub's record of a node session."
  def session(overrides \\ []) do
    struct!(
      %Session{
        id: "ns_1",
        node_id: "box",
        title: "Check disks",
        origin: "user",
        config: %{"model" => "mock-model", "reasoning" => nil},
        status: "pending",
        next_offset: 0,
        inserted_at: @at,
        updated_at: @at
      },
      overrides
    )
  end

  @doc "An outbox entry for an input."
  def input(overrides \\ []) do
    struct!(
      %Input{
        id: "in_1",
        session_id: "ns_1",
        input: %{"id" => "in_1", "kind" => "external", "payload" => %{"content" => []}},
        state: "queued",
        inserted_at: @at,
        updated_at: @at
      },
      overrides
    )
  end

  @doc "A node log record of `kind`."
  def record(kind, data \\ %{}),
    do: %{"kind" => kind, "data" => data, "at" => "2026-10-03T12:00:00Z"}

  @doc "The log record of an external input."
  def input_record(id \\ "in_1", content \\ "x"),
    do: record("input", %{"id" => id, "kind" => "external", "payload" => %{"content" => content}})

  @doc "A run-state record (`running`, `idle`, `stopped`), with extra fields."
  def state_record(state, fields \\ %{}), do: record("state", Map.put(fields, "state", state))

  ## Settings

  @doc "A complete settings map, as `Photon.Settings.load/0` returns it."
  def settings(overrides \\ %{}) do
    Photon.Settings.normalize(Map.new(overrides), Photon.Settings.defaults())
  end

  @doc "An environment lookup over a fixed map."
  def env(vars \\ %{}), do: &Map.get(vars, &1)
end
