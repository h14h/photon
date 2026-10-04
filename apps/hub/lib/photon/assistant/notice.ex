defmodule Photon.Assistant.Notice do
  @moduledoc """
  What Blip says without being asked, as pure functions. When the chat is
  closed, Blip stretches into a pill with one line of it; `PhotonWeb.BlipLive`
  drives these.

  Blip speaks up only about work it was asked to do and about real
  problems, never with tips:

    * its own answers, and failures in the conversation (`from_entries/1`)
    * node work the user started themselves, only when it fails
      (`failures/2`, against `statuses/1` from before)
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, Photon.Assistant.Transcript]

  alias Photon.Assistant.Transcript
  alias Photon.Durable.Entry
  alias PhotonCore.Message

  @typedoc """
  One thing Blip says: `:reply` (its answer), `:error` (the conversation
  failed) or `:failed` (node work the user started failed; `session_id`
  names it).
  """
  @type t :: %{kind: :reply | :error | :failed, text: String.t(), session_id: String.t() | nil}

  @typedoc "Where each node session stands, by ID, as far as `failures/2` cares."
  @type statuses :: %{String.t() => :active | :failed | :other}

  @gist_length 110

  @doc "What a batch of newly committed conversation entries is worth saying, in order."
  @spec from_entries([Entry.t()]) :: [t()]
  def from_entries(entries), do: entries |> Enum.map(&of_entry/1) |> Enum.reject(&is_nil/1)

  defp of_entry(%{kind: "assistant", data: data}) do
    case data["message"] |> Message.text_of() |> gist() do
      "" -> nil
      text -> %{kind: :reply, text: text, session_id: nil}
    end
  end

  defp of_entry(%{kind: "error", data: data}) do
    if Transcript.quiet?(data),
      do: nil,
      else: %{kind: :error, text: gist(data["message"] || ""), session_id: nil}
  end

  defp of_entry(_entry), do: nil

  @doc "Where each of the user's own node sessions stands."
  @spec statuses([map()]) :: statuses()
  def statuses(sessions) do
    for %{origin: "user"} = session <- sessions, into: %{}, do: {session.id, status(session)}
  end

  defp status(%{status: status}) when status in ["pending", "running"], do: :active
  defp status(%{status: "failed"}), do: :failed
  defp status(%{status: "idle", last_failure: failure}) when failure not in [nil, ""], do: :failed
  defp status(_session), do: :other

  @doc """
  The user's own node sessions that failed since `before` (from
  `statuses/1`): ones that were working then and have failed now.
  """
  @spec failures(statuses(), [map()]) :: [t()]
  def failures(before, sessions) do
    for %{origin: "user"} = session <- sessions,
        before[session.id] == :active,
        status(session) == :failed do
      %{
        kind: :failed,
        text: ~s(#{session.node_id} couldn't finish "#{session.title}".),
        session_id: session.id
      }
    end
  end

  @doc """
  One line of `text` for the pill: its first line that has words, without
  Markdown marks, cut short with "..." if it runs long.
  """
  @spec gist(String.t()) :: String.t()
  def gist(text) do
    line =
      text
      |> String.split("\n")
      |> Enum.map(&plain/1)
      |> Enum.find("", &(&1 != ""))

    if String.length(line) > @gist_length,
      do: String.slice(line, 0, @gist_length - 3) <> "...",
      else: line
  end

  # A line without its block marks (heading, quote, list) or inline ones.
  defp plain(line) do
    line
    |> String.replace(~r/\A\s*(?:#+|>|[-*+]|\d+[.)])\s+/, "")
    |> String.replace(~r/\*\*|__|`/, "")
    |> String.trim()
  end
end
