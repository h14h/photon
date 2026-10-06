defmodule PhotonNode.Fixtures do
  @moduledoc """
  Test data builders shared by the core and boundary tests. Each takes
  overrides for any field, so a test names only what it cares about.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias PhotonCore.Operation

  @doc "A `ready` shell operation, as `PhotonNode.Executor.Request` builds one."
  def shell_op(overrides \\ []) do
    command = Keyword.get(overrides, :command, "true")
    workspace = Keyword.get(overrides, :workspace, "/data/workspace")

    %{
      "id" => Keyword.get(overrides, :id, "op_1"),
      "type" => "shell",
      "version" => 1,
      "status" => "ready",
      "max_output_length" => nil,
      "state" => %{
        "input" => %{"command" => command, "shell" => "/bin/sh", "directory" => workspace},
        "base_directory" => Keyword.get(overrides, :dir, "/data/ops"),
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
end
