defmodule Photon.Assistant.Tools.MessageNodeSession do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.NodeWork
  alias Photon.{Nodes, NodeSessions}

  @impl true
  def name, do: "message_node_session"

  @impl true
  def description do
    "Send a follow-up message to an existing node session, which remembers its earlier work. " <>
      "If it is busy, the message steers the work in progress. Waits like run_on_node."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "The node session's ID."},
        "message" => %{
          "type" => "string",
          "description" => "What to tell or ask the node's agent."
        },
        "wait_seconds" => NodeWork.wait_param()
      },
      "required" => ["session_id", "message"]
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, api) do
    with {:ok, session} <- NodeWork.known_session(args["session_id"]),
         :ok <-
           if(Nodes.online?(session.node_id),
             do: :ok,
             else: {:error, "#{session.node_id} is offline."}
           ),
         %{input_id: input_id} = NodeWork.ids(api),
         {:ok, _input} <- NodeSessions.send_input(session.id, args["message"], input_id: input_id) do
      NodeWork.await(api, session, input_id, args["wait_seconds"])
    end
  end

  @impl true
  def resume(state, api), do: NodeWork.resume(state, api)

  # Stopped or failed after handing the work to the node: a watcher reports it.
  @impl true
  def on_interrupt(api, tx), do: NodeWork.ensure_watcher(api, tx)
end
