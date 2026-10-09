defmodule Photon.Signals.Rules do
  @moduledoc """
  Which settles reach Blip, and how a signal joins Blip's inbox, as pure
  functions over source maps and submission content.

  `thread_update/2` decides, in code, whether Blip hears about a thread's
  settled run. In quiet mode Blip hears about work it started however it
  ends, and about failures and questions in the owner's threads; a stop is
  never a signal. Ambient mode is quiet mode with one more cell: the owner's
  run that ends `"done"` without asking anything is `:digest`, an item for
  the next digest rather than a signal. Whose work it was comes from the
  settled submissions' sources (`blip_source?/1`), not from who started the
  thread.

  `ambient_kind/1` tells a digest or a daily review message from the
  other signal messages, so `Photon.Signals` can find one still queued,
  and `ambient_ref/1` reads its ref. `item_key/1` is a digest item's
  subject, which makes one row per subject.

  A signal is one text part and one ref in a `"signal"` message to Blip.
  `merges?/2` says whether a queued message takes another signal: only
  one whose refs are all of the new ref's kind, so updates collect in one
  message and questions in another, and a question never shares a run
  with an update. `merge/3` and `without/2` add and take back one signal,
  keeping its part and ref at the same index.

  Everything here runs inside the harness's settle hook, so it is total:
  any term in, a value out.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @typedoc """
  What Blip hears about a settled run, or nil for nothing. `:digest` is
  ambient mode's: an item for the next digest, not a signal.
  """
  @type kind :: :finished | :asking | :failed | :digest

  @typedoc "Which signals reach Blip: step 4's quiet mode, or ambient mode on top of it."
  @type mode :: :quiet | :ambient

  @typedoc """
  A settle's facts: how it ended (`outcome`), whether a `"done"` answer
  asks the user something (`asked?`), whether the run ends with it
  (`ended?`), and the settled submissions' source maps (`sources`).
  """
  @type facts :: %{
          outcome: String.t(),
          asked?: boolean(),
          ended?: boolean(),
          sources: [map() | nil]
        }

  @typedoc "A signal's ref, as stored in its message's `source[\"signals\"]`."
  @type ref :: %{optional(String.t()) => term()}

  @typedoc "Where a thread is, for a ref: its ID and title, its project's ID, slug and name."
  @type place :: %{
          thread_id: String.t(),
          title: String.t(),
          project_id: String.t(),
          slug: String.t(),
          project: String.t()
        }

  @doc """
  What Blip hears about a thread's settled run in `mode`, or nil. With a
  Blip source among the settled submissions (`blip_source?/1`): a finished
  run is `:finished`, one that ended asking the user `:asking`, a failure
  `:failed`. Without one (the owner's message, the owner's schedule, or
  nothing placed at all): only `:asking` when the run ended asking, and
  `:failed`. A stop is never a signal. Asking only counts when the run
  ended: with the next message already queued, its answer is on the way,
  so Blip's own work then reads as `:finished`.

  In `:ambient` mode every cell is the same but one: without a Blip
  source, a `"done"` run that ends without asking is `:digest`. A settle
  the run goes on from (`ended?: false`) is nil in both modes, so a
  thread answering one queued input after another makes one item, at its
  end.
  """
  @spec thread_update(facts() | term(), mode() | term()) :: kind() | nil
  def thread_update(%{outcome: outcome} = facts, mode) when mode in [:quiet, :ambient] do
    blip? = facts |> Map.get(:sources) |> List.wrap() |> Enum.any?(&blip_source?/1)
    ended? = Map.get(facts, :ended?) == true
    asking? = Map.get(facts, :asked?) == true and ended?

    case quiet(outcome, asking?, blip?) do
      nil when mode == :ambient and outcome == "done" and ended? and not blip? -> :digest
      kind -> kind
    end
  end

  def thread_update(_facts, _mode), do: nil

  defp quiet("failed", _asking?, _blip?), do: :failed
  defp quiet("done", true, _blip?), do: :asking
  defp quiet("done", false, true), do: :finished
  defp quiet(_outcome, _asking?, _blip?), do: nil

  @doc """
  Which ambient message a message with `source` is: `"digest"` or
  `"review"` when it is a signal message carrying a ref of that kind,
  else nil. A digest or review ref never merges with another kind
  (`merges?/2`), so its first ref says.
  """
  @spec ambient_kind(term()) :: String.t() | nil
  def ambient_kind(%{"kind" => "signal", "signals" => [%{"kind" => kind} | _rest]})
      when kind in ["digest", "review"],
      do: kind

  def ambient_kind(_source), do: nil

  @doc """
  The digest or review ref a message with `source` carries (its first
  ref, as `ambient_kind/1` reads it), or nil for any other message.
  """
  @spec ambient_ref(term()) :: ref() | nil
  def ambient_ref(%{"signals" => [ref | _rest]} = source) do
    if ambient_kind(source), do: ref
  end

  def ambient_ref(_source), do: nil

  @doc """
  A digest item's key: its subject, so one subject holds one row and a newer
  change to it replaces the older one:

    * `"finished"`, `"thread_started"`, `"resolved"`: `"<kind>:<thread id>"`
    * `"schedule_stopped"`: `"schedule_stopped:<schedule id>"`
    * `"file_written"`: `"file_written:<project id>:<file name>"`
    * `"project_created"`, `"purpose_changed"`: `"<kind>:<project id>"`

  Nil when the item lacks what its kind is about, or its kind is unknown.
  """
  @spec item_key(term()) :: String.t() | nil
  def item_key(%{kind: kind} = item) when kind in ["finished", "thread_started", "resolved"],
    do: join([kind, Map.get(item, :thread_id)])

  def item_key(%{kind: "schedule_stopped"} = item),
    do: join(["schedule_stopped", Map.get(item, :schedule_id)])

  def item_key(%{kind: "file_written"} = item),
    do: join(["file_written", Map.get(item, :project_id), Map.get(item, :name)])

  def item_key(%{kind: kind} = item) when kind in ["project_created", "purpose_changed"],
    do: join([kind, Map.get(item, :project_id)])

  def item_key(_item), do: nil

  defp join(parts) do
    if Enum.all?(parts, &(is_binary(&1) and &1 != "")), do: Enum.join(parts, ":")
  end

  @doc """
  Whether input came from Blip: a message Blip sent (source kind
  `"blip"`), or a firing of a schedule Blip made (`"routine"` with
  `"created_by" => "blip"`). Anything else, nil included, is the owner's.
  """
  @spec blip_source?(term()) :: boolean()
  def blip_source?(%{"kind" => "blip"}), do: true
  def blip_source?(%{"kind" => "routine", "created_by" => "blip"}), do: true
  def blip_source?(_source), do: false

  @doc """
  A signal's key, unique to what it is about: `"settle:<submission id>"`
  for a settle, after the first submission it closes (each is settled
  once), or `"settle:<task id>:end"` for one that closes none; and
  `"question:<question id>"` for a question.
  """
  @spec key({:settle, [String.t()], String.t()} | {:question, String.t()}) :: String.t()
  def key({:settle, [first | _rest], _task_id}), do: "settle:" <> first
  def key({:settle, [], task_id}), do: "settle:#{task_id}:end"
  def key({:question, id}), do: "question:" <> id

  @doc """
  The ref of a thread update: what the panel draws the line from and
  links to. `status` is the update's kind.
  """
  @spec update_ref(kind(), String.t(), place()) :: ref()
  def update_ref(kind, key, place) do
    place
    |> place_ref()
    |> Map.merge(%{"kind" => "thread_update", "key" => key, "status" => Atom.to_string(kind)})
  end

  @doc "The ref of an `ask_blip` question."
  @spec question_ref(String.t(), String.t(), place()) :: ref()
  def question_ref(question_id, key, place) do
    place
    |> place_ref()
    |> Map.merge(%{"kind" => "question", "key" => key, "question_id" => question_id})
  end

  defp place_ref(place) do
    %{
      "thread_id" => place.thread_id,
      "title" => place.title,
      "project_id" => place.project_id,
      "slug" => place.slug,
      "project" => place.project
    }
  end

  @doc """
  Whether a queued message with `source` takes the signal `ref`: it is a
  signal message, and every ref it carries is of `ref`'s kind
  (`"thread_update"`, `"question"`, `"digest"` or `"review"`).
  """
  @spec merges?(term(), ref() | term()) :: boolean()
  def merges?(%{"kind" => "signal", "signals" => [_ | _] = refs}, %{"kind" => kind}),
    do: Enum.all?(refs, &match?(%{"kind" => ^kind}, &1))

  def merges?(_source, _ref), do: false

  @doc "Whether a message with `source` carries the signal with `key`."
  @spec carries?(term(), term()) :: boolean()
  def carries?(%{"kind" => "signal", "signals" => refs}, key) when is_list(refs),
    do: Enum.any?(refs, &match?(%{"key" => ^key}, &1))

  def carries?(_source, _key), do: false

  @doc """
  A signal message's content with one more signal: `part` after its parts
  and `ref` after its refs.
  """
  @spec merge(map(), map(), ref()) :: map()
  def merge(content, part, ref) do
    source = Map.get(content, "source") || %{}

    Map.merge(content, %{
      "parts" => List.insert_at(parts(content), -1, part),
      "source" => Map.put(source, "signals", List.insert_at(refs(source), -1, ref))
    })
  end

  @doc """
  A signal message's content without the signal `key`: `:withdraw` when
  it was the only one, `{:keep, content}` with its part and ref dropped
  when there are others, `:absent` when the message doesn't carry it.
  """
  @spec without(map(), String.t()) :: :withdraw | {:keep, map()} | :absent
  def without(content, key) do
    source = Map.get(content, "source") || %{}
    refs = refs(source)

    case Enum.find_index(refs, &match?(%{"key" => ^key}, &1)) do
      nil ->
        :absent

      _index when length(refs) == 1 ->
        :withdraw

      index ->
        {:keep,
         Map.merge(content, %{
           "parts" => List.delete_at(parts(content), index),
           "source" => Map.put(source, "signals", List.delete_at(refs, index))
         })}
    end
  end

  defp parts(%{"parts" => parts}) when is_list(parts), do: parts
  defp parts(_content), do: []

  defp refs(%{"signals" => refs}) when is_list(refs), do: refs
  defp refs(_source), do: []
end
