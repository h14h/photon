defmodule PhotonNode.Ops.EnvTest do
  use PhotonNode.Case, async: true

  alias PhotonNode.Ops.Env

  @burrito_paths "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib"

  test "commands don't inherit the node's launch plumbing or its token" do
    env = %{
      "PATH" => "/bin",
      "RELEASE_ROOT" => "/opt",
      "PHOTON_NODE_TOKEN" => "s",
      "HOME" => "/h"
    }

    assert Enum.sort(Env.overrides(env)) == [
             {"PHOTON_NODE_TOKEN", false},
             {"RELEASE_ROOT", false}
           ]
  end

  test "a packaged node also drops the library path its wrapper added" do
    packaged = %{"__BURRITO" => "1", "LD_LIBRARY_PATH" => @burrito_paths}
    assert {"LD_LIBRARY_PATH", false} in Env.overrides(packaged)

    mine = %{"__BURRITO" => "1", "LD_LIBRARY_PATH" => "/mine:" <> @burrito_paths}
    assert {"LD_LIBRARY_PATH", "/mine"} in Env.overrides(mine)

    refute Enum.any?(
             Env.overrides(%{"LD_LIBRARY_PATH" => "/mine"}),
             &match?({"LD_LIBRARY_PATH", _}, &1)
           )
  end

  test "overrides convert to what a port takes" do
    assert Env.to_port([{"A", "1"}, {"B", false}]) == [{~c"A", ~c"1"}, {~c"B", false}]
  end
end
