defmodule Photon.Threads.Rules do
  @moduledoc """
  The rules for threads, as pure functions: a thread's title from its
  first message, and how the context-file tools describe files to a
  thread's model (sections 2.4 and 3.3 of
  `docs/plans/step-2-projects-and-threads.md`).

  Files are described by who last wrote them, from the reading thread's
  point of view: "you" for itself, "the user" for the owner, and
  `thread "Fix the pump"` for another thread, whose titles the caller
  reads and passes in.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @title_limit 60
  @owner "owner"

  @typedoc """
  A context file as these rules read it: a `Photon.Projects.ContextFile`,
  or any map with these fields.
  """
  @type file :: %{
          required(:name) => String.t(),
          required(:content) => String.t(),
          required(:updated_by) => String.t(),
          required(:updated_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @typedoc "Other threads' titles by ID, for naming who wrote a file."
  @type titles :: %{optional(String.t()) => String.t()}

  ## Titles

  @doc """
  A thread's title from its first message: the first line that isn't
  blank, with its whitespace collapsed, cut to at most 60 characters at a
  word boundary and `...` added when cut. "Untitled thread" when the
  message has no text.
  """
  @spec title(String.t()) :: String.t()
  def title(text) do
    line =
      text
      |> String.split("\n")
      |> Enum.map(&collapse/1)
      |> Enum.find("", &(&1 != ""))

    cond do
      line == "" -> "Untitled thread"
      String.length(line) <= @title_limit -> line
      true -> cut_at_word(line, @title_limit) <> "..."
    end
  end

  defp collapse(text), do: text |> String.split() |> Enum.join(" ")

  # At most `limit` characters, ending at a word boundary when there is
  # one, without trailing punctuation before the `...`.
  defp cut_at_word(text, limit) do
    head = String.slice(text, 0, limit + 1)

    cut =
      case Regex.run(~r/^(.*\S)\s/u, head) do
        [_, cut] -> String.slice(cut, 0, limit)
        nil -> String.slice(text, 0, limit)
      end

    String.replace(cut, ~r/[\s.,;:]+$/u, "")
  end

  ## Context files, as the tools describe them

  @doc """
  The `list_context_files` result: one line per file, newest change first,
  like `- notes.md (1,234 characters, changed 2026-10-07 14:03 UTC by
  you)`, as seen by thread `thread_id`. Other threads are named from
  `titles`.
  """
  @spec listing([file()], String.t(), titles()) :: String.t()
  def listing([], _thread_id, _titles), do: "This project has no context files yet."

  def listing(files, thread_id, titles) do
    files
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.map_join("\n", fn file ->
      "- #{file.name} (#{characters(file.content)}, #{changed(file, thread_id, titles)})"
    end)
  end

  @doc """
  The first line of a `read_context_file` result, before the content:
  `notes.md, 1,234 characters, changed 2026-10-07 14:03 UTC by you:`.
  """
  @spec file_header(file(), String.t(), titles()) :: String.t()
  def file_header(file, thread_id, titles),
    do: "#{file.name}, #{characters(file.content)}, #{changed(file, thread_id, titles)}:"

  @doc """
  The `read_context_file` error for a file called `name` that isn't there,
  listing the `names` there are.
  """
  @spec missing_file(String.t(), [String.t()]) :: String.t()
  def missing_file(name, []), do: "There's no #{name}. This project has no context files yet."

  def missing_file(name, names),
    do: "There's no #{name}. This project's context files are: #{Enum.join(names, ", ")}."

  @doc ~S'The size of `content` in characters (code points), as "1,234 characters".'
  @spec characters(String.t()) :: String.t()
  def characters(content) do
    case content |> String.to_charlist() |> length() do
      1 -> "1 character"
      n -> "#{count(n)} characters"
    end
  end

  defp changed(file, thread_id, titles) do
    "changed #{Calendar.strftime(file.updated_at, "%Y-%m-%d %H:%M UTC")} by " <>
      writer(file.updated_by, thread_id, titles)
  end

  defp writer(thread_id, thread_id, _titles), do: "you"
  defp writer(@owner, _thread_id, _titles), do: "the user"

  defp writer(other, _thread_id, titles) do
    case Map.fetch(titles, other) do
      {:ok, title} -> ~s(thread "#{title}")
      :error -> "another thread"
    end
  end

  # A count with thousands separators: 123456 to "123,456".
  defp count(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
