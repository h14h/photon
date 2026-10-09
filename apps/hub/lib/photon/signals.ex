defmodule Photon.Signals do
  @moduledoc """
  What reaches Blip unasked: thread updates and `ask_blip` questions,
  posted into Blip's conversation as `"signal"` messages; the owner's
  answers to questions, which have already gone to the thread; and
  notices for the owner when a question is passed on or withdrawn. It
  owns finding Blip's conversation because `Photon.Threads` and
  `Photon.Questions` post into it and can't depend on `Photon.Assistant`,
  which depends on them.

  Which settles become signals is decided in code, never by a model
  (`Photon.Signals.Rules.thread_update/2`). While Blip is busy, signals
  of one kind collect in one queued message (`Photon.Signals.Rules`), so
  a burst wakes the model once per kind. A signal's key makes it once,
  whether it started a message or joined one.

  ## Ambient mode

  Ambient mode, off by default, is the durable doc `global/ambient`. It is
  read and written here because the threads' settle hook reads it inside
  its commit and can't depend on `Photon.Ambient`, which depends on
  `Photon.Threads`. What the doc holds is `Photon.Ambient`'s; here only
  `"on"` is read.

  While it is on, changes Blip doesn't hear about at once are collected
  as digest items, one row per subject
  (`Photon.Signals.Rules.item_key/1`): a newer change to the same subject
  replaces the row, so the table holds at most one row per thread,
  schedule, project or file however long digests skip (rule 73). A digest
  marks the items it carries in the commit that posts it; when Blip's run
  on it settles they are deleted, or wait again if the run failed. Every
  write announces `{:ambient_changed}` on `ambient_topic/0`.

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

  @item_fields [:thread_id, :project_id, :schedule_id, :task_id, :name, :writer]

  # What a newer change to the same subject replaces: everything but the
  # row's ID and key.
  @replaced [
    :kind,
    :thread_id,
    :project_id,
    :schedule_id,
    :task_id,
    :name,
    :writer,
    :note,
    :digest_key,
    :inserted_at
  ]

  @note_limit 600

  @typedoc """
  A signal: its `key` (`Photon.Signals.Rules.key/1`), the `text` the model
  reads, and the `ref` the panel draws it from. A digest or review also
  carries `older` (`Photon.Durable.Context`).
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

  @typedoc "An `ask_blip` question, as `Photon.Questions.Question` holds it."
  @type question :: %{
          required(:id) => String.t(),
          required(:thread_id) => String.t(),
          required(:thread_title) => String.t(),
          required(:project_id) => String.t(),
          required(:project_slug) => String.t(),
          required(:project_name) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "A digest item to collect: its `kind`, and what it names; missing fields are nil."
  @type item :: %{
          required(:kind) => String.t(),
          optional(:thread_id) => String.t() | nil,
          optional(:project_id) => String.t() | nil,
          optional(:schedule_id) => String.t() | nil,
          optional(:task_id) => String.t() | nil,
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
  Collects `item` for the next digest, inside the caller's commit, and
  announces `{:ambient_changed}`, while ambient mode is on (read in this
  commit, so turning it off stops collection from the next); does nothing
  otherwise. A row already there for the same subject, waiting or carried
  by a digest Blip is still reading, is replaced and waits for the next
  digest. It runs on the harness's hook paths (the settle hook in the
  Scheduler's abort and fail commits, a routine's `on_fail/3`), so it is
  total: a missing or non-text field is nil, a note over 600 characters
  is cut, an unknown kind or a missing subject collects nothing, and it
  never raises.
  """
  @spec collect_tx(Tx.t(), item() | term()) :: :ok
  def collect_tx(tx, item) do
    with %{key: _key} = fields <- item_fields(item),
         :ambient <- mode_tx(tx) do
      # Repo.insert!/2 raises on a failed write, which rolls the commit
      # back; a row with the same subject is replaced, not doubled.
      _item =
        DigestItem
        |> struct!(Map.put(fields, :id, PhotonCore.ID.new("di_")))
        |> Repo.insert!(on_conflict: {:replace, @replaced}, conflict_target: [:key])

      Tx.announce(tx, @ambient_topic, {:ambient_changed})
    else
      _invalid_or_quiet -> :ok
    end
  end

  defp item_fields(%{kind: kind} = item) when kind in @item_kinds do
    fields = @item_fields |> Map.new(&{&1, text(Map.get(item, &1))}) |> Map.put(:kind, kind)

    case Rules.item_key(fields) do
      nil ->
        nil

      key ->
        Map.merge(fields, %{
          key: key,
          note: note(Map.get(item, :note)),
          digest_key: nil,
          inserted_at: DateTime.utc_now()
        })
    end
  end

  defp item_fields(_item), do: nil

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp note(value) when is_binary(value) and value != "", do: String.slice(value, 0, @note_limit)
  defp note(_value), do: nil

  @doc "`pending/0` inside the caller's commit."
  @spec pending_tx(Tx.t()) :: [DigestItem.t()]
  def pending_tx(%Tx{}), do: pending()

  @doc "The digest items waiting (not those a posted digest carries), oldest first."
  @spec pending() :: [DigestItem.t()]
  def pending do
    DigestItem
    |> where([i], is_nil(i.digest_key))
    |> order_by([i], asc: i.inserted_at, asc: i.id)
    |> Repo.all()
  end

  @doc """
  Deletes digest items inside the caller's commit: those with the given
  IDs, or every one (`:all`), carried or not.
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
  Marks the items with the given IDs as carried by the digest with key
  `digest_key`, inside the commit that posts it: they no longer wait,
  and go when Blip's run on that digest settles.
  """
  @spec carry_items_tx(Tx.t(), [String.t()], String.t()) :: :ok
  def carry_items_tx(%Tx{}, [], _digest_key), do: :ok

  def carry_items_tx(%Tx{}, ids, digest_key) when is_list(ids) and is_binary(digest_key) do
    query = where(DigestItem, [i], i.id in ^ids)
    {_count, _rows} = Repo.update_all(query, set: [digest_key: digest_key])
    :ok
  end

  @doc "Deletes the items the digest `digest_key` carries, inside the caller's commit."
  @spec drop_carried_tx(Tx.t(), String.t()) :: :ok
  def drop_carried_tx(%Tx{}, digest_key) when is_binary(digest_key) do
    {_count, _rows} = DigestItem |> where([i], i.digest_key == ^digest_key) |> Repo.delete_all()
    :ok
  end

  @doc """
  Puts the items the digest with key `digest_key` carries back to wait,
  inside the commit that settles Blip's run on it without an answer (Blip
  never told the owner), and announces `{:ambient_changed}` if there were
  any.
  """
  @spec release_items_tx(Tx.t(), String.t()) :: :ok
  def release_items_tx(tx, digest_key) when is_binary(digest_key) do
    query = where(DigestItem, [i], i.digest_key == ^digest_key)

    case Repo.update_all(query, set: [digest_key: nil]) do
      {0, _rows} -> :ok
      {_count, _rows} -> Tx.announce(tx, @ambient_topic, {:ambient_changed})
    end
  end

  @doc ~s{Whether a `"digest"` or `"review"` message (`kind`) still waits in Blip's inbox.}
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

  @doc "`blip_conversation_id/0` in the caller's commit: two first uses make one conversation."
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

  A signal's `older` stub goes in the source of the message it starts; a
  signal that joins a queued message adds none. Only digests and reviews
  carry one, and they never join messages of other kinds.
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
  inside the caller's commit: a note that the answer has already gone
  straight to the thread, then the answer as the owner wrote it. Its
  source (`"answer"`) names the question and the thread for the panel.
  Blip's Stop keeps it. One per question (its request ID).
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
  raises. An escalation carries the thread's own question, since the
  panel draws it as the card the owner answers from.
  """
  @spec notice_tx(Tx.t(), question(), :escalated | :withdrawn) :: :ok
  def notice_tx(tx, question, kind) do
    ref = question_ref(question)
    text = if kind == :escalated, do: Text.escalated(ref), else: Text.withdrawn(ref)

    _entry = Tx.append(tx, blip_conversation_tx(tx), "error", notice_data(question, kind, text))
    :ok
  end

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
