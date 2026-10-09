defmodule Photon.Assistant.Tools.EditContextFile do
  @moduledoc """
  Blip's `edit_context_file` tool: replaces one passage of one of a
  project's context files, which must occur in it exactly once, as written
  by Blip (`updated_by: "blip"`), inside the commit that records the
  call's result (`Photon.Projects.edit_file_tx/6`). A refused edit changes
  nothing. `Photon.Assistant.may_act_tx/3` (`:change`) may refuse it.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Projects}
  alias Photon.Assistant.Readout
  alias Photon.Durable.ToolSchema
  alias Photon.Projects.Rules

  @impl true
  def name, do: "edit_context_file"

  @impl true
  def description,
    do:
      "Change one passage of one of a project's context files: old_text, which must appear " <>
        "in the file exactly once, becomes new_text. Give enough of the passage to pick out " <>
        "one place."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          project: Readout.field(:project),
          name: Rules.file_field(:name),
          old_text: Rules.file_field(:old_text),
          new_text: Rules.file_field(:new_text)
        ],
        [:project, :name, :old_text, :new_text]
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => project_name, "name" => name} = args, api) do
    %{"old_text" => old_text, "new_text" => new_text} = args

    with {:ok, project} <- Assistant.find_project(project_name),
         do: {:commit, &edit(&1, api, project, name, {old_text, new_text})}
  end

  defp edit(tx, api, project, name, {old_text, new_text}) do
    with {:ok, _origin} <- Assistant.may_act_tx(tx, api.task, :change),
         {:ok, file} <- Projects.edit_file_tx(tx, project.id, name, old_text, new_text, "blip") do
      {:ok, Readout.file_edited(file.name, project.slug),
       %{
         "project_id" => project.id,
         "slug" => project.slug,
         "file" => file.name,
         "version" => file.version
       }}
    end
  end
end
