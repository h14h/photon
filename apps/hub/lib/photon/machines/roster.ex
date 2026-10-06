defmodule Photon.Machines.Roster do
  @moduledoc """
  Which machines the hub knows, and what state each is in, as pure
  functions over what `Photon.Machines` reads: the connected nodes' info
  from the registry, the IDs of node keys that aren't revoked, and whether
  the hub runs its own node (`config :photon, :local_node`).

  The hub's own machine, `local`, has no node key. When the hub runs its
  own node, `local` is known whether or not it is connected, so a call on
  it waits while it is offline (at hub boot the durable harness reruns
  calls before the local node connects) instead of failing as unknown
  (section 2.3, hub rule 12, of `docs/plans/step-1-machine-tools.md`).

  A connected node that doesn't list the `"ops:1"` capability runs a
  photon-node from before the operation protocol, and is `:outdated`.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @local "local"
  @ops_capability "ops:1"

  @typedoc "A connected node's info from the registry, with its `\"id\"`."
  @type info :: %{optional(String.t()) => term()}

  @typedoc "A machine as listed: its ID, whether it is connected, and its info if so."
  @type machine :: %{id: String.t(), online: boolean(), info: info() | nil}

  @type status :: :online | :offline | :outdated | :unknown

  @doc """
  Every machine the hub knows: `local` first (online or, when the hub runs
  its own node, offline), then the other connected machines by ID, then
  the known offline ones by ID.
  """
  @spec build([info()], [String.t()], boolean()) :: [machine()]
  def build(online_infos, known_ids, local_node?) do
    online_ids = MapSet.new(online_infos, & &1["id"])
    known = if local_node?, do: [@local | known_ids], else: known_ids

    offline =
      for id <- Enum.uniq(known),
          not MapSet.member?(online_ids, id),
          do: %{id: id, online: false, info: nil}

    (Enum.map(online_infos, &%{id: &1["id"], online: true, info: &1}) ++ offline)
    |> Enum.sort_by(&{&1.id != @local, not &1.online, &1.id})
  end

  @doc """
  The state of `machine`, given its info if it is connected (nil if not),
  the known IDs and whether the hub runs its own node.
  """
  @spec status(String.t(), info() | nil, [String.t()], boolean()) :: status()
  def status(_machine, %{} = info, _known_ids, _local_node?) do
    if ops?(info), do: :online, else: :outdated
  end

  def status(@local, nil, _known_ids, true), do: :offline

  def status(machine, nil, known_ids, _local_node?),
    do: if(machine in known_ids, do: :offline, else: :unknown)

  defp ops?(%{"capabilities" => capabilities}) when is_list(capabilities),
    do: @ops_capability in capabilities

  defp ops?(_info), do: false
end
