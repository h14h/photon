defmodule Photon.Assistant.Page do
  @moduledoc """
  The page the user had open when they wrote to Blip, as pure functions.
  Blip floats over every page, so a message like "why did this fail?" means
  whatever is on screen.

  The web UI works out the page from its path (`session_id/1`) and the
  session it names (`of_session/1`), and shows it beside the message box
  (`label/1`). `Photon.Assistant.send/2` puts a note of it in front of the
  message the model sees (`note/2`), and the conversation takes the note
  off again to show the message as it was typed (`strip/1`).

  Only node sessions count for now; other pages have nothing to point at.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @typedoc "A page, as stored with the message it came with."
  @type t :: %{String.t() => String.t()}

  @prefix "[Looking at "

  @doc "The node session a page's path shows, if it shows one."
  @spec session_id(String.t()) :: String.t() | nil
  def session_id("/sessions/" <> id) when id != "" do
    if String.contains?(id, "/"), do: nil, else: id
  end

  def session_id(_path), do: nil

  @doc "The page for a node session: its ID, node and title."
  @spec of_session(%{
          :id => String.t(),
          :node_id => String.t(),
          :title => String.t() | nil,
          optional(atom()) => any()
        }) :: t()
  def of_session(session) do
    %{
      "kind" => "session",
      "session_id" => session.id,
      "node" => session.node_id,
      "title" => session.title || ""
    }
  end

  @doc "How the page reads beside the message box: \"kepler / Check disks\"."
  @spec label(t()) :: String.t()
  def label(%{"node" => node, "title" => ""}), do: node
  def label(%{"node" => node, "title" => title}), do: "#{node} / #{title}"

  @doc """
  The message the model sees: the page as a note on its own line, then
  `text`. Without a page, just `text`.
  """
  @spec note(String.t(), t() | nil) :: String.t()
  def note(text, nil), do: text

  def note(text, %{"session_id" => id, "node" => node, "title" => title}),
    do: "#{@prefix}#{node}'s session \"#{title}\" (session #{id})]\n\n" <> text

  @doc "The message as it was typed: `text` without the note `note/2` put in front."
  @spec strip(String.t()) :: String.t()
  def strip(@prefix <> _ = text) do
    case String.split(text, "\n\n", parts: 2) do
      [_note, typed] -> typed
      [_text] -> text
    end
  end

  def strip(text), do: text
end
