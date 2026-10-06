defmodule PhotonNode.JournalTest do
  @moduledoc """
  The executor's journal on disk: listing entries, discarding one,
  forgetting one after its acknowledgement, the sweep of old output, and failures that leave
  the old entry in place. Torn writes are covered by
  `test/property/journal_property_test.exs`.
  """

  use ExUnit.Case, async: true

  import PhotonNode.Fixtures

  alias PhotonNode.Executor.Journal

  @day 24 * 60 * 60

  setup do
    dir = Path.join(System.tmp_dir!(), "photon-journal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, ops_dir: Path.join(dir, "ops")}
  end

  defp entry(id, cancel \\ false), do: %{"op" => shell_op(id: id), "cancel" => cancel}

  defp file(ops_dir, id, name), do: Path.join(Journal.op_dir(ops_dir, id), name)

  test "an operation with no entry reads as nil", %{ops_dir: ops_dir} do
    assert Journal.read(ops_dir, "op_none") == {:ok, nil}
    assert Journal.list(ops_dir) == []
  end

  test "a write replaces the entry and keeps it private", %{ops_dir: ops_dir} do
    assert Journal.write(ops_dir, "op_a", entry("op_a")) == :ok
    assert Journal.write(ops_dir, "op_a", entry("op_a", true)) == :ok
    assert Journal.read(ops_dir, "op_a") == {:ok, entry("op_a", true)}

    assert File.stat!(file(ops_dir, "op_a", "op.json")).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Journal.op_dir(ops_dir, "op_a")).mode |> Bitwise.band(0o777) == 0o700
    refute File.exists?(file(ops_dir, "op_a", "op.json.tmp"))
  end

  test "list/1 returns every readable entry in ID order", %{ops_dir: ops_dir} do
    :ok = Journal.write(ops_dir, "op_b", entry("op_b"))
    :ok = Journal.write(ops_dir, "op_a", entry("op_a", true))

    # A directory left with only output, a corrupt entry and an entry for
    # another ID are skipped.
    File.mkdir_p!(Journal.op_dir(ops_dir, "op_c"))
    File.write!(file(ops_dir, "op_c", "out"), "hello")
    File.mkdir_p!(Journal.op_dir(ops_dir, "op_d"))
    File.write!(file(ops_dir, "op_d", "op.json"), "{\"op\":")
    File.mkdir_p!(Journal.op_dir(ops_dir, "op_e"))
    File.write!(file(ops_dir, "op_e", "op.json"), Jason.encode!(entry("op_f")))
    File.write!(Path.join(ops_dir, "stray"), "")

    assert Journal.list(ops_dir) == [entry("op_a", true), entry("op_b")]
    assert {:error, "" <> _} = Journal.read(ops_dir, "op_d")
    assert {:error, "" <> _} = Journal.read(ops_dir, "op_e")
  end

  test "forget/2 deletes the entry and the command's bookkeeping, and keeps its output",
       %{ops_dir: ops_dir} do
    :ok = Journal.write(ops_dir, "op_a", entry("op_a"))
    for name <- ~w(out err pid exit stopped), do: File.write!(file(ops_dir, "op_a", name), name)

    assert Journal.forget(ops_dir, "op_a") == :ok
    assert Journal.read(ops_dir, "op_a") == {:ok, nil}
    assert Journal.list(ops_dir) == []

    assert ops_dir |> Journal.op_dir("op_a") |> File.ls!() |> Enum.sort() == ["err", "out"]

    # Forgetting again, or an operation that never had files, is fine.
    assert Journal.forget(ops_dir, "op_a") == :ok
    assert Journal.forget(ops_dir, "op_none") == :ok
  end

  test "discard/2 deletes the entry alone", %{ops_dir: ops_dir} do
    :ok = Journal.write(ops_dir, "op_a", entry("op_a"))
    for name <- ~w(out err pid), do: File.write!(file(ops_dir, "op_a", name), name)

    assert Journal.discard(ops_dir, "op_a") == :ok
    assert Journal.read(ops_dir, "op_a") == {:ok, nil}
    assert ops_dir |> Journal.op_dir("op_a") |> File.ls!() |> Enum.sort() == ["err", "out", "pid"]

    assert Journal.discard(ops_dir, "op_a") == :ok
    assert Journal.discard(ops_dir, "op_none") == :ok
  end

  test "sweep/3 removes old directories without an entry and nothing else",
       %{ops_dir: ops_dir} do
    now = System.os_time(:second)

    for id <- ~w(op_old op_young op_open) do
      :ok = Journal.write(ops_dir, id, entry(id))
      File.write!(file(ops_dir, id, "out"), "output")
    end

    :ok = Journal.forget(ops_dir, "op_old")
    :ok = Journal.forget(ops_dir, "op_young")

    File.touch!(Journal.op_dir(ops_dir, "op_old"), now - 8 * @day)
    File.touch!(Journal.op_dir(ops_dir, "op_young"), now - 6 * @day)
    File.touch!(Journal.op_dir(ops_dir, "op_open"), now - 30 * @day)

    assert Journal.sweep(ops_dir, now, 7 * @day) == ["op_old"]
    refute File.exists?(Journal.op_dir(ops_dir, "op_old"))
    assert File.exists?(file(ops_dir, "op_young", "out"))
    assert Journal.list(ops_dir) == [entry("op_open")]

    assert Journal.sweep(Path.join(ops_dir, "missing"), now, 7 * @day) == []
  end

  test "a write that fails leaves the old entry in place", %{ops_dir: ops_dir} do
    :ok = Journal.write(ops_dir, "op_a", entry("op_a"))
    # Something in the way of the temporary file.
    File.mkdir_p!(file(ops_dir, "op_a", "op.json.tmp"))

    assert {:error, "can't write " <> _} = Journal.write(ops_dir, "op_a", entry("op_a", true))
    assert Journal.read(ops_dir, "op_a") == {:ok, entry("op_a")}
  end

  test "a write into an ops directory the node can't create in fails", %{ops_dir: ops_dir} do
    File.mkdir_p!(ops_dir)
    File.chmod!(ops_dir, 0o500)
    on_exit(fn -> File.chmod(ops_dir, 0o700) end)

    assert {:error, "can't create " <> _} = Journal.write(ops_dir, "op_a", entry("op_a"))
    assert Journal.read(ops_dir, "op_a") == {:ok, nil}
  end
end
