defmodule Photon.Assistant.MockCoordinator do
  @moduledoc """
  The scripted Blip's phrasings for its tools over projects and threads
  (section 8.2 of `docs/plans/step-4-blip-as-coordinator.md`), which
  `Photon.Assistant.MockScript` tries after the machine and skill
  phrasings and before its own:

    * `projects` lists the projects (`list_projects`)
    * `project <slug>` reads one (`read_project`)
    * `threads` and `threads in <slug>` list threads (`list_threads`)
    * `read thread <id>` reads one (`read_thread`)
    * `start project: <purpose>` starts a project (`start_project`)
    * `start thread in <slug>: <message>` starts a thread (`start_thread`)
    * `tell <id>: <message>` messages a thread (`message_thread`)
    * `stop thread <id>` stops one (`stop_thread`)
    * `files in <slug>` lists a project's context files
      (`list_context_files`)
    * `read <slug>/<name>` reads one (`read_context_file`)
    * `write <slug>/<name>: <text>` writes `<text>`, which may run over
      several lines, as the whole file (`write_context_file`)
    * `edit <slug>/<name>: <old> => <new>` changes one passage
      (`edit_context_file`)
    * `in <n> minutes in <slug>: <prompt>` and `every <n> minutes in
      <slug>: <prompt>` schedule work in a project, a new thread each
      time (`schedule` with `project`), and `schedules in <slug>` lists
      a project's schedules (`list_schedules`); `cancel schedule <id>`
      cancels any schedule (`cancel_schedule`)
    * `all skills` lists every skill (`list_skills`), and `turn on <skill>
      in <slug>` or `turn off <skill> in <slug>` turns one on or off for
      a project (`set_project_skill`)
    * `answer <question id>: <text>` answers a thread's question
      (`answer_question`), and `answer: <text>` answers the newest
      question this conversation asked the owner about (the last
      `ask_owner` call among the request's messages)

  Messages the owner didn't type (`unasked/2`), read from every text part
  of the last user message, since a signal message may carry several:

    * a digest or a daily review of ambient mode: `Photon.Assistant.MockAmbient`'s,
      which `unasked/2` tries first

    * `[Question q_... from ...]` parts: a question whose text holds the
      key of a memory line `- <key>: <value>` (in the request's system
      text, under `## Memory`; at least three characters, ignoring case)
      is answered with the value (`answer_question`); any other is passed
      to the owner in the thread's words (`ask_owner`; the card and the
      bubble name the thread). One call
      per question, in one answer. A question ending in `(prose)` gets a
      plain reply and no call, the way a real model sometimes slips, so
      the hub passes it on itself
    * `[Thread update]` parts and nothing else: one line per update
      (`Fix the pump in Garden finished.`), no call
    * the owner's answer to a question (`[Your answer to ...`): "Noted."

  What it says is for the owner: threads by title, never an ID, and the
  owner as "you". Its intros don't repeat the ID a phrasing named the
  thread or question by (`Telling the thread.`). After a result of its
  tools over threads (`relay/3`), it says what happened in its own words
  where the result is written for the model (`Started "Fix the pump" in
  garden. I'll tell you how it goes.`, `I've asked you for "Fix the
  pump". Your answer goes straight to the thread.`, `Answered "Fix the
  pump".`); any other result of theirs it relays as the script's usual
  relay prints it, with the IDs left out and the model's words for the
  owner and itself turned round ("waiting on the user" reads "waiting on
  you", "asking you" reads "asking me"). Other tools' results (a
  command's output, a file) are relayed as they are.
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [PhotonCore, PhotonCore.LLM, Photon.Assistant.MockAmbient]

  alias Photon.Assistant.MockAmbient
  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  # Blip's tools whose results name threads and questions in the model's
  # words, which `relay/3` turns into the owner's.
  @thread_tools ~w(list_projects read_project list_threads read_thread list_context_files
                   start_thread message_thread stop_thread answer_question ask_owner)

  # The model's words for the owner and for Blip, and the IDs it is given,
  # in the order `owner_words/1` turns them round or leaves them out:
  # Blip's "you" becomes "me" before the user's words become "you".
  @owner_words [
    {~r/\bYou already asked\b/, "I already asked"},
    {~r/\basking you\b/, "asking me"},
    {~r/\bwith you\b/, "with me"},
    {~r/\bby you\b/, "by me"},
    {~r/\bwithout you\b/, "without me"},
    {~r/\byours to answer\b/, "mine to answer"},
    {~r/\btheir answer\b/, "your answer"},
    {~r/\bthe user's\b/, "your"},
    {~r/\bthe user\b/, "you"},
    {~r/\[user\]/, "[you]"},
    {~r/\bc_[a-z0-9]+ (?=")/, ""},
    {~r/ \(c_[a-z0-9]+\)/, ""},
    {~r/, ID p_[a-z0-9]+/, ""},
    {~r/\bno thread c_[a-z0-9]+/, "no such thread"},
    {~r/\bno open question q_[a-z0-9]+/, "no such open question"},
    {~r/\bq_[a-z0-9]+ from /, "the question from "},
    {~r/\bquestion q_[a-z0-9]+/, "question"},
    {~r/(\A|[:.] )q_[a-z0-9]+\b/, "\\1That question"},
    {~r/\bq_[a-z0-9]+\b/, "that question"},
    {~r/\bc_[a-z0-9]+\b/, "that thread"}
  ]

  @typedoc "A phrasing: the pattern a message must match, and the reply its captures make."
  @type phrasing :: {Regex.t(), ([String.t()] -> Message.t())}

  @help """
  - `projects` lists the projects, and `project <slug>` reads one, like `project garden`
  - `threads` or `threads in <slug>` lists threads, and `read thread <id>` reads one
  - `start project: <purpose>` starts a project
  - `start thread in <slug>: <message>` starts a thread there, like `start thread in garden: files`
  - `tell <id>: <message>` messages a thread, and `stop thread <id>` stops one
  - `files in <slug>` lists a project's context files, and `read <slug>/<name>` reads one
  - `write <slug>/<name>: <text>` writes a whole file, like `write garden/notes.md: hello`
  - `edit <slug>/<name>: <old text> => <new text>` changes one passage
  - `in 5 minutes in <slug>: <prompt>` or `every 60 minutes in <slug>: <prompt>` schedules a new thread there, and `schedules in <slug>` lists a project's schedules
  - `cancel schedule <id>` cancels a schedule, mine or a project's
  - `all skills` lists every skill, and `turn on <skill> in <slug>` or `turn off <skill> in <slug>` sets one for a project
  - `answer <question id>: <text>` answers a thread's question, and `answer: <text>` the last one I asked you about
  - a thread's question is answered from my memory when a `- <key>: <value>` line's key is in it, else passed to you; one ending in `(prose)` gets a plain reply
  """

  @doc """
  The phrasings, in the order the script tries them, each with the reply
  its captures make. `request` is the model request; these phrasings
  don't look at it.
  """
  @spec phrasings(map()) :: [phrasing()]
  def phrasings(request),
    do:
      read_phrasings() ++
        work_phrasings() ++
        file_phrasings() ++
        schedule_phrasings() ++ skill_phrasings() ++ question_phrasings(request)

  # The read tools' phrasings.
  defp read_phrasings do
    [
      {~r/\A(?:list )?projects\z/i,
       fn [] -> call("list_projects", %{}, "Here are the projects.") end},
      {~r/\Aproject\s+(\S+)\z/i, fn [slug] -> read_project(slug) end},
      {~r/\A(?:list )?threads\z/i,
       fn [] -> call("list_threads", %{}, "Here are the threads.") end},
      {~r/\Athreads in\s+(\S+)\z/i, fn [slug] -> threads_in(slug) end},
      {~r/\Aread thread\s+(\S+)\z/i, fn [id] -> read_thread(id) end}
    ]
  end

  # The phrasings of the tools that start and stop work.
  defp work_phrasings do
    [
      {~r/\Astart project\s*:\s*(.+)\z/is, fn [purpose] -> start_project(purpose) end},
      {~r/\Astart thread in\s+(\S+?)\s*:\s*(.+)\z/is,
       fn [slug, message] -> start_thread(slug, message) end},
      {~r/\Atell\s+(\S+?)\s*:\s*(.+)\z/is, fn [id, message] -> tell(id, message) end},
      {~r/\Astop thread\s+(\S+)\z/i, fn [id] -> stop_thread(id) end}
    ]
  end

  # The context-file tools' phrasings. A file is named `<slug>/<name>`, so
  # `read thread <id>` never reads as a file.
  defp file_phrasings do
    [
      {~r/\Afiles in\s+(\S+)\z/i, &files_in/1},
      {~r/\Aread\s+([^\s\/]+)\/([^\s\/:]+)\z/i, &read_file/1},
      {~r/\Awrite\s+([^\s\/]+)\/([^\s\/:]+)\s*:\s*(.*)\z/s, &write_file/1},
      {~r/\Aedit\s+([^\s\/]+)\/([^\s\/:]+)\s*:\s*(.+?)\s*=>\s*(.*)\z/s, &edit_file/1}
    ]
  end

  # The phrasings for a project's schedules, and cancelling any schedule.
  # Blip's own (`in <n> minutes: <prompt>`, `schedules`) are the script's.
  defp schedule_phrasings do
    [
      {~r/\Ain\s+(\d+)\s+minutes?\s+in\s+(\S+?)\s*:\s*(.+)\z/s, &schedule_in(&1, "in_minutes")},
      {~r/\Aevery\s+(\d+)\s+minutes?\s+in\s+(\S+?)\s*:\s*(.+)\z/s,
       &schedule_in(&1, "every_minutes")},
      {~r/\Aschedules in\s+(\S+)\z/i, fn [slug] -> schedules_in(slug) end},
      {~r/\Acancel schedule\s+(\S+)\z/i,
       fn [id] -> call("cancel_schedule", %{"schedule_id" => id}, "Cancelling #{id}.") end}
    ]
  end

  # The phrasings for skills: every skill, and one on or off for a project.
  defp skill_phrasings do
    [
      {~r/\Aall skills\z/i, fn [] -> call("list_skills", %{}, "Here are the skills.") end},
      {~r/\Aturn (on|off)\s+(\S+)\s+in\s+(\S+)\z/i, &set_skill/1}
    ]
  end

  # The phrasings that answer a thread's question. `answer: <text>` finds
  # the question in the request.
  defp question_phrasings(request) do
    [
      {~r/\Aanswer\s+(\S+?)\s*:\s*(.+)\z/is, fn [id, text] -> answer(id, text) end},
      {~r/\Aanswer\s*:\s*(.+)\z/is, fn [text] -> answer_last(request, text) end}
    ]
  end

  @doc "The help text's lines for these phrasings, one Markdown list item each."
  @spec help() :: String.t()
  def help, do: @help

  defp read_project(slug), do: call("read_project", %{"project" => slug}, "Reading #{slug}.")

  defp threads_in(slug),
    do: call("list_threads", %{"project" => slug}, "Here are the threads in #{slug}.")

  defp read_thread(id), do: call("read_thread", %{"thread" => id}, "Reading the thread.")

  defp start_project(purpose),
    do: call("start_project", %{"purpose" => String.trim(purpose)}, "Starting a project.")

  defp start_thread(slug, message),
    do:
      call(
        "start_thread",
        %{"project" => slug, "message" => String.trim(message)},
        "Starting a thread in #{slug}."
      )

  defp tell(id, message),
    do:
      call(
        "message_thread",
        %{"thread" => id, "message" => String.trim(message)},
        "Telling the thread."
      )

  defp stop_thread(id), do: call("stop_thread", %{"thread" => id}, "Stopping the thread.")

  defp files_in([slug]),
    do:
      call(
        "list_context_files",
        %{"project" => slug},
        "Checking the context files in #{slug}."
      )

  defp read_file([slug, name]),
    do:
      call(
        "read_context_file",
        %{"project" => slug, "name" => name},
        "Reading #{name} in #{slug}."
      )

  defp write_file([slug, name, content]),
    do:
      call(
        "write_context_file",
        %{"project" => slug, "name" => name, "content" => content},
        "Writing #{name} in #{slug}."
      )

  defp edit_file([slug, name, old_text, new_text]),
    do:
      call(
        "edit_context_file",
        %{"project" => slug, "name" => name, "old_text" => old_text, "new_text" => new_text},
        "Editing #{name} in #{slug}."
      )

  defp schedule_in([minutes, slug, prompt], key),
    do:
      call(
        "schedule",
        %{"prompt" => String.trim(prompt), key => String.to_integer(minutes), "project" => slug},
        "Scheduling it in #{slug}."
      )

  defp schedules_in(slug),
    do:
      call(
        "list_schedules",
        %{"project" => slug},
        "Here's what's scheduled in #{slug}."
      )

  defp set_skill([on, skill, slug]) do
    on? = String.downcase(on) == "on"

    call(
      "set_project_skill",
      %{"project" => slug, "skill" => skill, "on" => on?},
      "Turning #{String.downcase(on)} #{skill} in #{slug}."
    )
  end

  defp answer(id, text),
    do:
      call(
        "answer_question",
        %{"question_id" => id, "answer" => String.trim(text)},
        "Sending your answer to the thread."
      )

  defp answer_last(request, text) do
    case last_asked(request[:messages] || []) do
      nil -> Message.assistant("I don't have a question waiting on you.")
      id -> answer(id, text)
    end
  end

  # The question of the last `ask_owner` call in `messages`, or nil.
  defp last_asked(messages) do
    messages
    |> Enum.flat_map(&Message.tool_calls/1)
    |> Enum.filter(&(&1["name"] == "ask_owner"))
    |> Enum.flat_map(fn call ->
      case Message.arguments(call) do
        {:ok, %{"question_id" => id}} when is_binary(id) -> [id]
        _garbage -> []
      end
    end)
    |> List.last()
  end

  ## After a result

  @doc """
  What the scripted Blip says after its call to tool `name` (nil when the
  call isn't found) returned `text`, given `relayed`, what the script's
  usual relay makes of the result: for its tools over threads, its own
  words, or the relayed result in the owner's words; for any other tool,
  `relayed` as it is.
  """
  @spec relay(String.t() | nil, String.t(), String.t()) :: String.t()
  def relay(name, text, relayed) when name in @thread_tools,
    do: own_words(name, text) || owner_words(relayed)

  def relay(_name, _text, relayed), do: relayed

  # The results written for the model, said for the owner.
  defp own_words("start_thread", text) do
    case Regex.run(~r/\AStarted (".*") in (\S+) \([^()]*\)\./, text, capture: :all_but_first) do
      [title, slug] -> "Started #{title} in #{slug}. I'll tell you how it goes."
      nil -> nil
    end
  end

  defp own_words("ask_owner", text) do
    case Regex.run(~r/\AAsked the user\. .*? goes straight to (".*?");/, text,
           capture: :all_but_first
         ) do
      [title] -> "I've asked you for #{title}. Your answer goes straight to the thread."
      nil -> nil
    end
  end

  defp own_words("answer_question", text) do
    case Regex.run(~r/\ASent your answer to (".*")\.\z/, text, capture: :all_but_first) do
      [title] -> "Answered #{title}."
      nil -> nil
    end
  end

  defp own_words(_name, _text), do: nil

  # A result in the owner's words: no IDs, the owner as "you" and Blip as
  # "me".
  defp owner_words(text),
    do:
      Enum.reduce(@owner_words, text, fn {pattern, words}, text ->
        String.replace(text, pattern, words)
      end)

  ## What the owner didn't type

  @doc """
  The scripted reply to a message the owner didn't type, from the text
  parts of the last user message (`texts`): a digest or a daily review
  (`Photon.Assistant.MockAmbient.unasked/2`, tried first), thread
  questions, thread updates, or the owner's answer to a question going
  by. Nil for anything else, which the phrasings handle.
  """
  @spec unasked([String.t()], map()) :: Message.t() | nil
  def unasked(texts, request), do: MockAmbient.unasked(texts, request) || signal(texts, request)

  defp signal(texts, request) do
    questions = for "[Question " <> _ = text <- texts, q = question(text), q != nil, do: q

    cond do
      questions != [] ->
        handle(questions, memory(request[:system] || ""))

      match?(["[Your answer to" <> _ | _], texts) ->
        Message.assistant("Noted.")

      texts != [] and Enum.all?(texts, &String.starts_with?(&1, "[Thread update]")) ->
        updates(texts)

      true ->
        nil
    end
  end

  # `[Question q_456 from Garden / "Fix the pump" (c_123)]`, then the question.
  defp question(text) do
    [header | body] = String.split(text, "\n", parts: 2)

    case Regex.run(~r/\A\[Question (\S+) from .*? \/ "(.*)" \([^()]*\)\]\z/, header,
           capture: :all_but_first
         ) do
      [id, title] -> %{id: id, title: title, text: String.trim(Enum.join(body))}
      nil -> nil
    end
  end

  # The `- <key>: <value>` lines of the memory in the system text, with keys
  # of at least three characters.
  defp memory(system) do
    case String.split(system, "## Memory\n", parts: 2) do
      [_before, rest] -> rest |> String.split("\n## ", parts: 2) |> hd() |> memory_lines()
      _no_memory -> []
    end
  end

  defp memory_lines(shown) do
    for line <- String.split(shown, "\n"),
        [key, value] <- [
          Regex.run(~r/\A-\s*([^:]+?)\s*:\s*(.+)\z/, String.trim(line), capture: :all_but_first)
        ],
        String.length(key) >= 3,
        do: {String.downcase(key), String.trim(value)}
  end

  # One call per question (or a plain line for one ending in `(prose)`), in
  # one answer.
  defp handle(questions, memory) do
    {lines, calls} =
      questions
      |> Enum.map(&handle_one(&1, memory))
      |> Enum.unzip()

    Message.assistant(Enum.join(lines, "\n"), Enum.reject(calls, &is_nil/1))
  end

  defp handle_one(%{id: id, title: title, text: text}, memory) do
    known =
      Enum.find(memory, fn {key, _value} -> String.contains?(String.downcase(text), key) end)

    cond do
      String.ends_with?(text, "(prose)") ->
        {~s{I'm not sure what to tell "#{title}".}, nil}

      known != nil ->
        {_key, value} = known

        {~s{Answering "#{title}" from memory.},
         Mock.call("answer_question", %{"question_id" => id, "answer" => value})}

      true ->
        {~s{Asking you for "#{title}".},
         Mock.call("ask_owner", %{"question_id" => id, "question" => text})}
    end
  end

  # `[Thread update] Garden / "Fix the pump" (c_123) finished. It said: ...`
  # reads `Fix the pump in Garden finished.`
  defp updates(texts), do: texts |> Enum.map_join("\n", &update/1) |> Message.assistant()

  defp update(text) do
    case Regex.run(~r/\A\[Thread update\] (.*?) \/ "(.*)" \([^()]*\) (.*)\z/s, text,
           capture: :all_but_first
         ) do
      [project, title, outcome] -> "#{title} in #{project} #{outcome_words(outcome)}"
      nil -> "A thread changed."
    end
  end

  defp outcome_words("finished" <> _note), do: "finished."
  defp outcome_words("is waiting on the user: " <> note), do: "is waiting on you: " <> note
  defp outcome_words("is waiting on the user" <> _), do: "is waiting on you."
  defp outcome_words(other), do: other

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])
end
