defmodule Photon.Assistant.Readout do
  @moduledoc """
  The texts Blip's read tools return: `list_projects` (`projects/3`),
  `read_project` (`project/2`), `list_threads` (`threads/2`) and
  `read_thread` (`thread/3`), what its file tools say after a write or an
  edit (`file_written/4`, `file_edited/2`), what its schedule and skill
  tools say (`scheduled/3`, `schedules/4` for a project's, `skills/1`,
  `skill_set/3`), and the words for a project, thread, question or skill
  that isn't there (`unknown_project/2`, `unknown_thread/1`,
  `unknown_question/2`, `unknown_skill/2`). Its file tools' listing and read
  text are the threads' (`Photon.Threads.describe_files/2`,
  `read_file_text/3`), seen from Blip's side.

  It takes the rows, the board entries (`Photon.Threads.board/1`) and the
  time, all passed in. A thread's state reads as `Photon.Threads.State.label/2`
  words it, turned to Blip's side: the page's "Waiting on you" is
  "waiting on the user" here, and "Asking Blip" is "asking you". A thread's
  open `ask_blip` questions show with their IDs wherever the thread is
  listed, so Blip can name one in any run.

  `read_thread` shows a thread's messages, its answers and a line per tool
  call, never a tool's output or images: an item over 1,500 characters is
  cut in the middle, and the items are cut to 12,000 characters from the
  end.
  """

  # Functional core: no processes, no I/O. The time comes in as an argument.
  use Boundary, type: :strict, deps: [Photon.Threads, PhotonCore]

  alias Photon.Threads.State
  alias PhotonCore.Message

  @typedoc "A project row, or a map with its fields."
  @type project :: %{
          required(:id) => String.t(),
          required(:slug) => String.t(),
          required(:name) => String.t(),
          required(:purpose) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "A thread on the board, as `Photon.Threads.board/1` gives it."
  @type board_entry :: %{
          required(:id) => String.t(),
          required(:thread) => map(),
          required(:project) => %{id: String.t(), slug: String.t(), name: String.t()},
          required(:state) => State.t(),
          required(:questions) => [map()],
          optional(atom()) => term()
        }

  @typedoc "A context file row, or a map with its fields."
  @type file :: %{
          required(:name) => String.t(),
          required(:content) => String.t(),
          required(:updated_at) => DateTime.t(),
          required(:updated_by) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  A schedule as `read_project` lists it: its ID, when it fires in words
  (`Photon.Schedules.when_text/1`), its state and next time
  (`Photon.Schedules.list/1`), its prompt, and the thread it wakes (nil
  when it starts a new one each time).
  """
  @type schedule :: %{
          id: String.t(),
          when: String.t(),
          state: :waiting | :done | {:stopped, String.t()},
          next_at: DateTime.t() | nil,
          prompt: String.t(),
          thread_id: String.t() | nil
        }

  @typedoc """
  Where a project schedule from Blip's `schedule` tool fires: the
  project's slug, the thread it wakes (nil for a new thread each time)
  and whether it repeats.
  """
  @type schedule_place :: %{
          slug: String.t(),
          thread: %{id: String.t(), title: String.t()} | nil,
          repeats?: boolean()
        }

  @typedoc """
  A skill as `list_skills` shows it: its name, description and where it
  is on, as Blip names the places (`you`, or a project's slug).
  """
  @type skill :: %{name: String.t(), description: String.t(), on_for: [String.t()]}

  @typedoc """
  What `read_project` shows besides the project: its files, threads,
  schedules and skills on, and each machine with skills on and their
  names.
  """
  @type project_facts :: %{
          files: [file()],
          board: [board_entry()],
          schedules: [schedule()],
          skills: [String.t()],
          machine_skills: [{String.t(), [String.t()]}]
        }

  @typedoc "A conversation entry (`Photon.Durable.Entry`), or a map with its fields."
  @type entry :: %{
          required(:kind) => String.t(),
          required(:data) => map(),
          optional(atom()) => term()
        }

  @typedoc "The filter `list_threads` was given: a project's slug, a state, or neither."
  @type filter :: %{project: String.t() | nil, state: State.t() | nil}

  # The states in the order counts and filters name them, with the name
  # `list_threads`' `state` argument takes and the words for a count.
  @states [
    {:running, "running", "running"},
    {:asking, "asking", "asking you"},
    {:waiting, "waiting", "waiting on the user"},
    {:failed, "failed", "failed"},
    {:unread, "unread", "finished and not yet seen by the user"},
    {:quiet, "quiet", "quiet"},
    {:idle, "idle", "idle"}
  ]

  # How many threads a list shows before it says how many more there are.
  @thread_limit 40
  # The longest purpose sentence `list_projects` shows.
  @purpose_limit 120
  # The longest skill description `list_skills` shows.
  @description_limit 200
  # The longest question a thread's line shows.
  @question_limit 280
  # `read_thread`: the longest item, and the most characters of items.
  @item_limit 1_500
  @items_limit 12_000

  ## The state argument

  @doc "The names `list_threads`' `state` argument takes, in order."
  @spec state_names() :: [String.t()]
  def state_names, do: for({_state, name, _words} <- @states, do: name)

  @doc "The state a `state` argument names, or nil for nil or a name it doesn't know."
  @spec state_named(String.t() | nil) :: State.t() | nil
  def state_named(name) do
    Enum.find_value(@states, fn
      {state, ^name, _words} -> state
      _other -> nil
    end)
  end

  ## list_projects

  @doc """
  The `list_projects` result: one line per project, in the order given,
  with its name, the first sentence of its purpose, how many of its
  threads are in each state, and how many context files it has
  (`file_counts`, by project ID).
  """
  @spec projects([project()], [board_entry()], %{optional(String.t()) => non_neg_integer()}) ::
          String.t()
  def projects([], _board, _file_counts), do: "No projects yet."

  def projects(projects, board, file_counts) do
    by_project = Enum.group_by(board, & &1.project.id)

    Enum.map_join(projects, "\n", fn project ->
      counts = by_project |> Map.get(project.id, []) |> state_counts()

      "#{project.slug}: #{sentence(project.name)} #{first_sentence(project.purpose)} " <>
        "#{counts} #{files_count(Map.get(file_counts, project.id, 0))}"
    end)
  end

  defp state_counts([]), do: "No threads."

  defp state_counts(entries) do
    counts = Enum.frequencies_by(entries, & &1.state)

    words =
      for {state, _name, words} <- @states,
          Map.has_key?(counts, state),
          do: "#{Map.fetch!(counts, state)} #{words}"

    Enum.join(words, ", ") <> "."
  end

  defp files_count(0), do: "No context files."
  defp files_count(1), do: "1 context file."
  defp files_count(n), do: "#{n} context files."

  # A name or a description as a sentence: with a full stop unless it ends
  # in one already.
  defp sentence(text) do
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  # The first sentence of a purpose, whitespace collapsed, at most
  # @purpose_limit characters.
  defp first_sentence(purpose) do
    text = one_line(purpose)

    sentence =
      case Regex.run(~r/\A.*?[.!?](?=\s|\z)/u, text) do
        [first] -> first
        nil -> sentence(text)
      end

    cut_words(sentence, @purpose_limit)
  end

  ## read_project

  @doc """
  The `read_project` result: the project's name, slug, ID and whole
  purpose; its context files (size, changed when and by whom, as Blip sees
  it); its threads, most recent first, at most #{@thread_limit}, each
  with its state and note; its schedules; and the skills turned on for
  it, then, when any machine has skills on, a line naming them, since the
  project's threads get those too for work on that machine. An empty
  list says "none".
  """
  @spec project(project(), project_facts()) :: String.t()
  def project(project, facts) do
    titles = Map.new(facts.board, &{&1.id, &1.thread.title})

    Enum.join(
      [
        "#{project.name} (#{project.slug}, ID #{project.id})\nPurpose: #{String.trim(project.purpose || "")}",
        files_section(facts.files, titles),
        threads_section(facts.board),
        schedules_section(facts.schedules, titles),
        skills_section(facts.skills, facts.machine_skills)
      ],
      "\n\n"
    )
  end

  defp files_section([], _titles), do: "Context files: none."

  defp files_section(files, titles) do
    lines =
      files
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.map_join("\n", fn file ->
        "- #{file.name} (#{characters(file.content)}, changed #{time(file.updated_at)} by " <>
          "#{writer(file.updated_by, titles)})"
      end)

    "Context files:\n" <> lines
  end

  defp threads_section([]), do: "Threads: none."

  defp threads_section(board) do
    {shown, more} = Enum.split(board, @thread_limit)
    lines = Enum.map_join(shown, "\n", &("- " <> thread_line(&1, false)))
    "Threads (#{length(board)}, most recent first):\n" <> lines <> more_line(more, "with a state")
  end

  defp schedules_section([], _titles), do: "Schedules: none."

  defp schedules_section(schedules, titles) do
    "Schedules:\n" <> Enum.map_join(schedules, "\n", &schedule_line(&1, titles))
  end

  defp schedule_line(schedule, titles) do
    ~s(- #{schedule.id}: #{schedule.when}; #{schedule_state(schedule)}; ) <>
      ~s(#{schedule_target(schedule.thread_id, titles)}: "#{one_line(schedule.prompt)}")
  end

  defp schedule_state(%{state: :waiting, next_at: %DateTime{} = next_at}),
    do: "next #{time(next_at)}"

  defp schedule_state(%{state: {:stopped, reason}}), do: "stopped after an error (#{reason})"
  defp schedule_state(_done), do: "done, won't fire again"

  defp schedule_target(nil, _titles), do: "starts a new thread each time"

  defp schedule_target(thread_id, titles) do
    case Map.fetch(titles, thread_id) do
      {:ok, title} -> ~s(wakes #{thread_id} "#{title}")
      :error -> "wakes #{thread_id}"
    end
  end

  defp skills_section(names, machines) do
    own =
      case names do
        [] -> "Skills on: none."
        names -> "Skills on: " <> Enum.join(names, ", ") <> "."
      end

    case machines do
      [] ->
        own

      machines ->
        on_machines =
          Enum.map_join(machines, "; ", fn {id, names} ->
            "#{id} has #{Enum.join(names, ", ")}"
          end)

        own <> "\nAlso offered to its threads, for work on that machine: " <> on_machines <> "."
    end
  end

  ## list_threads

  @doc """
  The `list_threads` result: the board entries that pass `filter`, one
  line each, most recent activity first (the board's order), at most
  #{@thread_limit}, then how many more there are.
  """
  @spec threads([board_entry()], filter()) :: String.t()
  def threads(board, filter) do
    case Enum.filter(board, &matches?(&1, filter)) do
      [] ->
        no_threads(filter)

      entries ->
        {shown, more} = Enum.split(entries, @thread_limit)

        Enum.map_join(shown, "\n", &thread_line(&1, true)) <>
          more_line(more, "name a project or a state")
    end
  end

  defp matches?(entry, filter) do
    (filter.project in [nil, entry.project.slug] or filter.project == entry.project.id) and
      filter.state in [nil, entry.state]
  end

  defp no_threads(%{project: project, state: state}) do
    place = if project, do: " in #{project}", else: ""

    case state do
      nil -> "No threads#{place}."
      state -> "No threads#{place} are #{count_words(state)}."
    end
  end

  defp more_line([], _how), do: ""

  defp more_line(more, "with a state"),
    do: "\n...and #{length(more)} more; list_threads with a state shows fewer."

  defp more_line(more, how), do: "\n...and #{length(more)} more; #{how} to see fewer."

  # `c_123 "Fix the pump" (garden): waiting on the user: <note>`, the
  # project left out when the list is a project's own.
  defp thread_line(entry, with_project?) do
    project = if with_project?, do: " (#{entry.project.slug})", else: ""
    head = ~s(#{entry.id} "#{entry.thread.title}"#{project}: #{state_words(entry)})

    case thread_note(entry) do
      nil -> head
      note -> head <> ": " <> note
    end
  end

  # A thread's open questions when it has any, else its last run's note.
  defp thread_note(%{questions: [_ | _] = questions}),
    do: Enum.map_join(questions, "; ", &question_words/1)

  defp thread_note(%{state: state, thread: thread}) when state != :running,
    do: thread.last_run_note

  defp thread_note(_running), do: nil

  defp question_words(question) do
    "question #{question.id}, #{holder(question.status)}: " <>
      cut_words(one_line(question.question), @question_limit)
  end

  defp holder("with_owner"), do: "passed to the user"
  defp holder(_asked), do: "with you"

  ## read_thread

  @doc """
  The `read_thread` result: a header (the thread's title and ID, its
  project, state, who started it, its last activity at `now`, how its
  last run ended, its open questions), then its last `last` items from
  `entries` (oldest first, as `Photon.Threads.recent_entries/2` gives
  them): `[user]`, `[Blip]` and `[scheduled]` messages, `[thread]`
  answers, and a `[tool]` line per call. An item over #{@item_limit}
  characters is cut in the middle; the items are cut to #{@items_limit}
  characters from the end, with how many earlier ones were left out.
  """
  @spec thread(board_entry(), [entry()], %{last: pos_integer(), now: DateTime.t()}) :: String.t()
  def thread(entry, entries, %{last: last, now: now}) do
    items = entries |> items() |> Enum.take(-last)
    header = header(entry, now)

    case items do
      [] -> header <> "\n\nNo messages yet."
      items -> header <> "\n\n" <> fit(items)
    end
  end

  defp header(%{thread: thread, project: project} = entry, now) do
    [
      "\"#{thread.title}\" (#{entry.id}), in #{project.name} (#{project.slug})",
      "State: " <> state_words(entry),
      "Started by #{starter(thread.started_by)}; last activity #{when_ago(thread.active_at, now)}",
      last_run(thread)
      | Enum.map(entry.questions, &("Open " <> question_words(&1)))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp starter("blip"), do: "you"
  defp starter("schedule"), do: "a schedule"
  defp starter(_owner), do: "the user"

  defp last_run(%{last_run_status: nil}), do: nil

  defp last_run(%{last_run_status: status, last_run_ended_at: ended_at} = thread) do
    line = "Last run #{run_words(status)} #{time(ended_at)}"

    case thread.last_run_note do
      nil -> line
      note -> line <> ": " <> note
    end
  end

  defp run_words("done"), do: "finished"
  defp run_words("failed"), do: "failed"
  defp run_words("stopped"), do: "was stopped"
  defp run_words(other), do: "ended (#{other})"

  # The entries as items, oldest first: messages, answers with text, and
  # a line per tool result (the call's arguments from the assistant entry
  # that made it, when it is among the entries).
  defp items(entries) do
    calls =
      for %{kind: "assistant", data: data} <- entries,
          call <- Message.tool_calls(data["message"]),
          into: %{},
          do: {call["id"], call}

    Enum.flat_map(entries, &item(&1, calls))
  end

  defp item(%{kind: "user", data: data}, _calls) do
    case text(data["message"]) do
      "" -> []
      text -> ["[#{sender(data["source"])}] " <> text]
    end
  end

  defp item(%{kind: "assistant", data: data}, _calls) do
    case text(data["message"]) do
      "" -> []
      text -> ["[thread] " <> text]
    end
  end

  defp item(%{kind: "tool_result", data: data}, calls) do
    call = Map.get(calls, get_in(data, ["message", "tool_call_id"]), %{})

    args =
      case Message.arguments(call) do
        {:ok, args} -> args
        {:error, _reason} -> %{}
      end

    ["[tool] " <> tool_line(data["name"], args, data)]
  end

  defp item(_entry, _calls), do: []

  defp sender(%{"kind" => "blip"}), do: "Blip"
  defp sender(%{"kind" => "routine"}), do: "scheduled"
  defp sender(_user), do: "user"

  defp text(message), do: message |> Message.text_of() |> String.trim()

  # What a call did, in a line: what it acted on, and how it ended.
  defp tool_line(name, args, data) do
    details = if is_map(data["details"]), do: data["details"], else: %{}
    tool_words(name, args, details) <> ending(name, data, details)
  end

  defp tool_words("shell", args, details),
    do: "Ran `#{one_line(args["command"] || details["command"])}`" <> on(args, details)

  defp tool_words("view_image", args, details),
    do: "Looked at #{args["path"] || details["path"]}" <> on(args, details)

  defp tool_words("list_machines", _args, _details), do: "Listed the machines"
  defp tool_words("list_context_files", _args, _details), do: "Listed the context files"

  defp tool_words("read_context_file", args, details),
    do: "Read #{details["file"] || args["name"]}"

  defp tool_words("write_context_file", args, details),
    do: "Wrote #{details["file"] || args["name"]}"

  defp tool_words("edit_context_file", args, details),
    do: "Edited #{details["file"] || args["name"]}"

  defp tool_words("load_skill", args, details),
    do: "Loaded the #{details["skill"] || args["name"]} skill"

  defp tool_words("ask_blip", args, _details),
    do: "Asked Blip: " <> cut_words(one_line(args["question"]), @question_limit)

  defp tool_words(name, _args, _details), do: "Used #{name}"

  defp on(args, details) do
    case args["machine"] || details["machine"] do
      machine when is_binary(machine) -> " on " <> machine
      _none -> ""
    end
  end

  defp ending(_name, %{"status" => "ok"}, %{"status" => "canceled"}), do: ": stopped"
  defp ending(_name, %{"status" => "ok"}, %{"status" => "failed"}), do: ": failed"

  defp ending("shell", %{"status" => "ok"}, %{"exit_code" => code}) when is_integer(code),
    do: ": exit #{code}"

  defp ending(_name, %{"status" => "ok"}, _details), do: ""
  defp ending(_name, %{"status" => "aborted"}, _details), do: ": stopped"

  defp ending(_name, data, _details) do
    reason =
      data["message"]
      |> text()
      |> String.replace_prefix("Error: ", "")
      |> one_line()
      |> cut_words(200)

    if reason == "", do: ": error", else: ": error: " <> reason
  end

  # The newest items that fit in @items_limit characters, each cut to
  # @item_limit first, with how many earlier ones were left out.
  defp fit(items) do
    {kept, _room} =
      items
      |> Enum.map(&cut_middle/1)
      |> Enum.reverse()
      |> Enum.reduce_while({[], @items_limit}, fn item, {kept, room} ->
        size = String.length(item) + 1
        if size <= room, do: {:cont, {[item | kept], room - size}}, else: {:halt, {kept, room}}
      end)

    left_out = length(items) - length(kept)
    lines = Enum.join(kept, "\n")
    if left_out > 0, do: "...#{left_out} earlier items left out.\n" <> lines, else: lines
  end

  defp cut_middle(item) do
    length = String.length(item)

    if length <= @item_limit do
      item
    else
      marker = "\n[...#{length - @item_limit} characters left out...]\n"
      keep = div(@item_limit, 2)
      String.slice(item, 0, keep) <> marker <> String.slice(item, length - keep, keep)
    end
  end

  ## Context files

  @doc """
  What Blip's `write_context_file` says: `Created notes.md in garden
  (1,234 characters).` for a new file, `Wrote ...` for one it replaced.
  """
  @spec file_written(String.t(), String.t(), String.t(), boolean()) :: String.t()
  def file_written(name, slug, content, created?) do
    verb = if created?, do: "Created", else: "Wrote"
    "#{verb} #{name} in #{slug} (#{characters(content)})."
  end

  @doc "What Blip's `edit_context_file` says: `Edited notes.md in garden.`"
  @spec file_edited(String.t(), String.t()) :: String.t()
  def file_edited(name, slug), do: "Edited #{name} in #{slug}."

  ## Schedules

  @doc """
  What Blip's `schedule` tool says once it made schedule `id`, firing
  `when_text` (`Photon.Schedules.when_text/1`). Blip's own:
  `Scheduled sc_9: first at 2026-10-10 09:00 UTC.` A project's adds the
  place: `..., then every 1440 minutes, in garden, starting a new thread
  each time.`, or `..., in garden, waking c_123 "Fix the pump".` for one
  that wakes a thread (`each time` only when it repeats).
  """
  @spec scheduled(String.t(), String.t(), schedule_place() | nil) :: String.t()
  def scheduled(id, when_text, nil), do: "Scheduled #{id}: #{when_text}."

  def scheduled(id, when_text, %{slug: slug} = place),
    do: "Scheduled #{id}: #{when_text}, in #{slug}, #{place_words(place)}."

  defp place_words(place) do
    each = if place.repeats?, do: " each time", else: ""

    case place.thread do
      nil -> "starting a new thread" <> each
      %{id: id, title: title} -> ~s(waking #{id} "#{title}") <> each
    end
  end

  @doc """
  What `list_schedules` says for project `slug`: the time now, then each
  schedule as `read_project` lists it (its ID, when, next time or why it
  stopped, its target and prompt), or `No schedules in garden.` `titles`
  are the project's thread titles by ID, for the threads schedules wake.
  """
  @spec schedules(String.t(), [schedule()], %{optional(String.t()) => String.t()}, DateTime.t()) ::
          String.t()
  def schedules(slug, [], _titles, now), do: "No schedules in #{slug}. (Now: #{time(now)}.)"

  def schedules(slug, schedules, titles, now) do
    "Now: #{time(now)}.\nSchedules in #{slug}:\n" <>
      Enum.map_join(schedules, "\n", &schedule_line(&1, titles))
  end

  ## Skills

  @doc """
  What `list_skills` says: one line per skill, by name, with its
  description and where it is on (`you` for Blip, a project's slug):
  `pdf-forms: Fill in PDF forms. On for: you, garden.`, or `Off
  everywhere.` A long description is cut at #{@description_limit}
  characters. `No skills yet.` with none.
  """
  @spec skills([skill()]) :: String.t()
  def skills([]), do: "No skills yet."

  def skills(skills) do
    Enum.map_join(skills, "\n", fn skill ->
      description = skill.description |> one_line() |> cut_words(@description_limit)
      "#{skill.name}: #{sentence(description)} #{on_for(skill.on_for)}"
    end)
  end

  defp on_for([]), do: "Off everywhere."
  defp on_for(places), do: "On for: #{Enum.join(places, ", ")}."

  @doc """
  What `set_project_skill` says: `Turned on pdf-forms for garden.` or
  `Turned off pdf-forms for garden.`
  """
  @spec skill_set(String.t(), String.t(), boolean()) :: String.t()
  def skill_set(name, slug, true), do: "Turned on #{name} for #{slug}."
  def skill_set(name, slug, false), do: "Turned off #{name} for #{slug}."

  ## Unknown names

  @doc """
  The error for a `project` argument that names no project, listing the
  slugs there are.
  """
  @spec unknown_project(String.t(), [String.t()]) :: String.t()
  def unknown_project(name, []),
    do: "There's no project called #{name}. There are no projects yet."

  def unknown_project(name, slugs),
    do: "There's no project called #{name}. Projects: #{Enum.join(slugs, ", ")}."

  @doc """
  The error for a `skill` argument that names no skill, listing the
  skills there are.
  """
  @spec unknown_skill(String.t(), [String.t()]) :: String.t()
  def unknown_skill(name, []), do: "There's no skill called #{name}. There are no skills yet."

  def unknown_skill(name, names),
    do: "There's no skill called #{name}. Skills: #{Enum.join(names, ", ")}."

  @doc "The error for a `thread` argument that names no thread."
  @spec unknown_thread(String.t()) :: String.t()
  def unknown_thread(id), do: "There's no thread #{id}. list_threads shows them."

  @doc """
  The error for a `question_id` that names no question, with the
  questions that are open (`Photon.Questions.open/0`), so Blip can pick
  the one it meant: `There's no open question q_999. Open: q_456 from
  "Fix the pump" (with the user), q_457 from "Plant list" (yours to
  answer).`
  """
  @spec unknown_question(String.t(), [map()]) :: String.t()
  def unknown_question(id, []), do: "There's no open question #{id}. No questions are open."

  def unknown_question(id, open) do
    listed =
      Enum.map_join(open, ", ", fn question ->
        ~s{#{question.id} from "#{question.thread_title}" (#{whose(question.status)})}
      end)

    "There's no open question #{id}. Open: #{listed}."
  end

  defp whose("with_owner"), do: "with the user"
  defp whose(_asked), do: "yours to answer"

  ## Words

  # A board entry's state in Blip's words, from the page's label.
  defp state_words(%{state: state, thread: thread}) do
    case State.label(state, thread) do
      "Waiting on you" -> "waiting on the user"
      "Asking Blip" -> "asking you"
      "Finished" -> "finished, not yet seen by the user"
      label -> String.downcase(label)
    end
  end

  defp count_words(state) do
    Enum.find_value(@states, fn
      {^state, _name, words} -> words
      _other -> nil
    end)
  end

  defp writer("owner", _titles), do: "the user"
  defp writer("blip", _titles), do: "you"

  defp writer(thread_id, titles) do
    case Map.fetch(titles, thread_id) do
      {:ok, title} -> ~s(thread "#{title}")
      :error -> "another thread"
    end
  end

  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp time(_none), do: "at an unknown time"

  defp when_ago(%DateTime{} = at, now), do: "#{time(at)} (#{ago(DateTime.diff(now, at))})"
  defp when_ago(_none, _now), do: "unknown"

  defp ago(seconds) when seconds < 60, do: "just now"
  defp ago(seconds) when seconds < 3_600, do: plural(div(seconds, 60), "minute") <> " ago"
  defp ago(seconds) when seconds < 86_400, do: plural(div(seconds, 3_600), "hour") <> " ago"
  defp ago(seconds), do: plural(div(seconds, 86_400), "day") <> " ago"

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  # The size of `content` in characters, as "1,234 characters".
  defp characters(content) do
    case String.length(content || "") do
      1 -> "1 character"
      n -> "#{thousands(n)} characters"
    end
  end

  defp thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp one_line(text) when is_binary(text), do: text |> String.split() |> Enum.join(" ")
  defp one_line(_not_text), do: ""

  # At most `limit` characters, cut at a word boundary with "...".
  defp cut_words(text, limit) do
    if String.length(text) <= limit do
      text
    else
      head = String.slice(text, 0, limit - 3)

      cut =
        case Regex.run(~r/\A(.*\S)\s/su, head) do
          [_, cut] -> cut
          nil -> head
        end

      String.replace(cut, ~r/[\s.,;:]+\z/u, "") <> "..."
    end
  end
end
