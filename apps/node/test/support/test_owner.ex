defmodule PhotonNode.TestOwner do
  @moduledoc """
  An operation owner (`PhotonNode.Ops.Owner`) for boundary tests.
  Its owner ID is a test process, which gets what an operation sends:

    * `{:checkpoint, op}` as a `GenServer.call`, answered by the test
      (`await_status/2` answers each with `:ok`, or another reply)
    * `{:report, op}` for every snapshot
    * `{:output, op_id, stream, text}` for live output

  Like every owner, it never lets an exit reach the operation: a checkpoint
  whose test process is gone is `:ignored`.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour PhotonNode.Ops.Owner

  import ExUnit.Assertions

  @doc "The owner pair for `Ops.add/2`, reporting to `pid` (the caller by default)."
  def owner(pid \\ self()), do: {__MODULE__, pid}

  @impl true
  def checkpoint(pid, op) do
    GenServer.call(pid, {:checkpoint, op}, :infinity)
  catch
    :exit, _ -> :ignored
  end

  @impl true
  def report(pid, op) do
    send(pid, {:report, op})
    :ok
  end

  @impl true
  def output(pid, op_id, stream, text) do
    send(pid, {:output, op_id, stream, text})
    :ok
  end

  @doc """
  Answers checkpoints with `reply` until a snapshot with `status` is
  reported, and returns it.
  """
  def await_status(status, reply \\ :ok, timeout \\ 10_000) do
    await(&match?(%{"status" => ^status}, &1), reply, timeout, "no #{status} snapshot")
  end

  @doc "Answers checkpoints with `:ok` until a snapshot with a process group is reported."
  def await_pgid(timeout \\ 10_000) do
    await(
      &match?(%{"state" => %{"pgid" => pgid}} when is_integer(pgid) and pgid > 0, &1),
      :ok,
      timeout,
      "no snapshot with a process group"
    )
  end

  defp await(match?, reply, timeout, failure) do
    receive do
      {:"$gen_call", from, {:checkpoint, _op}} ->
        GenServer.reply(from, reply)
        await(match?, reply, timeout, failure)

      {:report, op} ->
        if match?.(op), do: op, else: await(match?, reply, timeout, failure)
    after
      timeout -> flunk(failure)
    end
  end
end
