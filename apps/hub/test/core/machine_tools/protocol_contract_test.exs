defmodule Photon.MachineTools.ProtocolContractTest do
  @moduledoc """
  What the hub sends, the node accepts: `op.start` args the hub builds at
  the edges of its limits go through the wire as JSON and are judged by
  the node's `PhotonNode.Executor.Request`.
  """

  use Photon.Case, async: true

  alias Photon.MachineTools.Translate
  alias PhotonCore.Operation
  alias PhotonCore.Operation.Wire
  alias PhotonNode.Executor.Request

  @facts %{shell: "/bin/sh", ops_dir: "/data/ops", workspace: "/home/me/photon"}

  # The op.start the hub would push for `args`, as the node parses it.
  defp over_the_wire(kind, args) do
    {_event, payload} = Wire.start("op_1", kind, args, false)
    {:ok, start} = payload |> Jason.encode!() |> Jason.decode!() |> Wire.parse_start()
    start
  end

  test "a shell command at the size limit, with the largest output limit, runs on the node" do
    command = String.duplicate("x", Operation.max_command_bytes())

    for workdir <- [nil, "garden"] do
      {:ok, args} =
        Translate.shell_args(
          %{"command" => command, "max_output_length" => PhotonCore.Output.max_limit()},
          workdir
        )

      assert {:ok, %{"status" => "ready"}} =
               Request.operation(over_the_wire("shell", args), @facts)
    end
  end

  test "a command over the limit is refused by both sides" do
    command = String.duplicate("x", Operation.max_command_bytes() + 1)

    assert {:error, _reason} = Translate.shell_args(%{"command" => command}, nil)

    assert {:error, _reason} =
             Request.operation(
               over_the_wire("shell", %{
                 "command" => command,
                 "directory" => nil,
                 "max_output_length" => 40_000
               }),
               @facts
             )
  end

  test "a view_image call, absolute or relative, runs on the node" do
    for {path, workdir} <- [{"/tmp/a.png", nil}, {"shots/a.png", "garden"}] do
      {:ok, args} = Translate.view_image_args(%{"path" => path}, workdir)

      assert {:ok, %{"status" => "ready"}} =
               Request.operation(over_the_wire("view_image", args), @facts)
    end
  end
end
