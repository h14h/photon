defmodule PhotonNode.Executor.Rules do
  @moduledoc """
  The executor's decisions about starting, resuming and restarting the hub's
  operations (`docs/operations.md`, node rules 1 to 3, 7 and 8). Pure: the
  executor reads its journal and the operation registry, calls one of
  these, and does what it says. A `decision`:

    * `:run`: a new operation. Journal its `ready` snapshot, then start it.
    * `{:resend, cancel?}`: the operation has finished, or a process is
      running it. Start nothing; send its latest snapshot again.
    * `{:resume, cancel?}`: unfinished, and nothing runs it. Start it again
      from its journaled snapshot with `Ops.add/2`, which never reruns a
      shell command (`Ops.Shell` recovers it from its files).
    * `:lost`: the hub has seen the operation but there is no journal for
      it. Run nothing and answer with `Request.lost/2`.

  `cancel?` is true when the entry says canceled and the operation is
  unfinished: the executor follows `Ops.add/2` with `Ops.cancel/1`, and
  never resumes in `canceling` (node rule 2).
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Operation

  @typedoc ~S|A journal entry: `%{"op" => snapshot, "cancel" => boolean}`.|
  @type entry :: %{required(String.t()) => term()}

  @typedoc "What to do with an operation; see the moduledoc."
  @type decision :: :run | {:resend, boolean()} | {:resume, boolean()} | :lost

  @clean_exits [:normal, :shutdown, :noproc]

  @doc """
  What `op.start` does, given the operation's journal entry (or nil),
  whether the hub has seen a snapshot for it (`known`) and whether a
  process runs it. A journaled operation is never run again (node rule 2);
  an unjournaled one runs only if the hub hasn't seen it (rules 1 and 3).
  """
  @spec on_start(entry() | nil, boolean(), boolean()) :: decision()
  def on_start(nil, false = _known, _running), do: :run
  def on_start(nil, true = _known, _running), do: :lost
  def on_start(entry, _known, running), do: journaled(entry, running)

  @doc """
  What the executor's start-up scan does with a journal entry. A finished
  operation is skipped: it waits for the next join, which sends its
  snapshot, and for its `op.ack`.
  """
  @spec on_scan(entry(), boolean()) :: :skip | {:resend, boolean()} | {:resume, boolean()}
  def on_scan(entry, running) do
    if finished?(entry), do: :skip, else: journaled(entry, running)
  end

  @doc """
  What an operation process's exit means, given its journal entry (or nil),
  the exit reason and whether it was restarted once already. A finished
  operation's exit is ignored. A clean exit (`:normal`, `:shutdown` or
  `:noproc`) before the terminal snapshot is restarted once from the
  journal, since an operation process stops without a result when its
  owner didn't take a checkpoint. A crash, or a second clean exit, fails
  the operation.
  """
  @spec down(entry() | nil, term(), boolean()) ::
          :ignore | {:restart, boolean()} | {:fail, String.t()}
  def down(nil, _reason, _restarted), do: :ignore

  def down(entry, reason, restarted) do
    cond do
      finished?(entry) -> :ignore
      reason in @clean_exits and not restarted -> {:restart, canceled?(entry)}
      true -> {:fail, "the operation process exited: #{Exception.format_exit(reason)}"}
    end
  end

  @doc """
  What happens to an operation's journal entry (or nil) when a terminal
  snapshot for it couldn't be journaled and was forwarded anyway (node
  rule 8). A `ready` entry is removed: resumed, it would start the
  operation after the hub was told how it ended. Any later entry is kept,
  since a resume from it only reports the outcome again (`Ops.Shell`
  recovers a started command from its files and never starts it twice).
  """
  @spec on_unjournaled(entry() | nil) :: :remove | :keep
  def on_unjournaled(%{"op" => %{"status" => "ready"}}), do: :remove
  def on_unjournaled(_entry), do: :keep

  defp journaled(entry, running) do
    cond do
      finished?(entry) -> {:resend, false}
      running -> {:resend, canceled?(entry)}
      true -> {:resume, canceled?(entry)}
    end
  end

  defp finished?(%{"op" => op}), do: Operation.terminal?(op)

  defp canceled?(entry), do: entry["cancel"] == true
end
