defmodule PhotonNode.Harness.Tools.SkillUse do
  @moduledoc """
  The SkillUse tool: loads a skill's instructions. Skills are discovered in
  `<workspace>/.harness/skills/*/SKILL.md` (see `PhotonNode.Harness.Skills`).
  """

  @behaviour PhotonNode.Harness.Tools

  alias PhotonCore.{Message, Operation}
  alias PhotonNode.Harness.Tools

  @impl true
  def name, do: "SkillUse"

  @impl true
  def definition do
    %{
      "name" => "SkillUse",
      "description" => "Load the instructions for a registered skill.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The exact name of the skill to load."}
        },
        "required" => ["name"]
      }
    }
  end

  @impl true
  def translate(call, env) do
    with {:ok, args} <- decode(call["arguments"]),
         {:ok, name} <- skill_name(args),
         {:ok, skill} <- find_skill(env.skills, name) do
      op =
        Operation.new("skill_use", 1, %{
          "path" => skill.path,
          "content" => nil,
          "terminal_error" => ""
        })

      {Tools.ok_status([op]), [op]}
    else
      {:error, message} -> {%{"error" => message, "waiting_for" => []}, []}
    end
  end

  defp skill_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp skill_name(_args), do: {:error, ~s(skill-use argument "name" must be set)}

  defp find_skill(skills, name) do
    case Enum.find(skills, &(&1.name == name)) do
      nil -> {:error, ~s(skill "#{name}" is not registered)}
      skill -> {:ok, skill}
    end
  end

  defp decode(args),
    do:
      Tools.decode_arguments(args, fn _ ->
        "decode skill-use arguments: expected a JSON object"
      end)

  @impl true
  def format(%{"error" => error}, _ops) when error not in [nil, ""], do: [Message.text(error)]

  def format(_status, [%{"status" => "completed", "state" => state} | _]),
    do: [Message.text(state["content"] || "")]

  def format(_status, [%{"status" => status, "state" => state} | _])
      when status in ["failed", "canceled"],
      do: [Message.text(state["terminal_error"])]

  def format(_status, _ops), do: [Message.text("Skill is loading.")]
end
