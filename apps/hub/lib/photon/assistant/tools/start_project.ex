defmodule Photon.Assistant.Tools.StartProject do
  @moduledoc """
  Blip's `start_project` tool (section 5.2 of
  `docs/plans/step-4-blip-as-coordinator.md`): a new project from a
  purpose and, optionally, a name (`Photon.Projects.create_tx/2`), made
  inside the commit that records the call's result, so a call stopped
  before it leaves nothing and a rerun after a restart makes one. A
  purpose or name the project rules refuse comes back as their messages.

  A run that carries a thread's question, and that the owner hasn't
  written into, can't start a project (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Projects}

  @impl true
  def name, do: "start_project"

  @impl true
  def description,
    do:
      "Start a new project: a body of work with a purpose, context files and threads. " <>
        "Only when the user asks for one."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "purpose" => %{
          "type" => "string",
          "description" => "What the project is for, in a sentence or two."
        },
        "name" => %{
          "type" => "string",
          "description" => "A short name. Leave it out to make one from the purpose."
        }
      },
      "required" => ["purpose"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, api), do: {:commit, &start(&1, api, Map.take(args, ["purpose", "name"]))}

  defp start(tx, api, params) do
    with :ok <- Assistant.may_act_tx(tx, api.task, :change),
         {:ok, project} <- created(Projects.create_tx(tx, params)) do
      {:ok, "Started #{project.slug} (#{project.name}).",
       %{"project_id" => project.id, "slug" => project.slug, "name" => project.name}}
    end
  end

  defp created({:ok, project}), do: {:ok, project}

  defp created({:error, errors}) do
    message =
      for field <- [:purpose, :name], message = errors[field], message != nil do
        "#{field}: #{message}"
      end

    {:error, Enum.join(message, " ")}
  end
end
