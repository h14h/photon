defmodule Photon.Skills.Prompt do
  @moduledoc """
  What agents see of skills, as pure functions: the Skills section of a
  prompt, the text a `load_skill` call returns, its error, and the tool's
  name, description and parameters, which Blip's `load_skill` and a thread's
  share.

  The section lists each skill's ID and version beside its name, so an
  agent can tell when a skill it loaded earlier changed or went: one
  deleted and another written or installed under its name starts again at
  version 1. It changes only when a skill is turned on or off, renamed,
  re-described or saved, or a machine's skills change or a machine with
  skills is installed or removed (never as machines connect), so prompt
  caches stay warm between those.

  A loaded skill installed without some of its files says not to look for
  them: they are on no machine, and a file of the same name in a project's
  folder is something else.

  Machine skills (`t:offered/0`) are listed after the agent's own, each
  under its machine, to be loaded before work on that machine and followed
  only there. With no machine skills, `section/1`, `loaded/2` and
  `not_loaded/3` give exactly the text they gave before machines had
  skills, so a hub with none sends agents the same prompts and results.
  """

  # Functional core: no processes, no I/O.
  use Boundary, top_level?: true, type: :strict, deps: []

  @tool_name "load_skill"

  @preamble """
  ## Skills

  Skills are instructions for particular kinds of task, written or installed by the user. When a task matches a skill's description, load it with #{@tool_name} before you start, and follow it. Load only the skills the task needs.

  Only the skills listed here are turned on. If you loaded a skill earlier in this conversation and it isn't listed any more, it was turned off or deleted: stop following it. If a skill's id or version here differs from the one you loaded, it has changed: load it again before you use it.
  """

  @machine_preamble """
  Some skills are turned on for a machine because they are about working on it. Each is listed under its machine. Before you start work on one of these machines, load the ones your work there needs with #{@tool_name}, and follow them while you work on that machine. They don't apply to work on other machines. If you loaded a skill earlier in this conversation and it is now listed only under a machine, it is no longer on for all your work: follow it only when you work on that machine.
  """

  @typedoc "What the prompt needs of a skill: a `Photon.Skills.Skill` will do."
  @type listed :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:version) => pos_integer(),
          required(:description) => String.t(),
          optional(atom()) => term()
        }

  @typedoc """
  What an agent is offered: its own set (Blip's, or its project's), and
  each machine with skills on, with them, in the order to list them.
  """
  @type offered :: %{own: [listed()], machines: [{String.t(), [listed()]}]}

  @typedoc "What `loaded/1` needs of a skill: a `Photon.Skills.Skill` will do."
  @type loadable :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:version) => pos_integer(),
          required(:instructions) => String.t(),
          optional(:files_left_out) => [String.t()],
          optional(atom()) => term()
        }

  @doc """
  The Skills section of a prompt for what the agent is `offered`. Nil when
  both are empty, so a prompt without enabled skills has no trace of the
  feature.
  """
  @spec section(offered()) :: String.t() | nil
  def section(%{own: [], machines: []}), do: nil

  def section(%{own: own, machines: machines}) do
    [String.trim_trailing(@preamble) | own_part(own) ++ machine_part(machines)]
    |> Enum.join("\n\n")
  end

  defp own_part([]), do: []

  defp own_part(skills),
    do: ["<available_skills>\n#{Enum.map_join(skills, "\n", &skill_line/1)}\n</available_skills>"]

  defp machine_part([]), do: []

  defp machine_part(machines) do
    groups =
      Enum.map_join(machines, "\n", fn {id, skills} ->
        ~s(<machine name="#{escape(id)}">\n) <>
          Enum.map_join(skills, "\n", &skill_line/1) <> "\n</machine>"
      end)

    [String.trim_trailing(@machine_preamble), "<machine_skills>\n#{groups}\n</machine_skills>"]
  end

  defp skill_line(skill) do
    "<skill><name>#{escape(skill.name)}</name><version>#{skill.version}</version>" <>
      "<id>#{escape(skill.id)}</id>" <>
      "<description>#{escape(one_line(skill.description))}</description></skill>"
  end

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&#34;")
    |> String.replace("'", "&#39;")
  end

  @doc "A loaded skill, as `load_skill` returns it: `loaded(skill, [])`."
  @spec loaded(loadable()) :: String.t()
  def loaded(skill), do: loaded(skill, [])

  @doc """
  A loaded skill that is on for `machines` (their IDs, in the order to
  name them) rather than in the agent's own set, with a line saying to
  follow it when working on them.
  """
  @spec loaded(loadable(), [String.t()]) :: String.t()
  def loaded(skill, machines) do
    on_for =
      case machines do
        [] -> ""
        ids -> ~s( machines="#{escape(Enum.join(ids, " "))}")
      end

    text = """
    <skill name="#{skill.name}" id="#{skill.id}" version="#{skill.version}"#{on_for}>
    #{skill.instructions}
    </skill>\
    """

    left_out =
      case Map.get(skill, :files_left_out) || [] do
        [] -> []
        files -> [left_out_line(files)]
      end

    Enum.join([text | machine_line(machines) ++ left_out], "\n")
  end

  defp machine_line([]), do: []

  defp machine_line([id]),
    do: ["This skill is turned on for #{id}: follow it when you work on #{id}."]

  defp machine_line(ids),
    do: ["This skill is turned on for #{join(ids)}: follow it when you work on those machines."]

  defp join([one]), do: one
  defp join(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  defp left_out_line(files) do
    "This skill was installed without its other files (#{Enum.join(files, ", ")}). " <>
      "They aren't on any machine: don't look for them or run them. Do what you can " <>
      "from the instructions, and tell the user if the task needs a missing file."
  end

  @doc "`not_loaded(name, enabled, [])`."
  @spec not_loaded(String.t(), [String.t()]) :: String.t()
  def not_loaded(name, enabled), do: not_loaded(name, enabled, [])

  @doc """
  The error when no skill called `name` is turned on here or for a
  machine: `own` are the names of the skills on here, and `machines` each
  machine with skills on and their names.
  """
  @spec not_loaded(String.t(), [String.t()], [{String.t(), [String.t()]}]) :: String.t()
  def not_loaded(_name, [], []), do: "No skills are turned on here."

  def not_loaded(name, own, []),
    do:
      "There's no skill called #{name} turned on here. " <>
        "Turned on here: #{Enum.join(own, ", ")}."

  def not_loaded(name, own, machines) do
    here = if own == [], do: "", else: " Turned on here: #{Enum.join(own, ", ")}."

    on_machines =
      Enum.map_join(machines, "; ", fn {id, names} -> "#{id} has #{Enum.join(names, ", ")}" end)

    "There's no skill called #{name} turned on here or for a machine." <>
      here <> " For machines: #{on_machines}."
  end

  @doc """
  What the marker in an older, shortened `load_skill` result says to do
  to read all of it (the result's `details["full_output"]`; see
  `Photon.Durable.Context`).
  """
  @spec full_output_hint(String.t()) :: String.t()
  def full_output_hint(name),
    do: ~s[Load it again with #{@tool_name}("#{name}") to read all of it]

  ## The tool, as both profiles offer it

  @doc "The tool's name."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "The tool's description, as the model sees it."
  @spec tool_description() :: String.t()
  def tool_description,
    do:
      "Load a skill's instructions into this conversation. Use it when a task matches a " <>
        "skill listed under Skills, before you start the task."

  @doc "The tool's parameters, as JSON schema."
  @spec tool_parameters() :: map()
  def tool_parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "The skill's name, as listed under Skills."
        }
      },
      "required" => ["name"]
    }
  end
end
