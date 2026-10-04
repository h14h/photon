defmodule Photon.Assistant.Tools.ListNodes do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.NodeWork
  alias Photon.{Nodes, NodeSessions}

  @impl true
  def name, do: "list_nodes"

  @impl true
  def description,
    do:
      "List the user's machines (nodes): which are online, what they are, and their recent work sessions."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def replay, do: :safe

  @impl true
  def execute(_args, _api) do
    online = Nodes.list()
    sessions = NodeSessions.list(nil, 200)
    known = sessions |> Enum.map(& &1.node_id) |> Enum.uniq()
    offline = known -- Enum.map(online, & &1["id"])
    lines = Enum.map(online, &online_line(&1, sessions)) ++ Enum.map(offline, &"- #{&1}: offline")

    case lines do
      [] -> {:ok, "No nodes yet. The user can add one from the Nodes page."}
      lines -> {:ok, Enum.join(lines, "\n")}
    end
  end

  defp online_line(node, sessions) do
    recent = sessions |> Enum.filter(&(&1.node_id == node["id"])) |> Enum.take(3)

    "- #{node["id"]}: online (#{node["platform"]}, workspace #{node["workspace"]}, photon-node #{node["version"]})" <>
      Enum.map_join(recent, "", &("\n  - " <> NodeWork.session_line(&1)))
  end
end
