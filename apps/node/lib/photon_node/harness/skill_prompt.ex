defmodule PhotonNode.Harness.SkillPrompt do
  @moduledoc """
  The system prompt section that lists a workspace's skills. Pure: the
  session core builds its prompt with it, and `PhotonNode.Harness.Skills`
  (which reads the workspace) finds the skills.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @preamble_file Path.expand("../../../priv/prompts/skill-preamble.md", __DIR__)
  @external_resource @preamble_file
  @preamble @preamble_file |> File.read!() |> String.trim()

  @typedoc "A discovered skill."
  @type skill :: %{name: String.t(), description: String.t(), path: String.t()}

  @doc "The system prompt section that lists skills, or nil without any."
  @spec prompt([skill()]) :: String.t() | nil
  def prompt([]), do: nil

  def prompt(skills) do
    xml =
      Enum.map_join(skills, "", fn s ->
        "<skill><name>#{escape(s.name)}</name><description>#{escape(s.description)}</description><location>#{escape(s.path)}</location></skill>"
      end)

    @preamble <> "\n\n<available_skills>" <> xml <> "</available_skills>"
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&#34;")
    |> String.replace("'", "&#39;")
  end
end
