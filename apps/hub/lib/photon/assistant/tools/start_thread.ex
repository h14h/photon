defmodule Photon.Assistant.Tools.StartThread do
  @moduledoc """
  Blip's `start_thread` tool (section 5.2 of
  `docs/plans/step-4-blip-as-coordinator.md`): a new thread in a project,
  with Blip's message as its first (`Photon.Threads.start_tx/4`, source
  `%{"kind" => "blip"}`, so the thread is `started_by: "blip"` and Blip
  hears how its runs end). The thread is made inside the commit that
  records the call's result, with the call's task ID in its request ID,
  so a rerun after a restart makes one thread.

  It refuses in a run that carries a thread's question the owner hasn't
  written into, and past the unattended limit
  (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Durable.ToolAPI

  @impl true
  def name, do: "start_thread"

  @impl true
  def description,
    do:
      "Start a thread in a project: an agent that works on what your message says, on the " <>
        "user's machines. Give it everything the task needs. You'll get an update when its " <>
        "run ends."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "project" => %{
          "type" => "string",
          "description" =>
            "The project's slug, like garden (list_projects shows them), or its ID."
        },
        "message" => %{
          "type" => "string",
          "description" => "The thread's first message: the task, with what it needs to know."
        }
      },
      "required" => ["project", "message"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => name, "message" => message}, api) do
    with {:ok, project} <- Assistant.find_project(name),
         do: {:commit, &start(&1, api, project, message)}
  end

  defp start(tx, api, project, message) do
    opts = [source: %{"kind" => "blip"}, request_id: "blip:" <> ToolAPI.task_id(api)]

    with :ok <- Assistant.may_act_tx(tx, api.task, :start),
         {:ok, thread} <- started(Threads.start_tx(tx, project.id, message, opts)) do
      {:ok,
       ~s(Started #{thread.id} "#{thread.title}" in #{project.slug}. ) <>
         "You'll get an update when its run ends.",
       %{
         "thread_id" => thread.id,
         "title" => thread.title,
         "project_id" => project.id,
         "slug" => project.slug
       }}
    end
  end

  defp started({:ok, thread}), do: {:ok, thread}

  defp started({:error, :blank}),
    do: {:error, "The message is empty; say what the thread should do."}

  defp started({:error, :not_found}), do: {:error, "That project no longer exists."}
end
