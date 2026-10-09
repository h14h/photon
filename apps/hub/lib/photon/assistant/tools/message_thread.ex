defmodule Photon.Assistant.Tools.MessageThread do
  @moduledoc """
  Blip's `message_thread` tool: sends a message to any thread
  (`Photon.Threads.send_tx/4`, source `%{"kind" => "blip"}`, so Blip hears
  how the run it starts ends). A busy thread gets it after its current run
  (`follow_up`, the default) or after its current step (`steer`); any other
  `when_busy` is a follow-up. The message is sent inside the commit that
  records the call's result, with the call's task ID in its request ID, so a
  rerun after a restart sends it once.

  It refuses in a run that carries a thread's question the owner hasn't
  written into, and past the unattended limit
  (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.{Origin, Readout}
  alias Photon.Durable.{Submission, ToolAPI, ToolSchema}

  @impl true
  def name, do: "message_thread"

  @impl true
  def description,
    do:
      "Send a message to a thread, in any project. If it's busy, it gets the message after " <>
        "its current run (follow_up) or after its current step (steer)."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          thread: Readout.field(:thread),
          message: {:string, "What to tell the thread."},
          when_busy:
            {:string,
             "If the thread is busy: follow_up (the default) waits for its current run to " <>
               "end; steer reaches it after its current step.", enum: ["follow_up", "steer"]}
        ],
        [:thread, :message]
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"thread" => id, "message" => message} = args, api) do
    # The schema's enum is only advice to the model: anything but steer
    # is a follow-up, so a stray "reject" can't roll back the commit.
    when_busy = if args["when_busy"] == "steer", do: "steer", else: "follow_up"

    with {:ok, thread} <- Assistant.find_thread(id),
         do: {:commit, &send_message(&1, api, thread, message, when_busy)}
  end

  defp send_message(tx, api, thread, message, when_busy) do
    opts = [
      source: %{"kind" => "blip"},
      request_id: "blip:" <> ToolAPI.task_id(api),
      when_busy: when_busy
    ]

    with {:ok, origin} <- Assistant.may_act_tx(tx, api.task, :start),
         {:ok, submission} <- sent(Threads.send_tx(tx, thread.id, message, opts)) do
      {:ok, said(submission, ~s("#{thread.title}")),
       Map.merge(Origin.unattended_details(origin), %{
         "thread_id" => thread.id,
         "title" => thread.title,
         "project_id" => thread.project_id
       })}
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
