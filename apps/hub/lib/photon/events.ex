defmodule Photon.Events do
  @moduledoc """
  The hub's PubSub announcements: how contexts tell open pages and channels
  that something changed.

  An announcement is only a hint to re-read. Every fact it describes is
  already committed (the durable store, the node keys, the settings
  file), and every page reads that state when it mounts. So a
  failed broadcast costs at most a page that refreshes late, and a failed
  subscription a page that doesn't update live. Neither is worth crashing
  the caller over: both are logged, and both functions return `:ok`.
  """

  use Boundary, deps: []

  require Logger

  @pubsub Photon.PubSub

  @doc "Announces `message` on `topic`. A failure is logged."
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message) do
    case Phoenix.PubSub.broadcast(@pubsub, topic, message) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("couldn't announce on #{topic}: #{inspect(reason)}")
    end
  end

  @doc "Subscribes the calling process to `topic`. A failure is logged."
  @spec subscribe(String.t()) :: :ok
  def subscribe(topic) do
    case Phoenix.PubSub.subscribe(@pubsub, topic) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("couldn't subscribe to #{topic}: #{inspect(reason)}")
    end
  end
end
