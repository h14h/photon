defmodule PhotonNode.Harness.Skills do
  @moduledoc """
  Skills in `<workspace>/.harness/skills/*/SKILL.md`. Each file starts with
  front matter naming the skill:

      ---
      name: deploy
      description: How to deploy this project
      ---

  `discover/1` reads the workspace (boundary). The prompt section that
  lists them is pure and lives in `PhotonNode.Harness.SkillPrompt`.
  """

  require Logger

  alias PhotonNode.Harness.SkillPrompt

  @typedoc "A discovered skill."
  @type skill :: SkillPrompt.skill()

  @doc "Skills in a workspace, first one per name; broken ones are logged and skipped."
  @spec discover(String.t()) :: [skill()]
  def discover(workspace) do
    [workspace, ".harness", "skills", "*", "SKILL.md"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&discovered/1)
    |> Enum.uniq_by(& &1.name)
  end

  defp discovered(path) do
    case parse(path) do
      {:ok, skill} ->
        [skill]

      {:error, reason} ->
        Logger.warning("skill error> #{path}: #{reason}")
        []
    end
  end

  defp parse(path) do
    case path |> File.read() |> front_matter() do
      {:ok, front} -> skill(fields(front), path)
      :error -> {:error, "missing front matter"}
    end
  end

  defp front_matter({:ok, body}) do
    with ["---" | lines] <- String.split(body, ~r/\r?\n/),
         {front, [_ | _]} <- Enum.split_while(lines, &(String.trim(&1) != "---")) do
      {:ok, front}
    else
      _ -> :error
    end
  end

  defp front_matter({:error, _reason}), do: :error

  defp fields(front) do
    for line <- front, [k, v] <- [String.split(line, ":", parts: 2)], into: %{} do
      {String.trim(k), String.trim(v)}
    end
  end

  defp skill(%{"name" => name, "description" => description}, path)
       when name != "" and description != "",
       do: {:ok, %{name: name, description: description, path: path}}

  defp skill(_fields, _path), do: {:error, "front matter needs a name and a description"}

  @doc "The system prompt section that lists skills, or nil without any (`SkillPrompt.prompt/1`)."
  @spec prompt([skill()]) :: String.t() | nil
  defdelegate prompt(skills), to: SkillPrompt
end
