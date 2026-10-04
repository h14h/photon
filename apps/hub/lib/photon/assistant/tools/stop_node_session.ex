defmodule Photon.Assistant.Tools.StopNodeSession do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.NodeWork
  alias Photon.Durable.ToolAPI
  alias Photon.{Nodes, NodeSessions}

  @impl true
  def name, do: "stop_node_session"

  @impl true
  def description, do: "Stop a node session's work now: cancels its running commands."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "The node session's ID."}
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"session_id" => id}, api) do
    with {:ok, session} <- NodeWork.known_session(id),
         # The stop's ID comes from this call, so a rerun after a restart
         # repeats the same stop rather than stopping later work.
         "t_" <> suffix = ToolAPI.task_id(api),
         {:ok, _stop} <- NodeSessions.stop(id, input_id: "stop_" <> suffix) do
      {:ok, stopped_text(session, Nodes.online?(session.node_id)),
       %{"session_id" => id, "node" => session.node_id}}
    else
      nil -> {:error, "There's no session #{id}."}
      error -> error
    end
  end

  defp stopped_text(session, true = _online),
    do: "Asked #{session.node_id} to stop session #{session.id}."

  defp stopped_text(session, false = _online),
    do: "#{session.node_id} is offline. It will stop session #{session.id} when it reconnects."
end
