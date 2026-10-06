defmodule Photon.Assistant.Page do
  @moduledoc """
  The page the user has open under Blip, as pure functions (section 5.9 of
  `docs/plans/step-2-projects-and-threads.md`). Blip floats over every
  page, so a message like "what's left here?" means the project, context
  file or thread on screen.

  The web UI reports each path it shows. `at/1` says what the path is
  about; `Photon.Assistant.page_at/1` reads that project (and its file or
  thread) and makes the page with `of_project/1`, `of_file/2` or
  `of_thread/2`. The page is a string-keyed map, stored with the message it
  came with (`source["page"]`), and its `"label"` is what the message box's
  chip and the conversation show ("Garden / Fix the pump").

  At send time `Photon.Assistant` reads the page's facts fresh, and
  `note/2` writes them as a note the model sees in front of the message.
  Every part of the note is bounded (rule 73): the purpose, the number of
  files and threads, the file's content and the latest answer.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @typedoc """
  A page, as stored with the message it came with: `"kind"` (`"project"`,
  `"file"` or `"thread"`), `"project_id"`, `"slug"`, `"name"`, `"label"`,
  and `"file"` for a file's page or `"thread_id"` and `"title"` for a
  thread's (nil otherwise).
  """
  @type t :: %{String.t() => String.t() | nil}

  @typedoc "What a path is about, before anything is read."
  @type ref ::
          {:project, String.t()}
          | {:file, String.t(), String.t()}
          | {:thread, String.t(), String.t()}

  @typedoc "A project, as far as a page needs it."
  @type project :: %{
          :id => String.t(),
          :slug => String.t(),
          :name => String.t(),
          optional(atom()) => any()
        }

  @typedoc "A thread, as far as a page needs it."
  @type thread :: %{:id => String.t(), :title => String.t(), optional(atom()) => any()}

  @typedoc """
  What the note says, read at send time: the project's purpose, its
  context files' names (newest change first), its threads (most recently
  active first) and, on a file's page, the file as last saved (nil when it
  has been deleted), or on a thread's page, whether it is running and its
  latest answer (nil before it has one).
  """
  @type facts :: %{
          :purpose => String.t(),
          :files => [String.t()],
          :threads => [%{id: String.t(), title: String.t(), running?: boolean()}],
          optional(:file) => %{content: String.t()} | nil,
          optional(:thread) => %{running?: boolean(), answer: String.t() | nil}
        }

  @purpose_limit 1_000
  @file_limit 30
  @thread_limit 10
  @content_limit 4_000
  @answer_limit 1_500

  @doc """
  What the page at `path` is about. A thread's page gives `{:thread, slug,
  id}`, a context file's `{:file, slug, name}`, and any other page inside
  a project (the project, the new-thread and new-file pages) `{:project,
  slug}`. Anything else, `/projects/new` included, gives nil.
  """
  @spec at(String.t()) :: ref() | nil
  def at(path) do
    case String.split(path, "/", trim: true) do
      ["projects", "new" | _rest] -> nil
      ["projects", slug, "threads", id] when id != "new" -> {:thread, slug, id}
      ["projects", slug, "files", name] when name != "new" -> {:file, slug, name}
      ["projects", slug | _rest] -> {:project, slug}
      _other -> nil
    end
  end

  @doc "The page of a project."
  @spec of_project(project()) :: t()
  def of_project(project) do
    %{
      "kind" => "project",
      "project_id" => project.id,
      "slug" => project.slug,
      "name" => project.name,
      "thread_id" => nil,
      "title" => nil,
      "file" => nil,
      "label" => project.name
    }
  end

  @doc "The page of a project's context file, named `name`."
  @spec of_file(project(), String.t()) :: t()
  def of_file(project, name) do
    %{
      of_project(project)
      | "kind" => "file",
        "file" => name,
        "label" => "#{project.name} / #{name}"
    }
  end

  @doc "The page of a project's thread."
  @spec of_thread(project(), thread()) :: t()
  def of_thread(project, thread) do
    %{
      of_project(project)
      | "kind" => "thread",
        "thread_id" => thread.id,
        "title" => thread.title,
        "label" => "#{project.name} / #{thread.title}"
    }
  end

  @doc """
  The note the model sees in front of the user's message: a first line
  saying what the user is looking at (it starts with "[Looking at"), then
  the facts, each bounded.
  """
  @spec note(t(), facts()) :: String.t()
  def note(page, facts) do
    [
      heading(page),
      "Purpose: " <> cut(String.trim(facts.purpose), @purpose_limit),
      "Context files: " <> listed(facts.files, @file_limit),
      threads_line(page, facts.threads)
      | own(page, facts)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp heading(page) do
    where =
      ~s(the project "#{page["name"]}", folder "#{page["slug"]}" in each machine's workspace)

    case page["kind"] do
      "thread" -> ~s([Looking at the thread "#{page["title"]}" in #{where}])
      "file" -> "[Looking at #{page["file"]} in #{where}]"
      _project -> "[Looking at #{where}]"
    end
  end

  # On a thread's page the thread itself has its own lines, so the list
  # names the others, and says nothing when there are none.
  defp threads_line(%{"kind" => "thread", "thread_id" => id}, threads) do
    case Enum.reject(threads, &(&1.id == id)) do
      [] -> nil
      others -> "Other threads: " <> listed(Enum.map(others, &thread_text/1), @thread_limit)
    end
  end

  defp threads_line(_page, threads),
    do: "Threads: " <> listed(Enum.map(threads, &thread_text/1), @thread_limit)

  defp thread_text(thread),
    do: ~s{"#{thread.title}" (#{if(thread.running?, do: "running", else: "idle")})}

  defp own(%{"kind" => "file", "file" => name}, facts), do: file_lines(name, facts[:file])
  defp own(%{"kind" => "thread"}, facts), do: [thread_line(facts[:thread])]
  defp own(_page, _facts), do: []

  defp file_lines(name, nil), do: ["#{name} doesn't exist anymore; it was deleted."]
  defp file_lines(name, %{content: ""}), do: ["#{name} is empty, as last saved."]

  defp file_lines(name, %{content: content}) do
    length = String.length(content)

    cut_note =
      if length > @content_limit,
        do: ["(cut; the file has #{count(length)} characters)"],
        else: []

    [
      "#{name} as last saved, between the lines:",
      "-----",
      String.slice(content, 0, @content_limit),
      "-----"
      | cut_note
    ]
  end

  defp thread_line(nil), do: nil

  defp thread_line(%{running?: running?, answer: answer}) do
    state = "The thread is #{if(running?, do: "running", else: "idle")}."

    case answer do
      nil ->
        state <> " It hasn't answered yet."

      answer ->
        if String.length(answer) > @answer_limit,
          do:
            ~s(#{state} The end of its latest answer: "...#{String.slice(answer, -@answer_limit, @answer_limit)}"),
          else: ~s(#{state} Its latest answer: "#{answer}")
    end
  end

  # A list of names, the first `limit` of them, and how many more.
  defp listed([], _limit), do: "none yet"

  defp listed(items, limit) do
    {shown, rest} = Enum.split(items, limit)
    more = if rest == [], do: "", else: ", and #{length(rest)} more"
    Enum.join(shown, ", ") <> more
  end

  defp cut(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "...", else: text
  end

  # 12345 as "12,345".
  defp count(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
