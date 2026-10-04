defmodule Photon.Durable.Changes do
  @moduledoc """
  What a stored commit announces, worked out from the changes it made, in
  order (`Photon.Durable.Tx.run/1` collects them). Pure: `Photon.Durable.Store`
  does the broadcasting.

    * `:scopes` - per conversation ID (or `"global"` for global docs), the
      new `:entries` and the changed `:docs`, `:submissions` and `:tasks`,
      each in the order they were written
    * `:tasks` - every task the commit changed, for the task panel and the
      scheduler
    * `:signals` - the keys of signals the commit recorded
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [
      Photon.Durable.Doc,
      Photon.Durable.Entry,
      Photon.Durable.Submission,
      Photon.Durable.TaskRecord
    ]

  alias Photon.Durable.{Doc, Entry, Submission, TaskRecord, Tx}

  @type summary :: %{
          entries: [Entry.t()],
          docs: [Doc.t()],
          submissions: [Submission.t()],
          tasks: [TaskRecord.t()]
        }

  @type t :: %{
          scopes: %{String.t() => summary()},
          tasks: [TaskRecord.t()],
          signals: [String.t()]
        }

  @spec summarize([Tx.change()]) :: t()
  def summarize(changes) do
    %{
      scopes: by_scope(changes),
      tasks: for({:task, task} <- changes, do: task),
      signals: for({:signal, key} <- changes, do: key)
    }
  end

  @doc "Whether the scheduler has anything to look at: a task changed or a signal fired."
  @spec wakes_scheduler?(t()) :: boolean()
  def wakes_scheduler?(%{tasks: [], signals: []}), do: false
  def wakes_scheduler?(%{}), do: true

  defp by_scope(changes) do
    changes
    |> Enum.group_by(&scope/1)
    |> Map.delete(nil)
    |> Map.new(fn {scope, changes} -> {scope, summary(changes)} end)
  end

  defp scope({:entry, entry}), do: entry.conversation_id
  defp scope({:doc, doc}), do: doc.scope
  defp scope({:submission, submission}), do: submission.conversation_id
  defp scope({:task, task}), do: task.conversation_id
  defp scope({:signal, _key}), do: nil

  # Built back to front by prepending, so each list keeps commit order.
  defp summary(changes) do
    empty = %{entries: [], docs: [], submissions: [], tasks: []}
    changes |> Enum.reverse() |> Enum.reduce(empty, &prepend/2)
  end

  defp prepend({:entry, entry}, acc), do: %{acc | entries: [entry | acc.entries]}
  defp prepend({:doc, doc}, acc), do: %{acc | docs: [doc | acc.docs]}
  defp prepend({:submission, s}, acc), do: %{acc | submissions: [s | acc.submissions]}
  defp prepend({:task, task}, acc), do: %{acc | tasks: [task | acc.tasks]}
end
