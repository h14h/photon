defmodule Photon.Signals.Text do
  @moduledoc """
  The words of what reaches Blip unasked.

  What the model reads (updates, questions, the note before the owner's
  answer) names the thread by ID, which Blip's tools take, as well as by
  title. The notices (`escalated/1`, `withdrawn/1`) are for the owner
  only; the model never sees them, so they carry no ID.

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

  @doc "The note in front of the owner's answer: it has already gone to the thread."
  @spec answer_note(map()) :: String.t()
  def answer_note(ref) do
    "[Your answer to #{field(ref, "question_id")} from #{where(ref)} went straight to the thread.]"
  end

  @doc """
  The notice when the hub passed a question Blip didn't handle with a
  tool on to the owner. It says nothing about why: Blip may well have
  asked it in prose already.
  """
  @spec escalated(map()) :: String.t()
  def escalated(ref),
    do: "Here's #{title(ref)}'s question as the thread asked it. Your answer goes straight to it."

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

  # Nil when there is no text.
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
