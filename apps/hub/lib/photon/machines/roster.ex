defmodule Photon.Machines.Roster do
  @moduledoc """
  Which machines the hub knows, and what state each is in, as pure
  functions over what `Photon.Machines` reads: the connected nodes' info
  from the registry, the IDs of node keys that aren't revoked, and whether
  the hub runs its own node (`config :photon, :local_node`).

  The hub's own machine, `local`, has no node key. When the hub runs its own
  node, `local` is known whether or not it is connected, so a call on it
  waits while it is offline (at hub boot the durable harness reruns calls
  before the local node connects) instead of failing as unknown (hub rule 12
  in `docs/operations.md`).

  A connected node that doesn't list the `"ops:2"` capability runs a
  photon-node from before the operation protocol this hub speaks, and is
  `:outdated`. `ops:2` is `ops:1` plus one promise: a `shell` operation
  creates its working directory when it is missing, so a project's folder on
  a machine is made on first use. A step 1 node would fail a thread's first
  command with "start process ...: enoent" instead, so it gets no work until
  it is reinstalled.

  `ids/3` names the same machines as `build/3` without their state, in an
  order that ignores who is connected: `local` first, then by ID. Machine
  skills are listed in that order in every agent's prompt, so a machine
  connecting or disconnecting never changes one
  (`docs/decisions.md#prompts-and-compatibility`).
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Operation.Wire

  @local "local"
  @ops_capability Wire.capability()

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
  The IDs of every machine the hub knows, from the same inputs as
  `build/3`: `local` first, then by ID, whichever of them are connected.
  """
  @spec ids([info()], [String.t()], boolean()) :: [String.t()]
  def ids(online_infos, known_ids, local_node?) do
    local = if local_node?, do: [@local], else: []

    (Enum.map(online_infos, & &1["id"]) ++ local ++ known_ids)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1 != @local, &1})
  end

  @doc "Connected machines' info in the order they are listed: `local` first, then by ID."
  @spec sort([info()]) :: [info()]
  def sort(online_infos), do: Enum.sort_by(online_infos, &{&1["id"] != @local, &1["id"]})

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
