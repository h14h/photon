defmodule Photon.Activity.Rules do
  @moduledoc """
  The activity log's words and facts (sections 6.2 and 6.3 of
  `docs/plans/step-4-blip-as-coordinator.md`), as pure functions:

    * `summary/3` - the line a tool call shows, in the past tense, naming
      the machine, project or thread it acted on
    * `message_summary/1` - the line for something Blip told the owner
      without a tool
    * `changes?/1` - whether a tool changes something, for the page's
      "Changes only" filter
    * `origin_label/2` - who asked, as the page says it

  `summary/3` and `changes?/1` run on the harness's hook paths (the
  activity row is written in the commit that records a call's result,
  on a Stop inside the Scheduler's own commit), so they are total: the
  call is taken as the model sent it, arguments that don't decode or
  lack a field or have the wrong type for it read `Used <name>`, and so
  does a tool these rules don't know (rule 75).
  """

  # Functional core: no processes, no I/O. `summary/3` decodes the raw
  # arguments with `PhotonCore.Message.arguments/1`.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Message

  @summary_limit 200

  # Who may have asked, as `Photon.Assistant.Origin` names it.
  @origins ~w(owner thread schedule follow_up unknown)

  # How long a command, a question or a prompt may run inside a summary
  # before it is cut, so the line keeps room for where it acted.
  @quote_limit 120

  @typedoc ~s{Who asked: `"owner"`, `"thread"`, `"schedule"`, `"follow_up"` or `"unknown"`.}
  @type origin :: String.t()

  @typedoc "Titles and prompts by ID: threads' titles and schedules' prompts the page read."
  @type names :: %{optional(String.t()) => String.t()}

  @doc "Who may have asked for something Blip did."
  @spec origins() :: [origin()]
  def origins, do: @origins

  @doc """
  The line a tool call shows: `call` is the call as the model sent it
  (`"name"`, and `"arguments"` as a map or a JSON string), `status` its
  result's status and `details` its result's details (where names and
  titles come from when there are some; the arguments otherwise). A
  failed call ends `: failed`, a stopped one `: stopped` and one a
  restart cut short `: interrupted`. At most 200 characters.
  """
  @spec summary(term(), term(), term()) :: String.t()
  def summary(call, status, details) do
    name = name(call)

    line =
      case Message.arguments(call) do
        {:ok, args} -> line(name, args, fields(details)) || used(name)
        {:error, _reason} -> used(name)
      end

    ending = ending(status)
    cut(line, @summary_limit - String.length(ending)) <> ending
  end

  defp name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp name(_call), do: nil

  defp used(nil), do: "Used a tool"
  defp used(name), do: "Used " <> one_line(name)

  defp ending("error"), do: ": failed"
  defp ending("aborted"), do: ": stopped"
  defp ending("interrupted"), do: ": interrupted"
  defp ending(_status), do: ""

  # A result's details, with string keys. Anything else is no details.
  defp fields(details) when is_map(details) do
    for {key, value} <- details, is_binary(key) or is_atom(key), into: %{} do
      {to_string(key), value}
    end
  end

  defp fields(_details), do: %{}

  # The machine tools.
  defp line("shell", %{"machine" => machine, "command" => command}, _d)
       when is_binary(machine) and is_binary(command),
       do: "Ran `#{one_line(command, @quote_limit)}` on #{one_line(machine)}"

  defp line("view_image", %{"machine" => machine, "path" => path}, _d)
       when is_binary(machine) and is_binary(path),
       do: "Looked at #{one_line(path, @quote_limit)} on #{one_line(machine)}"

  defp line("list_machines", _args, _d), do: "Checked your machines"

  # Reading projects and threads.
  defp line("list_projects", _args, _d), do: "Listed projects"

  defp line("list_threads", args, d),
    do: with_place("Listed threads", args, d)

  defp line("read_project", %{"project" => project}, d) when is_binary(project),
    do: "Looked over " <> slug(d, project)

  defp line("read_thread", %{"thread" => id}, d) when is_binary(id), do: "Read " <> thread(d, id)

  # Starting, messaging and stopping work.
  defp line("start_project", %{"purpose" => purpose}, d) when is_binary(purpose) do
    case d["slug"] do
      slug when is_binary(slug) -> "Started the project " <> one_line(slug)
      _none -> "Started a project"
    end
  end

  defp line("start_thread", %{"project" => project, "message" => message}, d)
       when is_binary(project) and is_binary(message) do
    case d["title"] do
      title when is_binary(title) -> ~s(Started "#{one_line(title)}" in #{slug(d, project)})
      _none -> "Started a thread in " <> slug(d, project)
    end
  end

  defp line("message_thread", %{"thread" => id, "message" => message}, d)
       when is_binary(id) and is_binary(message),
       do: "Messaged " <> thread(d, id)

  defp line("stop_thread", %{"thread" => id}, d) when is_binary(id),
    do: "Stopped " <> thread(d, id)

  # Context files.
  defp line("list_context_files", %{"project" => project}, d) when is_binary(project),
    do: "Listed the files in " <> slug(d, project)

  defp line("read_context_file", %{"project" => project, "name" => name}, d)
       when is_binary(project) and is_binary(name),
       do: "Read #{file(d, name)} in #{slug(d, project)}"

  defp line("write_context_file", %{"project" => project, "name" => name, "content" => text}, d)
       when is_binary(project) and is_binary(name) and is_binary(text),
       do: "Wrote #{file(d, name)} in #{slug(d, project)}"

  defp line("edit_context_file", %{"project" => project, "name" => name} = args, d)
       when is_binary(project) and is_binary(name) do
    if is_binary(args["old_text"]) and is_binary(args["new_text"]),
      do: "Edited #{file(d, name)} in #{slug(d, project)}"
  end

  # Questions.
  defp line("answer_question", %{"question_id" => id, "answer" => answer}, d)
       when is_binary(id) and is_binary(answer) do
    case d["title"] do
      title when is_binary(title) -> ~s(Answered "#{one_line(title)}"'s question)
      _none -> "Answered " <> one_line(id)
    end
  end

  defp line("ask_owner", %{"question_id" => id, "question" => question}, _d)
       when is_binary(id) and is_binary(question),
       do: "Asked you: " <> one_line(question, @summary_limit)

  # Schedules and skills.
  defp line("schedule", %{"prompt" => prompt} = args, d) when is_binary(prompt) do
    with when_text when is_binary(when_text) <- when_text(args) do
      with_place(~s(Scheduled "#{one_line(prompt, @quote_limit)}"#{when_text}), args, d)
    end
  end

  defp line("list_schedules", args, d), do: with_place("Checked the schedules", args, d)

  defp line("cancel_schedule", %{"schedule_id" => id}, d) when is_binary(id) do
    case d["slug"] do
      slug when is_binary(slug) -> "Cancelled #{one_line(id)} in #{one_line(slug)}"
      _none -> "Cancelled " <> one_line(id)
    end
  end

  defp line("list_skills", _args, _d), do: "Checked skills"

  defp line("set_project_skill", %{"project" => project, "skill" => skill, "on" => on}, d)
       when is_binary(project) and is_binary(skill) and is_boolean(on) do
    turned = if on, do: "Turned on", else: "Turned off"
    skill = if is_binary(d["skill"]), do: d["skill"], else: skill
    "#{turned} #{one_line(skill)} for #{slug(d, project)}"
  end

  defp line("load_skill", %{"name" => name}, _d) when is_binary(name),
    do: "Loaded the #{one_line(name)} skill"

  # Memory.
  defp line("update_memory", %{"action" => action, "text" => text}, _d) when is_binary(text) do
    case action do
      "add" -> "Remembered: " <> one_line(text, @summary_limit)
      "remove" -> "Forgot: " <> one_line(text, @summary_limit)
      "rewrite" -> "Rewrote its memory"
      _other -> nil
    end
  end

  defp line(_name, _args, _d), do: nil

  # `line` with " in <slug>" when the call names a project; nil when its
  # `project` argument isn't text.
  defp with_place(line, args, d) do
    case Map.get(args, "project") do
      nil -> line
      project when is_binary(project) -> "#{line} in #{slug(d, project)}"
      _other -> nil
    end
  end

  # When a schedule fires, from its arguments: "every day", " in 30
  # minutes", " at <time>", or nothing when it doesn't say; nil when a
  # field has the wrong type.
  defp when_text(%{"every_minutes" => every}) when is_integer(every) and every > 0,
    do: " " <> every(every)

  defp when_text(%{"in_minutes" => minutes}) when is_integer(minutes) and minutes >= 0,
    do: " in " <> minutes(minutes)

  defp when_text(%{"at" => at}) when is_binary(at), do: " at " <> one_line(at)

  defp when_text(args) do
    if Enum.any?(~w(every_minutes in_minutes at), &Map.has_key?(args, &1)), do: nil, else: ""
  end

  defp every(1440), do: "every day"
  defp every(60), do: "every hour"
  defp every(1), do: "every minute"
  defp every(n) when rem(n, 1440) == 0, do: "every #{div(n, 1440)} days"
  defp every(n) when rem(n, 60) == 0, do: "every #{div(n, 60)} hours"
  defp every(n), do: "every #{n} minutes"

  defp minutes(1), do: "1 minute"
  defp minutes(n), do: "#{n} minutes"

  # A project's slug from the details, else the argument as given.
  defp slug(d, project) do
    case d["slug"] do
      slug when is_binary(slug) -> one_line(slug)
      _none -> one_line(project)
    end
  end

  # A thread's title in quotes from the details, else its ID as given.
  defp thread(d, id) do
    case d["title"] do
      title when is_binary(title) -> ~s("#{one_line(title)}")
      _none -> one_line(id)
    end
  end

  # A file's name as stored, from the details, else as given.
  defp file(d, name) do
    case d["file"] do
      file when is_binary(file) -> one_line(file)
      _none -> one_line(name)
    end
  end

  @doc """
  The line for something Blip told the owner without a tool: `Told you:`
  and the text's first line with words in it, at most 200 characters;
  `Told you something` when there is none.
  """
  @spec message_summary(term()) :: String.t()
  def message_summary(text) when is_binary(text) do
    case text |> String.split(~r/\r?\n/) |> Enum.find(&(String.trim(&1) != "")) do
      nil -> "Told you something"
      line -> cut("Told you: " <> one_line(line, @summary_limit), @summary_limit)
    end
  end

  def message_summary(_text), do: "Told you something"

  @doc """
  Whether tool `name` changes something: false for the tools that only
  read (`list_*`, `read_*`, `load_skill`), true for the rest, `shell`
  included (a command can change anything) and any tool these rules
  don't know.
  """
  @spec changes?(term()) :: boolean()
  def changes?(name) when is_binary(name),
    do:
      not (String.starts_with?(name, "list_") or String.starts_with?(name, "read_") or
             name == "load_skill")

  def changes?(_name), do: true

  @doc """
  Who asked, as the activity page says it, for a row's `origin` and
  `origin_id` (an `Photon.Activity.Action` or a map with those keys).
  `names` are the thread titles and schedule prompts the page read for
  the IDs on screen:

    * `"owner"`: "You"
    * `"thread"` (a thread's question): its title, or "A thread"
    * `"schedule"`: "Schedule: <prompt>", or "A schedule"
    * `"follow_up"`: "Blip's follow-up", with "on <title>" when
      `origin_id` names a thread (a `c_` ID) whose title is known; a
      follow-up from a schedule Blip made for itself names no thread
    * anything else: "Blip"
  """
  @spec origin_label(term(), names()) :: String.t()
  def origin_label(%{origin: origin} = row, names) do
    id = Map.get(row, :origin_id)
    name = if is_binary(id) and is_map(names), do: Map.get(names, id)
    label(origin, id, if(is_binary(name), do: one_line(name)))
  end

  def origin_label(_row, _names), do: "Blip"

  defp label("owner", _id, _name), do: "You"
  defp label("thread", _id, nil), do: "A thread"
  defp label("thread", _id, title), do: title
  defp label("schedule", _id, nil), do: "A schedule"
  defp label("schedule", _id, prompt), do: "Schedule: " <> prompt

  defp label("follow_up", "c_" <> _rest, title) when is_binary(title),
    do: "Blip's follow-up on " <> title

  defp label("follow_up", _id, _name), do: "Blip's follow-up"
  defp label(_origin, _id, _name), do: "Blip"

  # Text on one line, its whitespace collapsed, cut to `limit` characters.
  defp one_line(text, limit \\ 60) do
    text |> String.split() |> Enum.join(" ") |> cut(limit)
  end

  defp cut(text, limit) do
    if String.length(text) <= limit,
      do: text,
      else: String.trim_trailing(String.slice(text, 0, max(limit - 3, 0))) <> "..."
  end
end
