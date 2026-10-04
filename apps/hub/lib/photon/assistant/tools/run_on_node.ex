defmodule Photon.Assistant.Tools.RunOnNode do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.NodeWork
  alias Photon.{Nodes, NodeSessions}

  @impl true
  def name, do: "run_on_node"

  @impl true
  def description do
    "Hand a task to the agent on one of the user's machines. It works in its own session with a shell on that machine. " <>
      "Returns the answer if it finishes within wait_seconds; otherwise the work continues and its report arrives later in this conversation."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "node" => %{"type" => "string", "description" => "The node's name, from list_nodes."},
        "task" => %{
          "type" => "string",
          "description" =>
            "A complete, self-contained task for the node's agent: goal, context, and what to report back."
        },
        "title" => %{
          "type" => "string",
          "description" => "A short title for the work, shown to the user."
        },
        "wait_seconds" => NodeWork.wait_param()
      },
      "required" => ["node", "task"]
    }
  end

  # IDs come from the call's task, so a rerun finds the same session.
  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, api) do
    node = args["node"]

    if Nodes.online?(node) or NodeSessions.get(NodeWork.ids(api).session_id) do
      %{session_id: session_id, input_id: input_id} = NodeWork.ids(api)

      case NodeSessions.start(node, args["task"],
             id: session_id,
             input_id: input_id,
             title: args["title"],
             origin: "assistant"
           ) do
        {:ok, session, _input} -> NodeWork.await(api, session, input_id, args["wait_seconds"])
        {:error, reason} -> {:error, reason}
      end
    else
      online = NodeWork.online_names()
      online = if online == [], do: "none", else: Enum.join(online, ", ")
      {:error, "Node #{inspect(node)} is offline or unknown. Online nodes: #{online}."}
    end
  end

  @impl true
  def resume(state, api), do: NodeWork.resume(state, api)

  # Stopped or failed after handing the work to the node: a watcher reports it.
  @impl true
  def on_interrupt(api, tx), do: NodeWork.ensure_watcher(api, tx)
end
