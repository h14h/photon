defmodule Photon.Assistant.Tools.StopThread do
  @moduledoc """
  Blip's `stop_thread` tool: stops any thread's run and withdraws what is
  queued for it, as the Stop button on its page does
  (`Photon.Threads.stop_tx/2`), inside the commit that records the call's
  result. A stop is never a signal, so Blip doesn't hear about it again.
  `Photon.Assistant.may_act_tx/3` (`:change`) may refuse it.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.Readout
  alias Photon.Durable.ToolSchema

  @impl true
  def name, do: "stop_thread"

  @impl true
  def description,
    do: "Stop a thread's run, in any project, and drop the messages waiting for it."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          thread: Readout.field(:thread)
        ],
        [:thread]
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"thread" => id}, api) do
    with {:ok, thread} <- Assistant.find_thread(id), do: {:commit, &stop(&1, api, thread)}
  end

  defp stop(tx, api, thread) do
    with {:ok, _origin} <- Assistant.may_act_tx(tx, api.task, :change) do
      details = %{
        "thread_id" => thread.id,
        "title" => thread.title,
        "project_id" => thread.project_id
      }

      case Threads.stop_tx(tx, thread.id) do
        :stopped -> {:ok, ~s(Stopped "#{thread.title}".), details}
        :idle -> {:ok, ~s("#{thread.title}" wasn't running; nothing to stop.), details}
      end
    end
  end
end
