defmodule Photon.TestProfile.Raise do
  @moduledoc false
  # Raises in `execute/2`. Its `on_interrupt/2` appends a "notice" entry, so a
  # test can see that it ran and in which commit.
  @behaviour Photon.Durable.Tool

  alias Photon.Durable.Tx

  @impl true
  def name, do: "raise"
  @impl true
  def description, do: "Raises."
  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}
  @impl true
  def execute(_args, _api), do: raise("boom")
  @impl true
  def on_interrupt(api, tx),
    do: Tx.append(tx, api.conversation_id, "notice", %{"message" => "handed off"})
end
