defmodule PhotonWeb.ProjectText do
  @moduledoc """
  The words the project pages use for times, file sizes and who changed a
  context file: "5 minutes ago", "1.2 KB", "by you", "by Blip", or "in
  Fix the pump" for a change a thread made (the page can link the
  thread's title, so it isn't quoted).

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
  Who last wrote `file`: `{:by, "you"}`, `{:by, "Blip"}`, or for a
  thread `{:in, %{id: id, title: title}}` with its title from `titles`
  (thread ID to title), or `{:by, "a thread"}` when it isn't there.
  """
  @spec writer(ContextFile.t(), %{optional(String.t()) => String.t()}) ::
          {:by, String.t()} | {:in, %{id: String.t(), title: String.t()}}
  def writer(%ContextFile{updated_by: "owner"}, _titles), do: {:by, "you"}
  # Ahead of the thread clause, which would look "blip" up as a thread ID.
  def writer(%ContextFile{updated_by: "blip"}, _titles), do: {:by, "Blip"}

  def writer(%ContextFile{updated_by: thread_id}, titles) do
    case Map.fetch(titles, thread_id) do
      {:ok, title} -> {:in, %{id: thread_id, title: title}}
      :error -> {:by, "a thread"}
    end
  end

  @doc ~S"""
  When `file` changed, as words: "changed 5 minutes ago".
  """
  @spec changed_at(ContextFile.t(), DateTime.t()) :: String.t()
  def changed_at(%ContextFile{} = file, now), do: "changed " <> ago(file.updated_at, now)

  @doc ~S"""
  "changed 5 minutes ago by you", "changed just now by Blip", or
  "changed yesterday in Fix the pump" for a thread's change.
  """
  @spec changed(ContextFile.t(), %{optional(String.t()) => String.t()}, DateTime.t()) ::
          String.t()
  def changed(%ContextFile{} = file, titles, now) do
    case writer(file, titles) do
      {:by, who} -> "#{changed_at(file, now)} by #{who}"
      {:in, thread} -> "#{changed_at(file, now)} in #{thread.title}"
    end
  end

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
