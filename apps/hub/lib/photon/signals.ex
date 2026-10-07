defmodule Photon.Signals do
  @moduledoc """
  What reaches Blip unasked (sections 3 and 4 of
  `docs/plans/step-4-blip-as-coordinator.md`): thread updates and
  `ask_blip` questions, posted into Blip's conversation as messages with
  source kind `"signal"`; the owner's answers to questions, which have
  already gone to the thread (`answer_tx/3`, source kind `"answer"`); and
  notices for the owner when a question is passed on or withdrawn
  (`notice_tx/3`). It also owns finding Blip's conversation
  (`blip_conversation_id/0`), since `Photon.Threads` and
  `Photon.Questions` post into it and can't depend on `Photon.Assistant`,
  which depends on them.

  Which settles become signals is decided in code, never by a model:
  `Photon.Threads`' settle hook asks `Photon.Signals.Rules.thread_update/2`
  in the mode `mode/0` gives, and writes the text with
  `Photon.Signals.Text`. In quiet mode, the default, Blip hears about
  work it started, and about failures and questions in the owner's
  threads.

  ## The merge

  `post_tx/2` runs inside the commit that stores what the signal is
  about. When Blip is idle the signal starts a run, as any message does.
  While Blip is busy, signals of one kind collect in one queued message,
  a part and a ref each (`Photon.Signals.Rules.merges?/2`): updates in
  one, questions in another, never both in one, so a burst wakes the
  model once per kind and a run that answers a question carries no update.
  A signal's key makes it once, whether it started a message or joined
  one. `unpost_tx/2` takes one back while it is still queued.

  ## Ambient mode

  Ambient mode (`docs/plans/step-5-ambient-mode.md`) is a setting, off by
  default. Its settings are the durable doc `global/ambient`, which this
  module reads and writes (`ambient_doc/0`, `ambient_doc_tx/1`,
  `put_ambient_doc_tx/2`) because the threads' settle hook reads it inside
  its commit and can't depend on `Photon.Ambient`, which depends on
  `Photon.Threads`. What the doc holds is `Photon.Ambient`'s, which writes
  it in the commit that arms or retires its timers; here only `"on"` is
  read: `mode/0` and `mode_tx/1` are `:ambient` when it is true, else
  `:quiet`.

  While it is on, the changes Blip doesn't hear about at once are
  collected as digest items (`Photon.Signals.DigestItem`, section 3.2):
  `collect_tx/2` runs inside the commit that makes each change, reads the
  mode there, and inserts nothing in quiet mode, so turning ambient mode
  off in one commit stops collection from the next. A digest reads them
  (`pending_tx/1`) and deletes what it carried (`drop_items_tx/2`) in the
  commit that posts it. `queued_ambient?/2` says whether a digest or
  review still waits in Blip's inbox, and `withdraw_ambient_tx/1` takes
  them back when ambient mode is turned off. Every insert announces
  `{:ambient_changed}` on `ambient_topic/0`.

  There is no process here: signals are submissions in Blip's
  conversation, the items are rows, and the harness runs them.
  """

  use Boundary,
    deps: [Photon.Durable, Photon.Repo, PhotonCore, Ecto],
    exports: [DigestItem, Rules, Text]

  import Ecto.Query

  alias Photon.{Durable, Repo}
  alias Photon.Durable.{Submission, Tx}
  alias Photon.Signals.{DigestItem, Rules, Text}
  alias PhotonCore.Message

  @ambient_topic "ambient"

  @item_kinds ~w(finished schedule_stopped file_written project_created purpose_changed thread_started resolved)

  @item_fields [:thread_id, :project_id, :schedule_id, :name, :writer]

  @note_limit 600

  @typedoc """
  A signal: its `key` (`Photon.Signals.Rules.key/1`), the `text` the model
  reads (`Photon.Signals.Text`), and the `ref` the panel draws it from.
  A digest or review also carries `older`, what Blip's later requests send
  in its place (`Photon.Durable.Context`).
  """
  @type t :: %{
          required(:key) => String.t(),
          required(:text) => String.t(),
          required(:ref) => Rules.ref(),
          optional(:older) => older()
        }

  @typedoc """
  The stub a message is sent as once Blip has moved on (`"text"`), and the
  answer that leaves its run out of later requests (`"drop_if_answer"`).
  """
  @type older :: %{optional(String.t()) => String.t()}

  @typedoc """
  An `ask_blip` question, as `Photon.Questions.Question` holds it: its ID,
  and where its thread was when it asked.
  """
  @type question :: %{
          required(:id) => String.t(),
          required(:thread_id) => String.t(),
          required(:thread_title) => String.t(),
          required(:project_id) => String.t(),
          required(:project_slug) => String.t(),
          required(:project_name) => String.t(),
          optional(atom()) => term()
        }

  @typedoc """
  A digest item to collect (section 3.2 of
  `docs/plans/step-5-ambient-mode.md`): its `key` and `kind`, and what it
  names; missing fields are nil.
  """
  @type item :: %{
          required(:key) => String.t(),
          required(:kind) => String.t(),
          optional(:thread_id) => String.t() | nil,
          optional(:project_id) => String.t() | nil,
          optional(:schedule_id) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:writer) => String.t() | nil,
          optional(:note) => String.t() | nil
        }

  ## The mode

  @doc "Which signals reach Blip: `:ambient` while ambient mode is on, else `:quiet`."
  @spec mode() :: Rules.mode()
  def mode, do: mode_of(ambient_doc())

  @doc "`mode/0` inside the caller's commit, so a collector reads it in its own commit."
  @spec mode_tx(Tx.t()) :: Rules.mode()
  def mode_tx(tx), do: mode_of(ambient_doc_tx(tx))

  defp mode_of(%{"on" => true}), do: :ambient
  defp mode_of(_doc), do: :quiet

  @doc """
  Ambient mode's doc (`global/ambient`), or an empty map before it was
  first saved. Its contents are `Photon.Ambient`'s.
  """
  @spec ambient_doc() :: map()
  def ambient_doc, do: Durable.doc("global", "ambient")

  @doc "`ambient_doc/0` inside the caller's commit."
  @spec ambient_doc_tx(Tx.t()) :: map()
  def ambient_doc_tx(tx), do: Tx.get_doc(tx, "global", "ambient")

  @doc "Writes ambient mode's doc in the caller's commit; returns it."
  @spec put_ambient_doc_tx(Tx.t(), map()) :: map()
  def put_ambient_doc_tx(tx, doc) when is_map(doc), do: Tx.put_doc(tx, "global", "ambient", doc)

  @doc "The topic `{:ambient_changed}` is announced on."
  @spec ambient_topic() :: String.t()
  def ambient_topic, do: @ambient_topic

  ## Digest items

  @doc """
  Collects `item` for the next digest, inside the caller's commit: inserts
  it while ambient mode is on (read in this commit) and its key is new,
  and then announces `{:ambient_changed}`; does nothing otherwise. It
  runs on the harness's hook paths (the settle hook in the Scheduler's
  abort and fail commits, a routine's `on_fail/3`), so it is total: a
  missing or non-text field is nil, a note longer than 600 characters is
  cut, an item without a key or with an unknown kind collects nothing,
  and it never raises.
  """
  @spec collect_tx(Tx.t(), item() | term()) :: :ok
  def collect_tx(tx, item) do
    with %{key: key, kind: kind} = fields <- item_fields(item),
         :ambient <- mode_tx(tx),
         false <- DigestItem |> where([i], i.key == ^key) |> Repo.exists?() do
      # Repo.insert!/2 raises on a failed insert; the key was checked
      # above in this commit, so on_conflict only guards a repeat.
      _item =
        DigestItem
        |> struct!(Map.merge(fields, %{id: PhotonCore.ID.new("di_"), kind: kind}))
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:key])

      Tx.announce(tx, @ambient_topic, {:ambient_changed})
    else
      _invalid_quiet_or_known -> :ok
    end
  end

  defp item_fields(%{key: key, kind: kind} = item)
       when is_binary(key) and key != "" and kind in @item_kinds do
    fields = Map.new(@item_fields, &{&1, text(Map.get(item, &1))})

    Map.merge(fields, %{
      key: key,
      kind: kind,
      note: note(Map.get(item, :note)),
      inserted_at: DateTime.utc_now()
    })
  end

  defp item_fields(_item), do: nil

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp note(value) when is_binary(value) and value != "", do: String.slice(value, 0, @note_limit)
  defp note(_value), do: nil

  @doc "The digest items waiting, oldest first, inside the caller's commit."
  @spec pending_tx(Tx.t()) :: [DigestItem.t()]
  def pending_tx(%Tx{}), do: pending()

  @doc "The digest items waiting, oldest first."
  @spec pending() :: [DigestItem.t()]
  def pending, do: DigestItem |> order_by([i], asc: i.inserted_at, asc: i.id) |> Repo.all()

  @doc """
  Deletes digest items inside the caller's commit: those with the given
  IDs, or every one (`:all`).
  """
  @spec drop_items_tx(Tx.t(), [String.t()] | :all) :: :ok
  def drop_items_tx(%Tx{}, :all) do
    {_count, _rows} = Repo.delete_all(DigestItem)
    :ok
  end

  def drop_items_tx(%Tx{}, []), do: :ok

  def drop_items_tx(%Tx{}, ids) when is_list(ids) do
    {_count, _rows} = DigestItem |> where([i], i.id in ^ids) |> Repo.delete_all()
    :ok
  end

  @doc """
  Whether a digest or review message (`kind`, `"digest"` or `"review"`)
  still waits, queued, in Blip's inbox.
  """
  @spec queued_ambient?(Tx.t(), String.t()) :: boolean()
  def queued_ambient?(tx, kind),
    do: tx |> queued_ambient() |> Enum.any?(&(Rules.ambient_kind(source(&1)) == kind))

  @doc """
  Withdraws every digest and review message still queued in Blip's inbox,
  inside the caller's commit, and returns their refs. One already placed
  is Blip's run in progress, and stays.
  """
  @spec withdraw_ambient_tx(Tx.t()) :: [Rules.ref()]
  def withdraw_ambient_tx(tx) do
    Enum.flat_map(queued_ambient(tx), fn carrier ->
      :ok = unpost_carrier_tx(tx, carrier, :withdraw)
      %{"signals" => refs} = source(carrier)
      refs
    end)
  end

  # Blip's queued digest and review messages; none before Blip's
  # conversation exists.
  defp queued_ambient(tx) do
    case Tx.get_doc(tx, "global", "assistant") do
      %{"conversation_id" => blip} ->
        tx |> Tx.queued(blip) |> Enum.filter(&(Rules.ambient_kind(source(&1)) != nil))

      _no_blip ->
        []
    end
  end

  ## Signals

  @doc "Blip's conversation, created on first use."
  @spec blip_conversation_id() :: String.t()
  def blip_conversation_id do
    case Durable.doc("global", "assistant") do
      %{"conversation_id" => id} -> id
      _none -> Durable.commit(&blip_conversation_tx/1)
    end
  end

  @doc """
  `blip_conversation_id/0` inside the caller's commit, so two first uses
  still make one conversation.
  """
  @spec blip_conversation_tx(Tx.t()) :: String.t()
  def blip_conversation_tx(tx) do
    case Tx.get_doc(tx, "global", "assistant") do
      %{"conversation_id" => id} ->
        id

      _none ->
        conversation = Tx.create_conversation(tx, %{profile: "assistant", title: "Assistant"})
        _doc = Tx.put_doc(tx, "global", "assistant", %{"conversation_id" => conversation.id})
        conversation.id
    end
  end

  @doc """
  Posts `signal` into Blip's conversation, inside the caller's commit, and
  returns the submission that carries it:

    1. a signal already posted under its key, as its own message or in a
       queued one, makes nothing
    2. a queued signal message whose refs are all of this ref's kind
       takes it, as one more text part and ref
    3. otherwise it is a message of its own, which starts a run when Blip
       is idle and waits as a follow-up when Blip is busy

  A signal's `older` stub goes in the source of the message it starts,
  next to `"signals"`; a signal that joins a queued message adds none.
  Only digests and reviews carry one, and `Photon.Signals.Rules.merges?/2`
  keeps them out of messages of other kinds.
  """
  @spec post_tx(Tx.t(), t()) :: Submission.t()
  def post_tx(tx, %{key: key, text: text, ref: ref} = signal) do
    blip = blip_conversation_tx(tx)
    request_id = "signal:" <> key

    with nil <- Tx.find_submission(tx, blip, request_id),
         queued = Tx.queued(tx, blip),
         nil <- Enum.find(queued, &Rules.carries?(source(&1), key)) do
      case Enum.find(queued, &Rules.merges?(source(&1), ref)) do
        nil -> submit_tx(tx, blip, signal, request_id)
        carrier -> merge_tx(tx, carrier, text, ref)
      end
    end
  end

  defp submit_tx(tx, blip, %{text: text, ref: ref} = signal, request_id) do
    source =
      case signal do
        %{older: %{} = older} -> %{"kind" => "signal", "signals" => [ref], "older" => older}
        _no_stub -> %{"kind" => "signal", "signals" => [ref]}
      end

    Durable.submit_tx(tx, blip, text, source: source, request_id: request_id)
  end

  defp merge_tx(tx, carrier, text, ref) do
    content = Rules.merge(carrier.content, Message.text(text), ref)
    Tx.update_submission(tx, carrier, content: content)
  end

  defp unpost_carrier_tx(tx, carrier, :withdraw) do
    _withdrawn = Tx.update_submission(tx, carrier, status: "withdrawn")
    :ok
  end

  defp unpost_carrier_tx(tx, carrier, {:keep, content}) do
    _kept = Tx.update_submission(tx, carrier, content: content)
    :ok
  end

  defp unpost_carrier_tx(_tx, _carrier, :absent), do: :ok

  @doc """
  Takes back the signal with `key` while it is still queued: withdraws the
  message when the signal is all it carries, or drops the signal's part
  and ref from a message that carries others. Once the message has been
  placed, Blip has seen it, and nothing changes.
  """
  @spec unpost_tx(Tx.t(), String.t()) :: :ok
  def unpost_tx(tx, key) do
    with %{"conversation_id" => blip} <- Tx.get_doc(tx, "global", "assistant"),
         %Submission{} = carrier <-
           tx |> Tx.queued(blip) |> Enum.find(&Rules.carries?(source(&1), key)) do
      unpost_carrier_tx(tx, carrier, Rules.without(carrier.content, key))
    else
      _no_blip_or_not_queued -> :ok
    end
  end

  @doc """
  The owner's answer to `question`, as a message in Blip's conversation,
  inside the caller's commit (section 4.5): a note that the answer has
  already gone straight to the thread, then the answer as the owner
  wrote it. Its source (`"answer"`) names the question and the thread, so
  the panel can show what it answered. Like any message it starts a run
  when Blip is idle and waits as a follow-up when Blip is busy; Blip's
  Stop keeps it. One per question (its request ID).
  """
  @spec answer_tx(Tx.t(), question(), String.t()) :: Submission.t()
  def answer_tx(tx, question, text) do
    ref = question_ref(question)

    Durable.submit_tx(
      tx,
      blip_conversation_tx(tx),
      [Message.text(Text.answer_note(ref)), Message.text(text)],
      source: %{
        "kind" => "answer",
        "question_id" => question.id,
        "thread_id" => question.thread_id,
        "title" => question.thread_title,
        "slug" => question.project_slug,
        "project" => question.project_name
      },
      request_id: "answer:" <> question.id
    )
  end

  @doc """
  A notice about `question` in Blip's conversation, inside the caller's
  commit: `:escalated` when the hub passed a question Blip didn't get to
  on to the owner, `:withdrawn` when the thread was stopped while its
  question was with the owner. A notice is for the owner to read; the
  model never sees it. It runs on the harness's abort path, so it never
  raises.

  Its data says which notice it is (`"question_notice"`: `"escalated"` or
  `"withdrawn"`) and where the thread is (`"thread_id"`, `"title"`,
  `"slug"`, `"project"`), and an escalation carries the thread's own
  question (`"question"`): Blip's panel draws an escalation as the
  question's card, which the owner answers from.
  """
  @spec notice_tx(Tx.t(), question(), :escalated | :withdrawn) :: :ok
  def notice_tx(tx, question, kind) do
    ref = question_ref(question)
    text = if kind == :escalated, do: Text.escalated(ref), else: Text.withdrawn(ref)

    _entry = Tx.append(tx, blip_conversation_tx(tx), "error", notice_data(question, kind, text))
    :ok
  end

  # What the panel draws the notice from: which notice it is and where its
  # thread is, and for an escalation the thread's own question, since the
  # owner answers that one from the panel's card.
  defp notice_data(question, kind, text) do
    data = %{
      "message" => text,
      "notice" => true,
      "question_id" => question.id,
      "question_notice" => Atom.to_string(kind),
      "thread_id" => question.thread_id,
      "title" => question.thread_title,
      "slug" => question.project_slug,
      "project" => question.project_name
    }

    case {kind, Map.get(question, :question)} do
      {:escalated, text} when is_binary(text) -> Map.put(data, "question", text)
      _withdrawn_or_none -> data
    end
  end

  defp question_ref(question) do
    Rules.question_ref(question.id, Rules.key({:question, question.id}), %{
      thread_id: question.thread_id,
      title: question.thread_title,
      project_id: question.project_id,
      slug: question.project_slug,
      project: question.project_name
    })
  end

  defp source(%Submission{content: %{"source" => source}}), do: source
  defp source(_submission), do: nil
end
