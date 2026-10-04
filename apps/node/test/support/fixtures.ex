defmodule PhotonNode.Fixtures do
  @moduledoc """
  Test data builders shared by the core and boundary tests. Each takes
  overrides for any field, so a test names only what it cares about.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias PhotonCore.{LLM, Message}
  alias PhotonNode.Harness.{Operation, Session, Store}

  ## Sessions

  @doc "A session's environment (`Session.env/0`), with no files behind it."
  def env(overrides \\ []) do
    Map.merge(
      %{
        workspace: "/work",
        shell: "/bin/sh",
        operations_dir: "/work/.photon/operations/s1",
        skills: [],
        machine: "testhost (x86_64-test)",
        heartbeat_ms: 600_000
      },
      Map.new(overrides)
    )
  end

  @doc "A new session core: `:id`, `:config` and `:env` (overrides for `env/1`)."
  def session(overrides \\ []) do
    Session.new(
      Keyword.get(overrides, :id, "s1"),
      Keyword.get(overrides, :config, %{}),
      env(Keyword.get(overrides, :env, []))
    )
  end

  @doc "A skill as `PhotonNode.Harness.Skills.discover/1` returns it."
  def skill(overrides \\ []) do
    Map.merge(
      %{
        name: "deploy",
        description: "How to deploy",
        path: "/work/.harness/skills/deploy/SKILL.md"
      },
      Map.new(overrides)
    )
  end

  ## Inputs

  @doc "An external input with a fresh ID."
  def external(content \\ "hello", overrides \\ []) do
    Map.merge(
      %{
        "id" => PhotonCore.ID.new("in_"),
        "kind" => "external",
        "payload" => %{"content" => content}
      },
      Map.new(overrides)
    )
  end

  @doc "A hard stop, as the hub sends it."
  def hard_stop(overrides \\ []) do
    Map.merge(
      %{
        "id" => PhotonCore.ID.new("stop_"),
        "kind" => "control",
        "payload" => %{"mode" => "hard", "reason" => "stopped from the hub"}
      },
      Map.new(overrides)
    )
  end

  @doc "A settings control input."
  def settings(parameters, overrides \\ []) do
    Map.merge(
      %{
        "id" => PhotonCore.ID.new("settings_"),
        "kind" => "control",
        "payload" => %{"mode" => "settings", "parameters" => parameters}
      },
      Map.new(overrides)
    )
  end

  ## Model answers

  @doc "A tool call the model made."
  def call(id, name \\ "Bash", arguments \\ %{}),
    do: %{"id" => id, "name" => name, "arguments" => Jason.encode!(arguments)}

  def bash_call(id, command), do: call(id, "Bash", %{"command" => command})

  @doc "A model answer as `PhotonCore.LLM.stream/3` returns it."
  def model_answer(text, calls \\ [], overrides \\ []) do
    response =
      Map.merge(
        %{
          "message" => Message.assistant(text, calls),
          "stop" => if(calls == [], do: "end_turn", else: "tool_use"),
          "usage" => nil,
          "model" => "mock"
        },
        Map.new(overrides)
      )

    {:ok, response}
  end

  @doc "A model request that failed."
  def model_failure(message \\ "connection refused"),
    do: {:error, LLM.Error.new(:transport, message)}

  ## Operations

  @doc "A `ready` shell operation, as the Bash translator builds one."
  def shell_op(overrides \\ []) do
    command = Keyword.get(overrides, :command, "true")
    workspace = Keyword.get(overrides, :workspace, "/work")

    %{
      "id" => Keyword.get(overrides, :id, "op_1"),
      "type" => "shell",
      "version" => 1,
      "status" => "ready",
      "max_output_length" => nil,
      "state" => %{
        "input" => %{"command" => command, "shell" => "/bin/sh", "directory" => workspace},
        "base_directory" => Keyword.get(overrides, :dir, "/work/.photon/operations/s1"),
        "phase" => "",
        "pgid" => 0,
        "exit_code" => nil,
        "result" => nil,
        "terminal_error" => "",
        "out_path" => "",
        "err_path" => ""
      }
    }
  end

  @doc "A shell operation that has started its command."
  def running(op, pgid \\ 4242),
    do: Operation.advance(op, "awaiting", %{"phase" => "process", "pgid" => pgid})

  @doc "A shell operation that finished."
  def completed(op, result \\ %{"out" => "", "err" => "", "exit_code" => 0}),
    do: Operation.advance(op, "completed", %{"result" => result})

  ## Log records

  def turn(id, previous \\ ""), do: %{"id" => id, "previous" => previous, "type" => "regular"}

  def response_data(turn_id, message) do
    %{
      "turn_id" => turn_id,
      "response" => %{"message" => message, "stop" => "tool_use", "failure" => nil}
    }
  end

  def status_data(turn_id, call_id, ops) do
    %{
      "turn_id" => turn_id,
      "call_id" => call_id,
      "status" => %{"error" => "", "waiting_for" => Enum.map(ops, & &1["id"])},
      "operations" => ops
    }
  end

  @doc "Log records from `{kind, data}` pairs, numbered after the header."
  def records(pairs) do
    pairs
    |> Enum.with_index(1)
    |> Enum.map(fn {{kind, data}, seq} -> %{"seq" => seq, "kind" => kind, "data" => data} end)
  end

  @doc "Writes a session log as a coordinator would have left it (boundary tests)."
  def write_log(session_id, config, pairs) do
    {store, _header} = Store.create(session_id, config)

    store =
      Enum.reduce(pairs, store, fn {kind, data}, store ->
        {store, _record} = Store.append(store, kind, data)
        store
      end)

    Store.close(store)
  end

  ## Effects

  @doc """
  Effects reduced to what tests compare: `{:persist, kind}`,
  `{:reply, reply}`, `{:request, turn_id}`, `{:dispatch, op_id}`,
  `{:cancel_op, op_id}`, `:warn` and the timer effects without their
  durations.
  """
  def names(effects), do: Enum.map(effects, &name/1)

  defp name({:persist, kind, _data}), do: {:persist, kind}
  defp name({:reply, _from, reply}), do: {:reply, reply}
  defp name({:warn, _message}), do: :warn
  defp name({:request, turn_id, _request}), do: {:request, turn_id}
  defp name({:dispatch, op}), do: {:dispatch, op["id"]}
  defp name({:cancel_op, op_id}), do: {:cancel_op, op_id}
  defp name({timer, _ms}), do: timer
  defp name(effect) when is_atom(effect), do: effect

  @doc "The `{kind, data}` of every record persisted by these effects."
  def persisted(effects), do: for({:persist, kind, data} <- effects, do: {kind, data})
end
