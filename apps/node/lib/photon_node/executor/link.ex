defmodule PhotonNode.Executor.Link do
  @moduledoc """
  How the executor reaches the hub: the contract for the node's hub link,
  and the two announcements the executor makes through it.

    * `snapshot/1`: an operation's latest snapshot, once it is journaled
      (or an answer the node doesn't journal, such as `Request.lost/2`)
    * `output/3`: new output of a running command, never stored

  The link is a module from the node's config (`PhotonNode.Config`,
  `:link`), `PhotonNode.Connection` unless a host or a test sets another.
  So the dependency points one way: the connection calls the executor with
  the hub's messages, and the executor knows only this contract.

  Both are notifications whose loss costs nothing durable: every journaled
  snapshot is sent again after each join, and live output is never stored.
  The link decides how they travel; it must not call back into the
  executor, which waits for it.
  """

  alias PhotonCore.Operation

  @doc "Sends an operation's latest snapshot to the hub."
  @callback snapshot(op :: Operation.t()) :: :ok

  @doc ~S|Streams new output of a running operation (`stream` is `"out"` or `"err"`).|
  @callback output(op_id :: String.t(), stream :: String.t(), text :: String.t()) :: :ok

  @doc "Sends a snapshot through the configured link."
  @spec snapshot(Operation.t()) :: :ok
  def snapshot(op), do: link().snapshot(op)

  @doc "Streams output through the configured link."
  @spec output(String.t(), String.t(), String.t()) :: :ok
  def output(op_id, stream, text), do: link().output(op_id, stream, text)

  defp link, do: PhotonNode.config().link
end
