defmodule PhotonNode.Harness.Link do
  @moduledoc """
  How the harness reaches the hub: the contract for the node's hub link,
  and the two announcements the harness makes through it.

    * `event/3`: a session's log record at its offset, once it is written
    * `live/2`: ephemeral data for a session (model deltas, command output)

  The link is a module from the node's config (`PhotonNode.Config`,
  `:link`), `PhotonNode.Connection` unless a host sets another. So the
  dependency points one way: the connection depends on the harness (it
  hands the hub's inputs to `PhotonNode.Harness`), and the harness knows
  only this contract.

  Both are notifications whose loss costs nothing: a lost record is
  recovered when the hub resyncs, and live data is never stored. The
  link decides how they travel (`PhotonNode.Connection`'s moduledoc says
  why its sends don't wait).
  """

  @doc "Announces a session's log record at `offset`."
  @callback event(session_id :: String.t(), offset :: non_neg_integer(), record :: map()) :: :ok

  @doc "Streams ephemeral data for a session."
  @callback live(session_id :: String.t(), data :: map()) :: :ok

  @doc "Announces a session's log record at `offset` through the configured link."
  @spec event(String.t(), non_neg_integer(), map()) :: :ok
  def event(session_id, offset, record), do: link().event(session_id, offset, record)

  @doc "Streams ephemeral data for a session through the configured link."
  @spec live(String.t(), map()) :: :ok
  def live(session_id, data), do: link().live(session_id, data)

  defp link, do: PhotonNode.config().link
end
