defmodule PhotonWeb.ProjectText do
  @moduledoc """
  The words the project pages use for times, file sizes and who changed a
  context file: "5 minutes ago", "1.2 KB", "by you" or `by "Fix the pump"`.

  Pure: the time to measure from and the thread titles are passed in, so
  a page reads the clock and the titles once and these only format them.
  """

  alias Photon.Projects.ContextFile

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour

  @doc """
  How long before `now` the time `at` was: "just now", "5 minutes ago",
  "3 hours ago", "yesterday", "4 days ago", and past a week the date, "on
  Mar 4" (with the year when it isn't `now`'s).
  """
  @spec ago(DateTime.t(), DateTime.t()) :: String.t()
  def ago(at, now) do
    seconds = max(DateTime.diff(now, at), 0)

    cond do
      seconds < 7 * @day -> recent(seconds)
      at.year == now.year -> "on " <> Calendar.strftime(at, "%b %-d")
      true -> "on " <> Calendar.strftime(at, "%b %-d, %Y")
    end
  end

  defp recent(seconds) do
    cond do
      seconds < @minute -> "just now"
      seconds < @hour -> count(div(seconds, @minute), "minute") <> " ago"
      seconds < @day -> count(div(seconds, @hour), "hour") <> " ago"
      seconds < 2 * @day -> "yesterday"
      true -> count(div(seconds, @day), "day") <> " ago"
    end
  end

  @doc ~S"""
  Who last wrote `file`: "you", or the writing thread's title in quotes
  from `titles` (thread ID to title), or "a thread" when it isn't there.
  """
  @spec writer(ContextFile.t(), %{optional(String.t()) => String.t()}) :: String.t()
  def writer(%ContextFile{updated_by: "owner"}, _titles), do: "you"

  def writer(%ContextFile{updated_by: thread_id}, titles) do
    case Map.fetch(titles, thread_id) do
      {:ok, title} -> ~s("#{title}")
      :error -> "a thread"
    end
  end

  @doc ~S"""
  "changed 5 minutes ago by you", or `changed yesterday by "Fix the pump"`.
  """
  @spec changed(ContextFile.t(), %{optional(String.t()) => String.t()}, DateTime.t()) ::
          String.t()
  def changed(%ContextFile{} = file, titles, now),
    do: "changed #{ago(file.updated_at, now)} by #{writer(file, titles)}"

  @doc ~s(A file's size: "Empty", "320 B", "4.2 KB" or "1.1 MB".)
  @spec size(String.t()) :: String.t()
  def size(""), do: "Empty"

  def size(content) do
    case byte_size(content) do
      bytes when bytes < 1_000 -> "#{bytes} B"
      bytes when bytes < 1_000_000 -> "#{decimal(bytes / 1_000)} KB"
      bytes -> "#{decimal(bytes / 1_000_000)} MB"
    end
  end

  # One decimal under ten, none above: "4.2", "12".
  defp decimal(value) when value < 10, do: :erlang.float_to_binary(value, decimals: 1)
  defp decimal(value), do: value |> round() |> Integer.to_string()

  defp count(1, word), do: "1 " <> word
  defp count(n, word), do: "#{n} #{word}s"
end
