defmodule PhotonNode.HarnessCase do
  @moduledoc """
  The case for the operation layer's and the connection's boundary tests:
  it runs a whole node with no hub connection in a temporary data
  directory. The test process stands in for the connection (it registers
  as `PhotonNode.Connection`), so what the executor sends the hub link
  arrives as `{:op_snapshot, op}` and `{:op_output, id, stream, text}`.

  These tests cover processes, timing, files and the protocol. What the
  executor decides is covered by the core tests in `test/core`.

  The names are global (one node per VM), so boundary tests are
  `async: false`.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  using do
    quote do
      import PhotonNode.Fixtures
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "photon-node-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Process.register(self(), PhotonNode.Connection)

    opts = [token: "test", data_dir: dir, node_id: "test", connect: false]

    start_supervised!({PhotonNode, opts})
    {:ok, dir: dir, ops_dir: Path.join(dir, "ops"), workspace: Path.join(dir, "workspace")}
  end
end
