defmodule PhotonNode.HarnessCase do
  @moduledoc """
  The case for the node's boundary tests: it runs a whole node with no hub
  connection in a temporary data directory, and calls it the way the hub
  connection does, through `PhotonNode.Harness`. The test process stands in
  for the connection (it registers as `PhotonNode.Connection`), so it
  receives every log record as `{:event, session_id, offset, record}` and
  live data as `{:live, ...}`.

  These tests cover processes, timing, files and the protocol. What a
  session decides is covered by the core tests in `test/core`.

  A test can set `@tag heartbeat_ms: n` for the node's heartbeat interval.
  The names are global (one node per VM), so boundary tests are
  `async: false`.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  using do
    quote do
      import PhotonNode.HarnessCase
      import PhotonNode.Fixtures
      alias PhotonNode.Harness
    end
  end

  setup context do
    dir = Path.join(System.tmp_dir!(), "photon-node-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Process.register(self(), PhotonNode.Connection)

    opts = [
      token: "test",
      data_dir: dir,
      node_id: "test",
      connect: false,
      heartbeat_ms: Map.get(context, :heartbeat_ms, 600_000)
    ]

    start_supervised!({PhotonNode, opts})
    {:ok, dir: dir, workspace: Path.join(dir, "workspace")}
  end

  @doc "An external input with a fresh ID."
  def message(text) do
    %{"id" => PhotonCore.ID.new("in_"), "kind" => "external", "payload" => %{"content" => text}}
  end

  @doc "Collects a session's records until one matches `fun`; returns them all."
  def await_record(session_id, fun, timeout \\ 10_000) do
    await(session_id, fun, timeout, [])
  end

  defp await(session_id, fun, timeout, acc) do
    receive do
      {:event, ^session_id, _offset, record} ->
        acc = [record | acc]
        if fun.(record), do: Enum.reverse(acc), else: await(session_id, fun, timeout, acc)
    after
      timeout ->
        kinds = acc |> Enum.reverse() |> Enum.map(& &1["kind"])
        flunk("no matching record for #{session_id}; got kinds #{inspect(kinds)}")
    end
  end

  def idle?(%{"kind" => "state", "data" => %{"state" => "idle"}}), do: true
  def idle?(_), do: false

  def stopped?(%{"kind" => "state", "data" => %{"state" => "stopped"}}), do: true
  def stopped?(_), do: false

  @doc "The answer the last `idle` record in `records` reports."
  def answer(records) do
    records |> Enum.filter(&idle?/1) |> List.last() |> get_in(["data", "answer"])
  end

  @doc "Whether a record shows a shell operation that has started its command."
  def running_op?(%{"kind" => "operation", "data" => %{"state" => %{"pgid" => pgid}}})
      when is_integer(pgid) and pgid > 0,
      do: true

  def running_op?(_), do: false

  @doc "Whether a record is a tool call's final status with an operation in `status`."
  def final_status?(record, status) do
    match?(
      %{"kind" => "tool_call_status", "data" => %{"operations" => [%{"status" => ^status}]}},
      record
    )
  end

  @doc "Kills a process group a test left running."
  def kill_group(pgid), do: System.cmd("/bin/sh", ["-c", "kill -KILL -#{pgid} 2>/dev/null"])
end
