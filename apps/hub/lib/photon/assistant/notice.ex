defmodule Photon.Assistant.Notice do
  @moduledoc """
  What Blip says without being asked, as pure functions. When the chat is
  closed, it shows in a speech bubble above Blip: the first paragraph of an
  answer, whole, as Markdown. `PhotonWeb.BlipLive` drives these.

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

  @doc "What a batch of newly committed conversation entries is worth saying, in order."
  @spec from_entries([Entry.t()]) :: [t()]
  def from_entries(entries), do: entries |> Enum.map(&of_entry/1) |> Enum.reject(&is_nil/1)

  defp of_entry(%{kind: "assistant", data: data}) do
    case data["message"] |> Message.text_of() |> paragraph() do
      "" -> nil
      text -> %{kind: :reply, text: text, session_id: nil}
    end
  end

  defp of_entry(%{kind: "error", data: data}) do
    if Transcript.quiet?(data),
      do: nil,
      else: %{kind: :error, text: paragraph(data["message"] || ""), session_id: nil}
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
  What of `text` goes in the bubble: its first paragraph (or list, or other
  block) with words in it, whole, as Markdown. Headings are left out: the
  bubble is Blip talking, not a document, and Blip's answers lead with the
  result.
  """
  @spec paragraph(String.t()) :: String.t()
  def paragraph(text) do
    text
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map(&without_headings/1)
    |> Enum.find("", &(&1 != ""))
  end

  # A block without its heading lines (a heading can sit right on top of a
  # paragraph, with no blank line between).
  defp without_headings(block) do
    block
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/\A {0,3}\#{1,6}(?:[ \t]|\z)/, &1))
    |> Enum.join("\n")
    |> String.trim()
  end
end
