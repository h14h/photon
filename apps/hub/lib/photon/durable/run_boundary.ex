defmodule Photon.Durable.RunBoundary do
  @moduledoc """
  Where a run ends among a conversation's entries: an answer with no tool
  calls, or an error that isn't a notice. A notice (`"notice" => true`: the
  hub's word about a question, or a schedule it skipped) sits between a
  run's entries without ending it; Stop's quiet error does end it.

  `Photon.Durable.Context`, `Photon.Transcript` and
  `Photon.Assistant.Notice` share this rule, so they agree on which run an
  entry belongs to.
  """

  # Functional core, top-level so the projections in other contexts can
  # depend on it alone.
  use Boundary, top_level?: true, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Message

  @doc "Whether `entry` (a `Photon.Durable.Entry` or a map with its `kind` and `data`) ends a run."
  @spec ends?(%{
          required(:kind) => String.t(),
          required(:data) => map(),
          optional(atom()) => term()
        }) ::
          boolean()
  def ends?(%{kind: "assistant", data: %{"message" => message}}),
    do: Message.tool_calls(message) == []

  def ends?(%{kind: "error", data: data}), do: data["notice"] != true
  def ends?(_entry), do: false
end
