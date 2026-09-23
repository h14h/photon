defmodule Photon.Nodes do
  @moduledoc """
  Agent nodes currently connected to this server.

  Each node is represented by its `PhotonWeb.NodeChannel` process, registered
  under the node ID with the node's info as the registry value. Commands are
  fire-and-forget pushes; results come back as session events.
  """

  @topic "nodes"

  @doc "PubSub topic carrying `:nodes_changed` whenever a node joins, leaves or changes state."
  def topic, do: @topic

  def broadcast, do: Phoenix.PubSub.broadcast(Photon.PubSub, @topic, :nodes_changed)

  @doc "Connected nodes, sorted with the local node first."
  def list do
    Photon.NodeRegistry
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {id, info} -> Map.put(info, "id", id) end)
    |> Enum.sort_by(&{&1["id"] != "local", &1["id"]})
  end

  def get(id) do
    case Registry.lookup(Photon.NodeRegistry, id) do
      [{_pid, info}] -> Map.put(info, "id", id)
      [] -> nil
    end
  end

  def running_ids do
    Enum.reduce(list(), MapSet.new(), &MapSet.union(&2, &1["running"]))
  end

  @doc """
  Starts a run. `attachments` are `{workspace_path, bytes}` pairs, sent inline
  (base64) for the node to write into its workspace; see `Photon.Attachments`.
  """
  def start_run(node_id, session_id, prompt, config, attachments \\ []) do
    command(node_id, "start_run", %{
      "session_id" => session_id,
      "prompt" => prompt,
      "config" => config,
      "attachments" =>
        for({path, data} <- attachments, do: %{"path" => path, "data" => Base.encode64(data)})
    })
  end

  def stop_run(node_id, session_id),
    do: command(node_id, "stop_run", %{"session_id" => session_id})

  def delete_session(node_id, session_id) do
    command(node_id, "delete_session", %{"session_id" => session_id})
  end

  defp command(node_id, event, payload) do
    case Registry.lookup(Photon.NodeRegistry, node_id) do
      [{pid, _}] ->
        send(pid, {:command, event, payload})
        :ok

      [] ->
        {:error, :offline}
    end
  end
end
