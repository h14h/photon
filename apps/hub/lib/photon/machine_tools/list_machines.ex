defmodule Photon.MachineTools.ListMachines do
  @moduledoc """
  The `list_machines` tool: every machine the hub knows, from
  `Photon.Machines.roster/0` (section 3.1 of
  `docs/plans/step-1-machine-tools.md`). Connected machines come with
  their platform, hostname, workspace and photon-node version; a connected
  machine whose photon-node can't take commands says so; known machines
  that aren't connected are listed as offline. `local` is the hub's own
  computer.

  When the conversation has a working directory (`api.workdir`, a
  project's slug for a thread), the list opens with a line saying the
  working directory is that folder in each machine's workspace, made on
  first use, and each machine that can take commands names its full path
  (section 3.4 of `docs/plans/step-2-projects-and-threads.md`). Offline
  machines have no workspace to show.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Machines

  @impl true
  def name, do: "list_machines"

  @impl true
  def description,
    do:
      "List the machines you can run commands on with shell and view_image: their IDs, " <>
        "whether each is online, and what it is."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def replay, do: :safe

  @impl true
  def execute(_args, api) do
    case Machines.roster() do
      [] ->
        {:ok, "No machines yet. The user can add one from the Nodes page."}

      machines ->
        {:ok, intro(api.workdir) <> Enum.map_join(machines, "\n", &line(&1, api.workdir))}
    end
  end

  defp intro(nil), do: ""

  defp intro(workdir),
    do: "Your working directory on each machine is <workspace>/#{workdir}, made on first use.\n\n"

  defp line(%{id: id, online: false}, _workdir), do: "- #{name(id)}: offline"

  defp line(%{id: id, info: info}, workdir) do
    case Machines.status(id) do
      :outdated ->
        "- #{name(id)}: online, but it runs an older photon-node#{version(info)} that can't take commands; " <>
          "it needs reinstalling from the Nodes page"

      _online ->
        "- #{name(id)}: " <> Enum.join(["online" | facts(info) ++ folder(info, workdir)], ", ")
    end
  end

  defp folder(%{"workspace" => workspace}, workdir)
       when is_binary(workspace) and workspace != "" and is_binary(workdir),
       do: ["working directory " <> Path.join(workspace, workdir)]

  defp folder(_info, _workdir), do: []

  defp name("local"), do: "local (this hub's own computer)"
  defp name(id), do: id

  defp facts(info) do
    for {key, label} <- [
          {"platform", ""},
          {"hostname", "hostname "},
          {"workspace", "workspace "},
          {"version", "photon-node "}
        ],
        is_binary(info[key]) and info[key] != "",
        do: label <> info[key]
  end

  defp version(%{"version" => version}) when is_binary(version) and version != "",
    do: " (#{version})"

  defp version(_info), do: ""
end
