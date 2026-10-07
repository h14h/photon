defmodule Photon.Assistant.Notice do
  @moduledoc """
  What Blip says without being asked, as pure functions. When the chat is
  closed, it shows in a speech bubble above Blip: the first paragraph of an
  answer, whole, as Markdown. `PhotonWeb.BlipLive` drives these.

  Blip speaks up only about its own answers and failures in the
  conversation (`from_entries/1`), never with tips, and about a thread's
  question once it is with the owner (`:question`): Blip's `ask_owner`
  passing it on, in Blip's words, or the hub's notice that it passed on
  one Blip didn't get to, in the thread's. So a question reaches the
  owner with the panel shut. A signal message is never a notice; Blip's
  reply to it is, as any answer is, except in a run that only handles
  threads' questions (`Photon.Assistant.Origin`'s `quiet?`): there Blip
  answers to the threads, so the owner hears only the questions it
  passes on. `scan/2` follows the runs across batches for that.

  A question's notice names its thread by the title the conversation
  recorded, and keeps the thread's ID: `text/2` says it with the
  thread's current title, so a bubble on screen when the thread is named
  or renamed reads the new title.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, Photon.Transcript, Photon.Assistant.Origin]

  alias Photon.Assistant.Origin
  alias Photon.Durable.Entry
  alias Photon.Transcript
  alias PhotonCore.Message

  # The most of a question a bubble shows; the panel has all of it.
  @question_limit 280

  @typedoc """
  One thing Blip says: `:reply` (its answer), `:error` (the conversation
  failed) or `:question` (a thread's question is with the owner). A
  question also has its thread's ID and the title its text names it by.
  """
  @type t :: %{
          required(:kind) => :reply | :error | :question,
          required(:text) => String.t(),
          optional(:thread_id) => String.t() | nil,
          optional(:title) => String.t() | nil
        }

  @typedoc """
  What `scan/2` carries from one batch to the next: the sources of the
  user entries of the run in progress (newest first), and whether the last run ended (a
  model turn with no calls, or an error), so the next user entry starts
  a new one.
  """
  @type state :: %{sources: [term()], ended?: boolean()}

  @doc "The state before any entry: no run in progress."
  @spec initial() :: state()
  def initial, do: %{sources: [], ended?: true}

  @doc "What a batch of newly committed conversation entries is worth saying, in order."
  @spec from_entries([Entry.t()]) :: [t()]
  def from_entries(entries), do: entries |> scan(initial()) |> elem(0)

  @doc """
  `from_entries/1` for a batch that follows the batches `state` has seen:
  what the batch is worth saying, and the state for the next batch. A
  reply in a run that only handles threads' questions says nothing.
  """
  @spec scan([Entry.t()], state()) :: {[t()], state()}
  def scan(entries, state) do
    Enum.flat_map_reduce(entries, state, fn entry, state ->
      state = follow(state, entry)
      {entry |> of_entry(quiet?(state)) |> List.wrap(), ended(state, entry)}
    end)
  end

  # A user entry joins the run in progress, or starts the next one.
  defp follow(%{ended?: true}, %{kind: "user", data: data}),
    do: %{sources: [source(data)], ended?: false}

  defp follow(%{sources: sources}, %{kind: "user", data: data}),
    do: %{sources: [source(data) | sources], ended?: false}

  defp follow(state, _entry), do: state

  # A user entry with no source is one the owner typed.
  defp source(%{"source" => %{} = source}), do: source
  defp source(_data), do: %{"kind" => "user"}

  defp ended(state, %{kind: "assistant", data: data}),
    do: %{state | ended?: Message.tool_calls(data["message"]) == []}

  defp ended(state, %{kind: "error"}), do: %{state | ended?: true}
  defp ended(state, _entry), do: state

  defp quiet?(%{sources: sources}), do: Origin.of(sources).quiet?

  defp of_entry(%{kind: "assistant"}, true = _quiet), do: nil
  defp of_entry(entry, _quiet), do: of_entry(entry)

  defp of_entry(%{kind: "assistant", data: data}) do
    case data["message"] |> Message.text_of() |> paragraph() do
      "" -> nil
      text -> %{kind: :reply, text: text}
    end
  end

  defp of_entry(%{kind: "tool_result", data: data}) do
    details = data["details"]

    if Transcript.question_card(data),
      do: question(details["thread_id"], details["title"], details["wording"]),
      else: nil
  end

  defp of_entry(%{kind: "error", data: data} = entry) do
    cond do
      Transcript.escalation(entry) ->
        question(data["thread_id"], data["title"], data["question"])

      Transcript.quiet?(data) ->
        nil

      true ->
        %{kind: :error, text: paragraph(data["message"] || "")}
    end
  end

  defp of_entry(_entry), do: nil

  # `"Fix the pump" asks: <the question>`, the question on one line and
  # cut to what a bubble holds.
  defp question(thread_id, title, text) do
    title = if is_binary(title) and title != "", do: title
    named = if title, do: ~s("#{title}"), else: "A thread"
    thread_id = if is_binary(thread_id), do: thread_id

    text =
      case one_line(text) do
        "" -> named <> " has a question for you."
        text -> named <> " asks: " <> text
      end

    %{kind: :question, text: text, thread_id: thread_id, title: title}
  end

  @doc """
  What a notice says, with its thread under its current title from
  `titles` (thread ID to title, nil for a thread that is gone): a
  question's notice names the thread it came from by the title it had
  then, which may since have changed. Anything else says its text.
  """
  @spec text(t(), Transcript.titles()) :: String.t()
  def text(%{kind: :question, text: text, thread_id: id, title: old}, titles)
      when is_binary(old) do
    case Transcript.title(titles, id, old) do
      ^old -> text
      new -> ~s("#{new}") <> String.replace_prefix(text, ~s("#{old}"), "")
    end
  end

  def text(%{text: text}, _titles), do: text

  defp one_line(text) when is_binary(text) do
    text = text |> String.split() |> Enum.join(" ")

    if String.length(text) > @question_limit,
      do: String.slice(text, 0, @question_limit - 3) <> "...",
      else: text
  end

  defp one_line(_text), do: ""

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
