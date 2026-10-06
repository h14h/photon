defmodule Photon.Threads.Rules do
  @moduledoc """
  The rules for threads, as pure functions: a thread's titles, and how the
  context-file tools describe files to a thread's model (sections 2.4 and
  3.3 of `docs/plans/step-2-projects-and-threads.md`).

  A thread starts with a title made from its first message (`title/1`).
  After its first run, the model is asked once for a short one
  (`title_request/2`), and what it says is taken only if it reads as a
  title (`model_title/1`). The owner can rename a thread (`rename/1`).

  Files are described by who last wrote them, from the reading thread's
  point of view: "you" for itself, "the user" for the owner, and
  `thread "Fix the pump"` for another thread, whose titles the caller
  reads and passes in.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  @title_limit 50
  @rename_limit 80
  @owner "owner"

  # How much of the first message and the first answer the title request
  # shows the model: enough to name the work, little enough to stay cheap.
  @request_excerpt 1_500

  # A model's title longer than this many words isn't a title.
  @title_words 10

  @title_system """
  You name threads in Photon, an app where an agent works on the user's \
  machines and notes. Reply with only a title for the thread below: 2 to 6 \
  words, in sentence case, naming the work rather than repeating the \
  message. No quotes, no ending punctuation, nothing else.\
  """

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
  A thread's first title, from its first message: the first line that
  isn't blank, without Markdown's marks (a heading's `#`, a list's `-`,
  backticks, `**`) and with its whitespace collapsed, cut to at most 50
  characters at a word boundary and `...` added when cut. "Untitled
  thread" when the message has no text.
  """
  @spec title(String.t()) :: String.t()
  def title(text) do
    line = text |> first_line() |> unmark()

    cond do
      line == "" -> "Untitled thread"
      String.length(line) <= @title_limit -> line
      true -> cut_at_word(line, @title_limit) <> "..."
    end
  end

  @doc """
  The request that asks the model for a thread's title, given its first
  message and its first answer (nil when it has none): the system prompt
  and one user message holding the start of each. The caller adds the
  model.
  """
  @spec title_request(String.t(), String.t() | nil) :: %{
          system: String.t(),
          messages: [PhotonCore.Message.t()]
        }
  def title_request(message, answer) do
    text =
      "Its first message:\n<<<\n#{excerpt(message)}\n>>>\n\n" <>
        "Its first answer:\n<<<\n#{excerpt(answer || "(none yet)")}\n>>>"

    %{system: @title_system, messages: [PhotonCore.Message.user(text)]}
  end

  @doc """
  The first message in a title request made by `title_request/2`'s text,
  for the scripted model; nil when the text isn't one.
  """
  @spec requested_message(String.t()) :: String.t() | nil
  def requested_message(text) do
    case Regex.run(~r/\AIts first message:\n<<<\n(.*?)\n>>>/s, text) do
      [_, message] when is_binary(message) -> message
      _no_match -> nil
    end
  end

  defp excerpt(text) do
    text = String.trim(text)

    if String.length(text) > @request_excerpt,
      do: String.slice(text, 0, @request_excerpt) <> "...",
      else: text
  end

  @doc """
  The title in a model's answer to `title_request/2`: its first line that
  isn't blank, without quotes, Markdown's marks, a "Title:" in front or
  punctuation at the end, cut to 50 characters at a word boundary.
  `:error` when nothing is left, or it runs over 10 words, so it isn't a
  title.
  """
  @spec model_title(String.t()) :: {:ok, String.t()} | :error
  def model_title(text) do
    line =
      text
      |> first_line()
      |> String.replace(~r/\Atitle\s*:\s*/iu, "")
      |> unmark()
      |> String.replace(~r/\A["'\x{201C}\x{201D}\x{2018}\x{2019}\s]+/u, "")
      |> String.replace(~r/["'\x{201C}\x{201D}\x{2018}\x{2019}\s.!,;:]+\z/u, "")

    words = length(String.split(line))

    cond do
      words == 0 or words > @title_words -> :error
      String.length(line) <= @title_limit -> {:ok, line}
      true -> {:ok, cut_at_word(line, @title_limit)}
    end
  end

  @doc """
  A title the owner typed: its whitespace collapsed, cut to at most 80
  characters. `{:error, :blank}` when it has no text.
  """
  @spec rename(String.t()) :: {:ok, String.t()} | {:error, :blank}
  def rename(text) do
    case collapse(text) do
      "" -> {:error, :blank}
      title -> {:ok, String.slice(title, 0, @rename_limit)}
    end
  end

  defp first_line(text) do
    text
    |> String.split("\n")
    |> Enum.map(&collapse/1)
    |> Enum.find("", &(&1 != ""))
  end

  # A line without Markdown's marks: a heading's, quote's or list item's in
  # front, and backticks and bold or italic stars anywhere.
  defp unmark(line) do
    line
    |> String.replace(~r/\A(?:#+|>|[-*+]|\d+[.)])\s+/u, "")
    |> String.replace(~r/`+|\*{1,3}|(?<!\w)_{1,3}|_{1,3}(?!\w)/u, "")
    |> collapse()
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
