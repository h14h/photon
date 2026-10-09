defmodule Photon.Machines.RulesTest do
  @moduledoc "The hub's rules for operation rows."

  use Photon.Case, async: true

  alias Photon.Machines.{Op, Rules}
  alias PhotonCore.Operation.Wire

  @id "op_abc"
  @args %{"command" => "uname -a", "directory" => nil, "max_output_length" => 40_000}

  defp row(attrs \\ []) do
    struct!(
      %Op{
        id: @id,
        machine: "mm1",
        kind: "shell",
        args: @args,
        task_id: "t_abc",
        status: "open",
        confirmed: false,
        pushed: false,
        cancel: false,
        result: nil
      },
      attrs
    )
  end

  defp snapshot(status, id \\ @id),
    do: %{"id" => id, "type" => "shell", "version" => 1, "status" => status, "state" => %{}}

  # A terminal snapshot of a command that printed `out` and `err`.
  defp printed(status, out, err),
    do: put_in(snapshot(status)["state"], %{"result" => %{"out" => out, "err" => err}})

  @terminal ~w(completed failed canceled)
  @running ~w(ready awaiting canceling)

  describe "insert?/2 (rule 9)" do
    test "only for an unfinished task that isn't marked for abort" do
      for status <- ~w(pending running waiting), do: assert(Rules.insert?(status, false))

      for status <- ~w(pending running waiting), do: refute(Rules.insert?(status, true))

      for status <- ~w(done failed aborted),
          abort <- [false, true],
          do: refute(Rules.insert?(status, abort))
    end

    test "not when the task is gone" do
      refute Rules.insert?(nil, false)
    end
  end

  describe "push_for/1 (rule 2)" do
    test "an open row gets op.start with known from the row, and pushed set" do
      assert Rules.push_for(row()) ==
               {%{pushed: true}, [Wire.start(@id, "shell", @args, false)]}

      assert Rules.push_for(row(confirmed: true)) ==
               {%{pushed: true}, [Wire.start(@id, "shell", @args, true)]}
    end

    test "a row already pushed needs no write" do
      assert Rules.push_for(row(pushed: true)) ==
               {:none, [Wire.start(@id, "shell", @args, false)]}
    end

    test "nothing for a canceled, finished or closed row, or no row" do
      for row <- [
            row(cancel: true),
            row(status: "finished", result: snapshot("completed")),
            row(status: "closed"),
            nil
          ],
          do: assert(Rules.push_for(row) == {:none, []})
    end
  end

  describe "on_join/1 (rules 2 and 7)" do
    test "start for open rows, cancel for canceled ones, nothing for the rest" do
      rows = [
        row(id: "op_a"),
        row(id: "op_b", confirmed: true, pushed: true),
        row(id: "op_c", cancel: true, pushed: true),
        row(id: "op_d", status: "finished", result: snapshot("completed", "op_d")),
        row(id: "op_e", status: "closed")
      ]

      assert Rules.on_join(rows) ==
               {[{"op_a", %{pushed: true}}],
                [
                  Wire.start("op_a", "shell", @args, false),
                  Wire.start("op_b", "shell", @args, true),
                  Wire.cancel("op_c")
                ]}
    end

    test "no rows, nothing to do" do
      assert Rules.on_join([]) == {[], []}
    end
  end

  describe "on_snapshot/3 (rules 3 to 6)" do
    test "a non-terminal snapshot confirms an open row" do
      for status <- @running do
        assert Rules.on_snapshot(row(), "mm1", snapshot(status)) == {%{confirmed: true}, []}

        assert Rules.on_snapshot(row(confirmed: true), "mm1", snapshot(status)) == {:none, []}

        assert Rules.on_snapshot(row(cancel: true), "mm1", snapshot(status)) ==
                 {%{confirmed: true}, []}
      end
    end

    test "a terminal snapshot finishes an open row, keeps the snapshot and acks" do
      for status <- @terminal do
        snap = snapshot(status)

        assert Rules.on_snapshot(row(), "mm1", snap) ==
                 {{:finish, %{status: "finished", confirmed: true, result: snap}},
                  [Wire.ack(@id)]}
      end
    end

    test "a terminal snapshot closes a canceled open row without keeping it" do
      for status <- @terminal do
        assert Rules.on_snapshot(row(cancel: true), "mm1", snapshot(status)) ==
                 {{:finish, %{status: "closed", confirmed: true, result: nil, output: nil}},
                  [Wire.ack(@id)]}
      end
    end

    test "a canceled open row keeps what the command printed before it stopped" do
      snap = printed("canceled", "tick 1\ntick 2\n", "")

      assert Rules.on_snapshot(row(cancel: true), "mm1", snap) ==
               {{:finish,
                 %{status: "closed", confirmed: true, result: nil, output: "tick 1\ntick 2"}},
                [Wire.ack(@id)]}
    end

    test "a finished or closed row: acked again if terminal, canceled if not" do
      for row <- [row(status: "finished", result: snapshot("completed")), row(status: "closed")] do
        for status <- @terminal,
            do:
              assert(Rules.on_snapshot(row, "mm1", snapshot(status)) == {:none, [Wire.ack(@id)]})

        for status <- @running,
            do:
              assert(
                Rules.on_snapshot(row, "mm1", snapshot(status)) == {:none, [Wire.cancel(@id)]}
              )
      end
    end

    test "an op the hub has no row for: acked if terminal, canceled if not" do
      for status <- @terminal,
          do: assert(Rules.on_snapshot(nil, "mm1", snapshot(status)) == {:none, [Wire.ack(@id)]})

      for status <- @running,
          do:
            assert(Rules.on_snapshot(nil, "mm1", snapshot(status)) == {:none, [Wire.cancel(@id)]})
    end

    test "another machine's op is foreign, whatever its state" do
      for row <- [row(), row(cancel: true), row(status: "finished"), row(status: "closed")],
          status <- @terminal ++ @running,
          do: assert(Rules.on_snapshot(row, "nas", snapshot(status)) == :foreign)
    end
  end

  describe "on_claim/1 (rule 8)" do
    test "a finished row closes and hands over its snapshot" do
      snap = snapshot("completed")

      assert Rules.on_claim(row(status: "finished", result: snap)) ==
               {%{status: "closed", result: nil}, snap}
    end

    test "nothing to claim from any other row" do
      for row <- [row(), row(status: "closed"), nil],
          do: assert(Rules.on_claim(row) == {:none, nil})
    end
  end

  describe "on_cancel/2 (rule 7)" do
    test "an open row gets cancel, and op.cancel only when online" do
      assert Rules.on_cancel(row(), true) == {%{cancel: true}, [Wire.cancel(@id)]}
      assert Rules.on_cancel(row(), false) == {%{cancel: true}, []}
    end

    test "an open row already canceled is told again, with no write" do
      assert Rules.on_cancel(row(cancel: true), true) == {:none, [Wire.cancel(@id)]}
      assert Rules.on_cancel(row(cancel: true), false) == {:none, []}
    end

    test "a finished row closes and drops its snapshot, keeping what the command printed" do
      finished = row(status: "finished", result: snapshot("completed"))

      for online <- [true, false],
          do:
            assert(
              Rules.on_cancel(finished, online) ==
                {%{status: "closed", result: nil, output: nil}, []}
            )

      printed = row(status: "finished", result: printed("completed", "done\n", ""))

      assert Rules.on_cancel(printed, true) ==
               {%{status: "closed", result: nil, output: "done"}, []}
    end

    test "a closed row or no row changes nothing" do
      for row <- [row(status: "closed"), nil],
          online <- [true, false],
          do: assert(Rules.on_cancel(row, online) == {:none, []})
    end
  end

  describe "output/1" do
    test "stdout then stderr, without their last line breaks" do
      assert Rules.output(printed("canceled", "a\nb\n", "oops\n")) == "a\nb\noops"
      assert Rules.output(printed("canceled", "", "oops")) == "oops"
      assert Rules.output(printed("completed", "a", nil)) == "a"
    end

    test "the last 8,000 characters" do
      long = String.duplicate("x", 9_000) <> "end"
      output = Rules.output(printed("canceled", long, ""))
      assert String.length(output) == 8_000
      assert String.ends_with?(output, "end")
    end

    test "nothing printed, or no output in the snapshot, is nil" do
      assert Rules.output(printed("canceled", "", "")) == nil
      assert Rules.output(snapshot("canceled")) == nil
      assert Rules.output(%{"state" => %{"result" => %{"mime" => "image/png"}}}) == nil
      assert Rules.output(nil) == nil
    end
  end

  describe "on_abandon/2 (rule 7)" do
    test "an open row gets cancel, with the facts, and op.cancel when online" do
      assert Rules.on_abandon(row(), true) ==
               {:abandoned, %{pushed: false, confirmed: false, online: true}, %{cancel: true},
                [Wire.cancel(@id)]}

      assert Rules.on_abandon(row(pushed: true), false) ==
               {:abandoned, %{pushed: true, confirmed: false, online: false}, %{cancel: true}, []}

      assert Rules.on_abandon(row(pushed: true, confirmed: true), false) ==
               {:abandoned, %{pushed: true, confirmed: true, online: false}, %{cancel: true}, []}
    end

    test "a row that finished meanwhile is claimed" do
      snap = snapshot("completed")

      for online <- [true, false] do
        assert Rules.on_abandon(row(status: "finished", result: snap), online) ==
                 {:claimed, snap, %{status: "closed", result: nil}}
      end
    end

    test "a closed row or no row changes nothing" do
      assert Rules.on_abandon(row(status: "closed", pushed: true), false) ==
               {:abandoned, %{pushed: true, confirmed: false, online: false}, :none, []}

      assert Rules.on_abandon(nil, true) ==
               {:abandoned, %{pushed: false, confirmed: false, online: true}, :none, []}
    end
  end
end
