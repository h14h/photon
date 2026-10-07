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

  After a tool result, the script's usual relay prints it.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

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
  """

  @doc """
  The phrasings, in the order the script tries them, each with the reply
  its captures make. `request` is the model request; these phrasings
  don't look at it.
  """
  @spec phrasings(map()) :: [phrasing()]
  def phrasings(_request), do: read_phrasings() ++ work_phrasings() ++ file_phrasings()

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

  @doc "The help text's lines for these phrasings, one Markdown list item each."
  @spec help() :: String.t()
  def help, do: @help

  defp read_project(slug), do: call("read_project", %{"project" => slug}, "Reading #{slug}.")

  defp threads_in(slug),
    do: call("list_threads", %{"project" => slug}, "Here are the threads in #{slug}.")

  defp read_thread(id), do: call("read_thread", %{"thread" => id}, "Reading #{id}.")

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
        "Telling #{id}."
      )

  defp stop_thread(id), do: call("stop_thread", %{"thread" => id}, "Stopping #{id}.")

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

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])
end
