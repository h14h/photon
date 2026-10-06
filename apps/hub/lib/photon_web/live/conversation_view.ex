defmodule PhotonWeb.ConversationView do
  @moduledoc """
  The socket side of a durable conversation on screen, shared by Blip's
  panel (`PhotonWeb.BlipLive`) and a project's thread page: plain functions
  over a LiveView socket, not a process. The page reads the conversation
  through its context and hands what it read here; these functions only
  fold it into assigns and the `:entries` stream, through
  `Photon.Transcript`, so the fold lives in one place and the pages'
  callbacks stay short (rule 30).

  `mount_conversation/3` sets up the assigns `PhotonWeb.ConversationComponents`
  render from:

  - `results` and `calls`: each tool call's result, and the assistant entry
    that made each call, so a result can re-render its answer
    (`Photon.Transcript.index/1`);
  - `outputs`: the end of each running `shell` call's output, by call ID,
    from the `tool_output` live events (the hub stores none of it, so a page
    opened mid-command shows output from then on), dropped when the result
    comes, unless the call was stopped (then it stays, as all there is to
    show of what it did; a page opened later has none of it);
  - `live` and `shown`: the in-flight answer, and its finished blocks;
  - `empty?`, `busy`, `queued`, and the composer's `mode` and `form`;
  - the `:entries` stream of what the conversation shows.

  `apply_changes/4` folds a commit's `{:durable, ...}` changes in,
  `apply_live/2` a `{:live, ...}` event, and `reset_form/1` empties the
  composer after a send.
  """

  import Phoenix.Component, only: [assign: 2, update: 3, to_form: 2]
  import Phoenix.LiveView, only: [stream: 3, stream_configure: 3, stream_insert: 3]

  alias Phoenix.LiveView.Socket
  alias Photon.{Markdown, Transcript}

  @doc """
  Sets up a conversation's assigns and its `:entries` stream from its
  entries. Options: `busy:` and `queued:` (both required), and `dom_id:`, a
  function from an entry to its DOM ID (the stream's default,
  `entries-<id>`, without it).
  """
  @spec mount_conversation(Socket.t(), [map()], keyword()) :: Socket.t()
  def mount_conversation(socket, entries, opts) do
    %{results: results, calls: calls} = Transcript.index(entries)

    socket
    |> assign(
      results: results,
      calls: calls,
      outputs: %{},
      empty?: Transcript.empty?(entries),
      live: nil,
      shown: nil,
      busy: Keyword.fetch!(opts, :busy),
      queued: Keyword.fetch!(opts, :queued),
      mode: "follow_up",
      form: blank_form()
    )
    |> configure(opts[:dom_id])
    |> stream(:entries, Enum.filter(entries, &Transcript.shown?/1))
  end

  defp configure(socket, nil), do: socket
  defp configure(socket, dom_id), do: stream_configure(socket, :entries, dom_id: dom_id)

  @doc """
  Folds a commit's changes in: its entries, then whether the conversation
  is busy and what waits in its inbox, both read by the caller after the
  commit. Once it isn't busy, there's no in-flight answer.
  """
  @spec apply_changes(Socket.t(), %{entries: [map()]}, boolean(), [map()]) :: Socket.t()
  def apply_changes(socket, changes, busy, queued) do
    socket = Enum.reduce(changes.entries, socket, &add_entry(&2, &1))
    socket = assign(socket, queued: queued, busy: busy)
    if busy, do: socket, else: assign(socket, live: nil, shown: nil)
  end

  @doc """
  Folds a live event in. A running call's output is kept as a tail under
  it; output that comes after the result (or for no call on the page) has
  nowhere to go. Every other event is the in-flight answer.
  """
  @spec apply_live(Socket.t(), map()) :: Socket.t()
  def apply_live(socket, %{"type" => "tool_output", "call_id" => call_id} = event) do
    if Map.has_key?(socket.assigns.results, call_id) do
      socket
    else
      socket |> update(:outputs, &Transcript.tool_output(&1, event)) |> show_call(call_id)
    end
  end

  def apply_live(socket, event) do
    live = Transcript.live(socket.assigns.live, event)
    assign(socket, live: live, shown: shown(live))
  end

  @doc "Empties the composer and puts it back to sending after the current answer."
  @spec reset_form(Socket.t()) :: Socket.t()
  def reset_form(socket), do: assign(socket, form: blank_form(), mode: "follow_up")

  defp blank_form, do: to_form(%{"text" => ""}, as: :message)

  # What of the in-flight answer is shown: its finished blocks, so it comes
  # in a paragraph at a time (`Photon.Markdown.settled/1`). Its Markdown is
  # rendered again only when a block is added, not on every token.
  defp shown(live),
    do: %{text: Markdown.settled(live.text), reasoning: Markdown.settled(live.reasoning)}

  # A tool result re-renders the assistant entry whose call it answers, in
  # place of the output the call streamed while it ran (which a stopped
  # call keeps).
  defp add_entry(socket, %{kind: "tool_result"} = entry) do
    call_id = Transcript.call_id(entry)
    results = Transcript.add_result(socket.assigns.results, entry)

    socket
    |> assign(results: results)
    |> update(:outputs, &Transcript.settle_output(&1, call_id, results[call_id]))
    |> show_call(call_id)
  end

  defp add_entry(socket, %{kind: "assistant"} = entry) do
    socket
    |> update(:calls, &Transcript.add_calls(&1, entry))
    |> assign(live: nil, shown: nil, empty?: false)
    |> stream_insert(:entries, entry)
  end

  defp add_entry(socket, entry) do
    if Transcript.shown?(entry),
      do: socket |> assign(empty?: false) |> stream_insert(:entries, entry),
      else: socket
  end

  # Re-renders the assistant entry that made a call, if it's on the page.
  defp show_call(socket, call_id) do
    case socket.assigns.calls[call_id] do
      nil -> socket
      parent -> stream_insert(socket, :entries, parent)
    end
  end
end
