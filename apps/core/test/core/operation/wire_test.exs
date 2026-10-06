defmodule PhotonCore.Operation.WireTest do
  @moduledoc "The operation protocol's messages: built by one side, parsed by the other."

  use PhotonCore.Case, async: true

  alias PhotonCore.Operation.Wire

  # What the other side receives: the payload after a trip through JSON.
  defp over_the_wire({event, payload}), do: {event, payload |> Jason.encode!() |> Jason.decode!()}

  describe "event names" do
    test "name each message" do
      assert Enum.map([:start, :cancel, :ack, :snapshot, :output], &Wire.event/1) ==
               ~w(op.start op.cancel op.ack op.snapshot op.output)
    end

    test "are the events the builders use" do
      assert {"op.start", _} = Wire.start("op_1", "shell", %{}, false)
      assert {"op.cancel", _} = Wire.cancel("op_1")
      assert {"op.ack", _} = Wire.ack("op_1")
      assert {"op.snapshot", _} = Wire.snapshot(shell_op())
      assert {"op.output", _} = Wire.output("op_1", "out", "hi")
    end
  end

  describe "op.start" do
    test "round-trips" do
      args = %{"command" => "ls", "directory" => nil, "max_output_length" => 40_000}
      {"op.start", payload} = over_the_wire(Wire.start("op_1", "shell", args, true))

      assert Wire.parse_start(payload) ==
               {:ok, %{"id" => "op_1", "kind" => "shell", "args" => args, "known" => true}}
    end

    test "ignores unknown fields, but keeps args whole for the node to judge" do
      {_event, payload} = Wire.start("op_1", "paint", %{"brush" => "wide"}, false)

      assert {:ok, parsed} = Wire.parse_start(Map.put(payload, "priority", "high"))

      assert parsed == %{
               "id" => "op_1",
               "kind" => "paint",
               "args" => %{"brush" => "wide"},
               "known" => false
             }
    end

    test "refuses missing or mistyped fields" do
      {_event, payload} = Wire.start("op_1", "shell", %{}, false)

      assert {:error, "op.start: id must be" <> _} = Wire.parse_start(Map.delete(payload, "id"))

      assert {:error, "op.start: kind must be a string"} =
               Wire.parse_start(%{payload | "kind" => 1})

      assert {:error, "op.start: kind must be a string"} =
               Wire.parse_start(%{payload | "kind" => ""})

      assert {:error, "op.start: args must be an object"} =
               Wire.parse_start(%{payload | "args" => []})

      assert {:error, "op.start: known must be true or false"} =
               Wire.parse_start(Map.delete(payload, "known"))

      assert {:error, "op.start: the payload must be an object"} = Wire.parse_start("op_1")
    end

    test "refuses IDs that aren't operation IDs or aren't safe as file names" do
      for id <- ["t_1", "op_../../etc", "op_a/b", String.duplicate("o", 65), 7, nil] do
        {_event, payload} = Wire.start("op_1", "shell", %{}, false)
        assert {:error, "op.start: id must be" <> _} = Wire.parse_start(%{payload | "id" => id})
      end
    end
  end

  describe "op.cancel and op.ack" do
    test "round-trip" do
      for message <- [Wire.cancel("op_1"), Wire.ack("op_1")] do
        {_event, payload} = over_the_wire(message)
        assert Wire.parse_id(payload) == {:ok, %{"id" => "op_1"}}
      end
    end

    test "ignore unknown fields" do
      assert Wire.parse_id(%{"id" => "op_1", "reason" => "stop"}) == {:ok, %{"id" => "op_1"}}
    end

    test "refuse a missing or mistyped id" do
      assert {:error, "op.cancel or op.ack: id must be" <> _} = Wire.parse_id(%{})
      assert {:error, "op.cancel or op.ack: id must be" <> _} = Wire.parse_id(%{"id" => 1})
      assert {:error, _} = Wire.parse_id(nil)
    end
  end

  describe "op.snapshot" do
    test "round-trips through JSON" do
      op =
        shell_op()
        |> Operation.advance("completed", %{
          "result" => %{"out" => "café\u0000", "err" => "", "exit_code" => 0}
        })

      {"op.snapshot", payload} = over_the_wire(Wire.snapshot(op))

      assert Wire.parse_snapshot(payload) == {:ok, op}
    end

    test "keeps every status and a set output limit" do
      for status <- Operation.statuses() do
        op = %{shell_op() | "status" => status, "max_output_length" => 100}
        assert {:ok, ^op} = op |> Wire.snapshot() |> elem(1) |> Wire.parse_snapshot()
      end
    end

    test "ignores unknown fields around and in the snapshot" do
      op = shell_op()
      payload = %{"op" => Map.put(op, "progress", 0.5), "sent_at" => 1}

      assert Wire.parse_snapshot(payload) == {:ok, op}
    end

    test "refuses missing or mistyped fields" do
      op = shell_op()
      bad = fn changes -> Wire.parse_snapshot(%{"op" => Map.merge(op, changes)}) end

      assert {:error, "op.snapshot: op must be an object"} = Wire.parse_snapshot(%{})
      assert {:error, "op.snapshot: op must be an object"} = Wire.parse_snapshot(%{"op" => "x"})

      assert {:error, "op.snapshot: id must be" <> _} =
               Wire.parse_snapshot(%{"op" => Map.delete(op, "id")})

      assert {:error, "op.snapshot: type must be a string"} = bad.(%{"type" => nil})
      assert {:error, "op.snapshot: version must be a positive integer"} = bad.(%{"version" => 0})
      assert {:error, "op.snapshot: status must be one of " <> _} = bad.(%{"status" => "done"})

      assert {:error, "op.snapshot: max_output_length must be null or a positive integer"} =
               bad.(%{"max_output_length" => "10"})

      assert {:error, "op.snapshot: state must be an object"} = bad.(%{"state" => nil})
    end
  end

  describe "op.output" do
    test "round-trips" do
      {"op.output", payload} = over_the_wire(Wire.output("op_1", "err", "warning\n"))

      assert Wire.parse_output(payload) ==
               {:ok, %{"id" => "op_1", "stream" => "err", "text" => "warning\n"}}
    end

    test "ignores unknown fields" do
      {_event, payload} = Wire.output("op_1", "out", "")

      assert Wire.parse_output(Map.put(payload, "seq", 3)) ==
               {:ok, %{"id" => "op_1", "stream" => "out", "text" => ""}}
    end

    test "refuses missing or mistyped fields" do
      {_event, payload} = Wire.output("op_1", "out", "hi")

      assert {:error, "op.output: id must be" <> _} = Wire.parse_output(Map.delete(payload, "id"))

      assert {:error, ~s(op.output: stream must be "out" or "err")} =
               Wire.parse_output(%{payload | "stream" => "log"})

      assert {:error, "op.output: text must be a string"} =
               Wire.parse_output(%{payload | "text" => ["h", "i"]})
    end

    test "builds output only for the two streams" do
      assert_raise FunctionClauseError, fn -> Wire.output("op_1", "log", "hi") end
    end
  end
end
