defmodule Photon.Signals.Text do
  @moduledoc """
  The words of what reaches Blip unasked (sections 3.4, 4.5, 4.6 and 4.7
  of `docs/plans/step-4-blip-as-coordinator.md`).

  A signal is one text part of a message to Blip, which the model reads:
  a thread update (`update/2`) or a question (`question/2`). They name
  the project and thread by name and title as they are when the signal is
  posted, and the thread by ID, which Blip's tools take; a question is
  also named by its ID. The note in front of the owner's answer
  (`answer_note/1`) is read by the model too.

  The notices (`escalated/1`, `withdrawn/1`) are entries in Blip's
  conversation for the owner to read; the model never sees them, so they
  name the thread by title and carry no ID.

  Each function takes a signal's ref (`Photon.Signals.Rules.ref/0`) for
  where the thread is, and is total: a missing field reads as empty, a
  missing note or reason is left out.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  # The longest note or reason an update carries, and the longest question.
  @detail_limit 600
  @question_limit 2_000

  @doc """
  A thread update, for a ref with `"status"` `"finished"`, `"asking"` or
  `"failed"`, and `detail`, the run's note (finished, asking) or the
  failure's reason, cut to #{@detail_limit} characters on one line.
  """
  @spec update(map(), String.t() | nil) :: String.t()
  def update(ref, detail) do
    "[Thread update] " <> where(ref) <> " " <> outcome(field(ref, "status"), one_line(detail))
  end

  defp outcome("finished", nil), do: "finished."
  defp outcome("finished", note), do: "finished. It said: " <> note
  defp outcome("asking", nil), do: "is waiting on the user."
  defp outcome("asking", note), do: "is waiting on the user: " <> note
  defp outcome("failed", nil), do: "failed."
  defp outcome("failed", reason), do: "failed: " <> reason
  defp outcome(_status, nil), do: "changed."
  defp outcome(_status, detail), do: "changed: " <> detail

  @doc """
  An `ask_blip` question, for a ref with `"question_id"`: a header line,
  then the question as the thread asked it, cut to #{@question_limit}
  characters.
  """
  @spec question(map(), String.t() | nil) :: String.t()
  def question(ref, text) do
    header = "[Question #{field(ref, "question_id")} from #{where(ref)}]"

    case cut(text, @question_limit) do
      nil -> header
      text -> header <> "\n" <> text
    end
  end

  @doc """
  The note in front of the owner's answer in Blip's conversation, for a
  question's ref: the answer has already gone to the thread.
  """
  @spec answer_note(map()) :: String.t()
  def answer_note(ref) do
    "[Your answer to #{field(ref, "question_id")} from #{where(ref)} went straight to the thread.]"
  end

  @doc "The notice when the hub passed a question Blip didn't get to on to the owner."
  @spec escalated(map()) :: String.t()
  def escalated(ref), do: "I didn't get to #{title(ref)}'s question, so it's with you now."

  @doc "The notice when a thread whose question was with the owner was stopped."
  @spec withdrawn(map()) :: String.t()
  def withdrawn(ref), do: "#{title(ref)} was stopped, so its question was withdrawn."

  # `Garden / "Fix the pump" (c_123)`.
  defp where(ref), do: "#{field(ref, "project")} / #{title(ref)} (#{field(ref, "thread_id")})"

  defp title(ref), do: ~s{"#{field(ref, "title")}"}

  defp field(ref, key) when is_map(ref) do
    case Map.get(ref, key) do
      value when is_binary(value) -> value
      _missing -> ""
    end
  end

  defp field(_ref, _key), do: ""

  defp one_line(text) when is_binary(text),
    do: text |> String.split() |> Enum.join(" ") |> cut(@detail_limit)

  defp one_line(_text), do: nil

  # Trimmed and at most `limit` characters, ending in "..." when cut; nil
  # when there is no text.
  defp cut(text, limit) when is_binary(text) do
    case String.trim(text) do
      "" ->
        nil

      text ->
        if String.length(text) <= limit,
          do: text,
          else: String.trim_trailing(String.slice(text, 0, limit - 3)) <> "..."
    end
  end

  defp cut(_text, _limit), do: nil
end
