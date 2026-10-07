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
  """

  @doc """
  The phrasings, in the order the script tries them, each with the reply
  its captures make. `request` is the model request; the read phrasings
  don't look at it.
  """
  @spec phrasings(map()) :: [phrasing()]
  def phrasings(_request) do
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

  @doc "The help text's lines for these phrasings, one Markdown list item each."
  @spec help() :: String.t()
  def help, do: @help

  defp read_project(slug), do: call("read_project", %{"project" => slug}, "Reading #{slug}.")

  defp threads_in(slug),
    do: call("list_threads", %{"project" => slug}, "Here are the threads in #{slug}.")

  defp read_thread(id), do: call("read_thread", %{"thread" => id}, "Reading #{id}.")

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])
end
