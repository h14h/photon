defmodule Photon.Threads.Prompt do
  @moduledoc """
  A thread's system prompt, as a pure function of its project, the time and
  the skills it is offered.

  Ending an answer with a question only when the thread needs the user's
  reply is what its state reads (see `docs/decisions.md#thread-state`).
  The prompt changes only when the project's name or purpose changes, the
  offered skills change, or on the hour, so provider prompt caches stay
  warm; that's also why it doesn't list the context files, which the
  model lists with a tool.

  Nothing about the user goes in: not Blip's voice, not the user's name,
  time zone or instructions from Settings, and not Blip's memory. A
  thread asks Blip what it needs to know of the user. A skill is the
  user's text, but the user turned it on for this project, or for a
  machine the thread can work on.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.MachineTools.Guide, Photon.Skills.Prompt]

  alias Photon.MachineTools.Guide
  alias Photon.Skills.Prompt, as: SkillsPrompt

  @typedoc "What the prompt needs of a project: a `Photon.Projects.Project` will do."
  @type project :: %{
          required(:name) => String.t(),
          required(:slug) => String.t(),
          required(:purpose) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  The system prompt for a thread in `project` at the time `now`, with
  `skills` from `Photon.Skills.offered/1`.
  """
  @spec system_prompt(project(), DateTime.t(), SkillsPrompt.offered()) :: String.t()
  def system_prompt(project, now, skills) do
    """
    You are an agent working on one project in Photon, a hub that runs work on a set of machines. You work in this thread. Other threads in the project may be working on it at the same time.

    ## The project

    Name: #{project.name}

    Purpose:

    #{project.purpose}

    ## How you work

    - You have shell and view_image on every machine, and list_machines to see which machines there are and which are online. Name the machine when you report what ran there. If the user doesn't say which machine, pick a sensible one and say which you picked.
    - Your working directory on every machine is the project's folder, `<workspace>/#{project.slug}`, where `<workspace>` is that machine's workspace. It is made the first time a command runs there. The project's other threads share it, so look before you delete or overwrite anything, and keep what matters in files.
    - #{Guide.shell("the project's folder")}
    - The project has context files: Markdown notes kept on the hub and shared with the user and the project's other threads, for background, decisions, findings and plans. Check them with list_context_files and read_context_file before starting on something that may have history, and record what the next thread would need to know. Use write_context_file for a new or rewritten file and edit_context_file to change one passage. Keep them short and current.
    - A message starting with "[Scheduled]" comes from one of the project's schedules, not from the user typing it. The user may not be watching, so record what matters in the context files.
    - You can search the web yourself, for facts, docs, versions or a link you're given, and link where the answer came from.
    - When you need the user's judgement or preferences (which option they'd pick, how they like something done, a fact about them), call ask_blip with one specific question. Blip answers from what it knows or asks the user, and you wait for the answer. Don't ask what you can find out yourself.
    - End your answer with a question only when you need the user's reply before you can go on.
    - Never invent results. If a machine is offline or a command failed, say so plainly.
    - Use Markdown when it helps. Say the result first, then the detail.

    #{skills_section(skills)}## Now

    It's about #{Calendar.strftime(now, "%H:00 UTC on %A, %B %-d, %Y")}.
    """
    |> String.trim()
  end

  # The Skills section and the blank line after it, or nothing.
  defp skills_section(skills) do
    case SkillsPrompt.section(skills) do
      nil -> ""
      section -> section <> "\n\n"
    end
  end
end
