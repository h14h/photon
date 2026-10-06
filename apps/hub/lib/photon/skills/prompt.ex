defmodule Photon.Skills.Prompt do
  @moduledoc """
  What agents see of skills (section 2.6 of
  `docs/plans/step-3-skills-and-schedules.md`), as pure functions: the
  Skills section of a prompt, the text a `load_skill` call returns, its
  error, and the tool's name, description and parameters, which Blip's
  `load_skill` and a thread's share.

  `section/1` lists the enabled skills' names, versions and descriptions,
  and says what to do when a skill loaded earlier is no longer listed or
  its version went up. With no skills it is nil, so a prompt without
  enabled skills has no trace of the feature. It changes only when a skill
  is turned on or off, renamed, re-described or saved, so prompt caches
  stay warm between those.

  `loaded/1` wraps the instructions in a `<skill>` element that names the
  version, and, for a skill installed without some of its files, adds a
  line naming them and telling the agent not to look for them: they are on
  no machine, and a file of the same name in a project's folder is
  something else.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Skills.Skill]

  @tool_name "load_skill"

  @preamble """
  ## Skills

  Skills are instructions for particular kinds of task, written or installed by the user. When a task matches a skill's description, load it with #{@tool_name} before you start, and follow it. Load only the skills the task needs.

  Only the skills listed here are turned on. If you loaded a skill earlier in this conversation and it isn't listed any more, it was turned off or deleted: stop following it. If a skill's version here is higher than the one you loaded, load it again before you use it.
  """

  @typedoc "What the prompt needs of a skill: a `Photon.Skills.Skill` will do."
  @type listed :: %{
          required(:name) => String.t(),
          required(:version) => pos_integer(),
          required(:description) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "What `loaded/1` needs of a skill: a `Photon.Skills.Skill` will do."
  @type loadable :: %{
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
  `<skill>` element naming the skill and its version, then, when install
  left files out, the line that names them.
  """
  @spec loaded(loadable()) :: String.t()
  def loaded(skill) do
    text = """
    <skill name="#{skill.name}" version="#{skill.version}">
    #{skill.instructions}
    </skill>\
    """

    case Map.get(skill, :files_left_out) || [] do
      [] -> text
      files -> text <> "\n" <> left_out_line(files)
    end
  end

  defp left_out_line(files) do
    "This skill was installed without its other files (#{Enum.join(files, ", ")}). " <>
      "They aren't on any machine: don't look for them or run them. Do what you can " <>
      "from the instructions, and tell the user if the task needs a missing file."
  end

  @doc """
  The error when no skill called `name` is turned on here; `enabled` are
  the names of the skills that are, by name.
  """
  @spec not_loaded(String.t(), [String.t()]) :: String.t()
  def not_loaded(_name, []), do: "No skills are turned on here."

  def not_loaded(name, enabled),
    do:
      "There's no skill called #{name} turned on here. " <>
        "Turned on here: #{Enum.join(enabled, ", ")}."

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
