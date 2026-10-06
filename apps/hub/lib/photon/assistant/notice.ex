defmodule Photon.Assistant.Notice do
  @moduledoc """
  What Blip says without being asked, as pure functions. When the chat is
  closed, it shows in a speech bubble above Blip: the first paragraph of an
  answer, whole, as Markdown. `PhotonWeb.BlipLive` drives these.

  Blip speaks up only about its own answers and failures in the
  conversation (`from_entries/1`), never with tips.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, Photon.Transcript]

  alias Photon.Durable.Entry
  alias Photon.Transcript
  alias PhotonCore.Message

  @typedoc "One thing Blip says: `:reply` (its answer) or `:error` (the conversation failed)."
  @type t :: %{kind: :reply | :error, text: String.t()}

  @doc "What a batch of newly committed conversation entries is worth saying, in order."
  @spec from_entries([Entry.t()]) :: [t()]
  def from_entries(entries), do: entries |> Enum.map(&of_entry/1) |> Enum.reject(&is_nil/1)

  defp of_entry(%{kind: "assistant", data: data}) do
    case data["message"] |> Message.text_of() |> paragraph() do
      "" -> nil
      text -> %{kind: :reply, text: text}
    end
  end

  defp of_entry(%{kind: "error", data: data}) do
    if Transcript.quiet?(data),
      do: nil,
      else: %{kind: :error, text: paragraph(data["message"] || "")}
  end

  defp of_entry(_entry), do: nil

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
