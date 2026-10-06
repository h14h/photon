defmodule PhotonNode.Property.JournalTest do
  @moduledoc """
  An operation's journal entry survives a crash at any point of a write:
  whatever mix of completed writes, writes torn partway through the
  temporary file and writes that crashed between the sync and the rename
  came before, `read/2` returns the last entry that was fully written (or
  none), and the next write still lands.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import PhotonNode.Fixtures

  alias PhotonCore.Operation
  alias PhotonNode.Executor.Journal

  @id "op_journal"

  setup do
    dir = Path.join(System.tmp_dir!(), "photon-journal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  ## Generators

  defp snapshot do
    gen all(
          status <- member_of(Operation.statuses()),
          command <- string(:printable, max_length: 40),
          out <- string(:utf8, max_length: 40),
          pgid <- integer(0..100_000)
        ) do
      [id: @id, command: command]
      |> shell_op()
      |> Operation.advance(status, %{"pgid" => pgid, "result" => %{"out" => out}})
    end
  end

  defp entry do
    gen all(op <- snapshot(), cancel <- boolean()) do
      %{"op" => op, "cancel" => cancel}
    end
  end

  # What happens to one write: it completes, the crash tears the
  # temporary file after `cut` bytes, or the crash comes after the
  # temporary file is synced but before it is renamed.
  defp step do
    one_of([
      map(entry(), &{:write, &1}),
      map({entry(), non_negative_integer()}, fn {entry, cut} -> {:torn, entry, cut} end),
      map(entry(), &{:unrenamed, &1})
    ])
  end

  ## Properties

  property "read/2 returns the last fully written entry after any crash", %{dir: dir} do
    check all(steps <- list_of(step(), min_length: 1, max_length: 8), max_runs: 60) do
      ops_dir = Path.join(dir, "ops#{System.unique_integer([:positive])}")

      last =
        Enum.reduce(steps, nil, fn step, last ->
          last = apply_step(step, ops_dir, last)
          assert Journal.read(ops_dir, @id) == {:ok, last}
          last
        end)

      # Whatever a crash left behind, the next write lands.
      next = %{"op" => shell_op(id: @id), "cancel" => last == nil}
      assert Journal.write(ops_dir, @id, next) == :ok
      assert Journal.read(ops_dir, @id) == {:ok, next}
      assert Journal.list(ops_dir) == [next]
    end
  end

  defp apply_step({:write, entry}, ops_dir, _last) do
    assert Journal.write(ops_dir, @id, entry) == :ok
    entry
  end

  defp apply_step({:torn, entry, cut}, ops_dir, last) do
    data = Jason.encode!(entry)
    write_tmp(ops_dir, binary_part(data, 0, rem(cut, byte_size(data))))
    last
  end

  defp apply_step({:unrenamed, entry}, ops_dir, last) do
    write_tmp(ops_dir, Jason.encode!(entry))
    last
  end

  defp write_tmp(ops_dir, data) do
    dir = Journal.op_dir(ops_dir, @id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "op.json.tmp"), data)
  end
end
