defmodule PhotonNode.Harness.Ops.SkillUse do
  @moduledoc "The `skill_use` job (run by `PhotonNode.Harness.Ops.Job`): reads a skill's SKILL.md."

  @behaviour PhotonNode.Harness.Ops.Job

  alias PhotonCore.{Operation, Output}

  @impl true
  @spec run(Operation.t()) :: Operation.t()
  def run(op) do
    case File.read(op["state"]["path"]) do
      {:ok, content} ->
        Operation.advance(op, "completed", %{"content" => Output.sanitize(content)})

      {:error, reason} ->
        Operation.advance(op, "failed", %{
          "terminal_error" => "read skill: #{:file.format_error(reason)}"
        })
    end
  end
end
