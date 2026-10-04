defmodule Photon.TestProfile.Wait do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  @impl true
  def name, do: "wait"
  @impl true
  def description, do: "Waits for the signal go."
  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}
  @impl true
  def replay, do: :safe
  @impl true
  def execute(_args, _api), do: {:wait, %{"signal" => "go"}, %{}}
  @impl true
  def resume(_state, _api), do: {:ok, "went"}
end
