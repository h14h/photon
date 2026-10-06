defmodule Photon.TestProfile.Where do
  @moduledoc false
  # Reports the working directory its calls get: `execute/2` parks until the
  # signal "go" with the one it saw, `resume/2` answers with both, and
  # `on_interrupt/2` appends a "notice" entry naming the one it got.
  @behaviour Photon.Durable.Tool

  alias Photon.Durable.Tx

  @impl true
  def name, do: "where"
  @impl true
  def description, do: "Says which working directory it runs in."
  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}
  @impl true
  def replay, do: :safe
  @impl true
  def execute(_args, api), do: {:wait, %{"signal" => "go"}, %{"execute" => api.workdir}}
  @impl true
  def resume(state, api),
    do: {:ok, "execute: #{inspect(state["execute"])}, resume: #{inspect(api.workdir)}"}

  @impl true
  def on_interrupt(api, tx),
    do:
      Tx.append(tx, api.conversation_id, "notice", %{
        "message" => "interrupted in #{inspect(api.workdir)}"
      })
end
