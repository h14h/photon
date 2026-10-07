defmodule Photon.TestProfile.Commit do
  @moduledoc false
  # Returns a `{:commit, fun}` result: the result is decided inside the
  # commit that records it.
  @behaviour Photon.Durable.Tool

  @impl true
  def name, do: "commit"
  @impl true
  def description, do: "Decides its result inside the commit."
  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}
  @impl true
  def execute(_args, _api), do: {:commit, fn _tx -> {:ok, "committed"} end}
end
