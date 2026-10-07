defmodule Photon.Assistant.Tools.MessageThread do
  @moduledoc """
  Blip's `message_thread` tool (section 5.2 of
  `docs/plans/step-4-blip-as-coordinator.md`): sends a message to any
  thread (`Photon.Threads.send_tx/4`, source `%{"kind" => "blip"}`, so
  Blip hears how the run it starts ends). A busy thread gets it after
  its current run (`follow_up`, the default) or after its current step
  (`steer`). The message is sent inside the commit that records the
  call's result, with the call's task ID in its request ID, so a rerun
  after a restart sends it once.

  It refuses in a run that carries a thread's question the owner hasn't
  written into, and past the unattended limit
  (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Durable.{Submission, ToolAPI}

  @impl true
  def name, do: "message_thread"

  @impl true
  def description,
    do:
      "Send a message to a thread, in any project. If it's busy, it gets the message after " <>
        "its current run (follow_up) or after its current step (steer)."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "thread" => %{
          "type" => "string",
          "description" => "The thread's ID, like c_123 (list_threads shows them)."
        },
        "message" => %{"type" => "string", "description" => "What to tell the thread."},
        "when_busy" => %{
          "type" => "string",
          "enum" => ["follow_up", "steer"],
          "description" =>
            "If the thread is busy: follow_up (the default) waits for its current run to " <>
              "end; steer reaches it after its current step."
        }
      },
      "required" => ["thread", "message"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"thread" => id, "message" => message} = args, api) do
    when_busy = args["when_busy"] || "follow_up"

    with {:ok, thread} <- Assistant.find_thread(id),
         do: {:commit, &send_message(&1, api, thread, message, when_busy)}
  end

  defp send_message(tx, api, thread, message, when_busy) do
    opts = [
      source: %{"kind" => "blip"},
      request_id: "blip:" <> ToolAPI.task_id(api),
      when_busy: when_busy
    ]

    with :ok <- Assistant.may_act_tx(tx, api.task, :start),
         {:ok, submission} <- sent(Threads.send_tx(tx, thread.id, message, opts)) do
      {:ok, said(submission, ~s("#{thread.title}")),
       %{"thread_id" => thread.id, "title" => thread.title, "project_id" => thread.project_id}}
    end
  end

  defp sent({:ok, submission}), do: {:ok, submission}
  defp sent({:error, :blank}), do: {:error, "The message is empty."}
  defp sent({:error, :not_found}), do: {:error, "That thread no longer exists."}

  defp said(%Submission{status: "queued", mode: "steer"}, title),
    do: "#{title} will see it after its current step."

  defp said(%Submission{status: "queued"}, title),
    do: "Queued for #{title}, behind its current run."

  defp said(_placed, title), do: "Sent to #{title}; it's working on it."
end
