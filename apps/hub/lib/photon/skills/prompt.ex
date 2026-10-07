defmodule Photon.Skills.Prompt do
  @moduledoc """
  What agents see of skills (section 2.6 of
  `docs/plans/step-3-skills-and-schedules.md`), as pure functions: the
  Skills section of a prompt, the text a `load_skill` call returns, its
  error, and the tool's name, description and parameters, which Blip's
  `load_skill` and a thread's share.

  `section/1` lists the enabled skills' names, IDs, versions and
  descriptions, and says what to do when a skill loaded earlier is no
  longer listed, or is listed with another ID or version. The ID tells
  apart two skills that had the same name in turn: one deleted and
  another written or installed under its name starts again at version 1. With no skills it is nil, so a prompt without
  enabled skills has no trace of the feature. It changes only when a skill
  is turned on or off, renamed, re-described or saved, so prompt caches
  stay warm between those.

  `loaded/1` wraps the instructions in a `<skill>` element that names the
  ID and version, and, for a skill installed without some of its files, adds a
  line naming them and telling the agent not to look for them: they are on
  no machine, and a file of the same name in a project's folder is
  something else.

  A skill turned on for a machine is offered to every agent, beside its
  own set (`t:offered/0`; section 4 of `docs/plans/machine-skills.md`).
  `loaded/2` names the machines it is on for and says to follow it when
  working there, and `not_loaded/3` lists the machines' skills too. With
  no machines, both give exactly the text `loaded/1` and `not_loaded/2`
  give, so a hub with no machine skills tells agents what it did before.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Skills.Skill]

  @tool_name "load_skill"

  @preamble """
  ## Skills

  Skills are instructions for particular kinds of task, written or installed by the user. When a task matches a skill's description, load it with #{@tool_name} before you start, and follow it. Load only the skills the task needs.

  Only the skills listed here are turned on. If you loaded a skill earlier in this conversation and it isn't listed any more, it was turned off or deleted: stop following it. If a skill's id or version here differs from the one you loaded, it has changed: load it again before you use it.
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
  The Skills section of a prompt for `skills` (the scope's enabled skills,
  in the order to list them), or nil when there are none.
  """
  @spec section([listed()]) :: String.t() | nil
  def section([]), do: nil

  def section(skills) do
    lines = Enum.map_join(skills, "\n", &skill_line/1)
    @preamble <> "\n<available_skills>\n" <> lines <> "\n</available_skills>"
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

  @doc """
  A loaded skill, as `load_skill` returns it: the instructions inside a
  `<skill>` element naming the skill, its ID and its version, then, when install
  left files out, the line that names them. The same as `loaded(skill, [])`.
  """
  @spec loaded(loadable()) :: String.t()
  def loaded(skill), do: loaded(skill, [])

  @doc """
  A loaded skill that is on for `machines` (their IDs, in the order to
  name them) rather than in the agent's own set: the `<skill>` element
  also names them, and a line after it says to follow the skill when
  working on them, before the line naming files install left out, if
  any. With no machines, `loaded/1`'s text.
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

  @doc """
  The error when no skill called `name` is turned on here; `enabled` are
  the names of the skills that are, by name. The same as
  `not_loaded(name, enabled, [])`.
  """
  @spec not_loaded(String.t(), [String.t()]) :: String.t()
  def not_loaded(name, enabled), do: not_loaded(name, enabled, [])

  @doc """
  The error when no skill called `name` is turned on here or for a
  machine: `own` are the names of the skills on here, and `machines` each
  machine with skills on and their names, `{machine_id, names}`. With no
  machines, the text `not_loaded/2` gives.
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
