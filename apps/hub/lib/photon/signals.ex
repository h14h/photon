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
  `Photon.Signals.Text`. Quiet mode is the only mode for now: Blip hears
  about work it started, and about failures and questions in the owner's
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

  ## Room for ambient mode

  Step 5's ambient mode adds a mode to `Photon.Signals.Rules.thread_update/2`
  (Blip hears about the owner's finished threads too, collected into a
  digest). `mode/0` is the one place the setting will be read; every
  decision already takes the mode as an argument.

  There is no process here: signals are submissions in Blip's
  conversation, and the harness runs them.
  """

  use Boundary, deps: [Photon.Durable, PhotonCore], exports: [Rules, Text]

  alias Photon.Durable
  alias Photon.Durable.{Submission, Tx}
  alias Photon.Signals.{Rules, Text}
  alias PhotonCore.Message

  @typedoc """
  A signal: its `key` (`Photon.Signals.Rules.key/1`), the `text` the model
  reads (`Photon.Signals.Text`), and the `ref` the panel draws it from.
  """
  @type t :: %{key: String.t(), text: String.t(), ref: Rules.ref()}

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

  @doc "Which signals reach Blip. Quiet mode is the only mode until step 5 adds the setting."
  @spec mode() :: Rules.mode()
  def mode, do: :quiet

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
  """
  @spec post_tx(Tx.t(), t()) :: Submission.t()
  def post_tx(tx, %{key: key, text: text, ref: ref}) do
    blip = blip_conversation_tx(tx)
    request_id = "signal:" <> key

    with nil <- Tx.find_submission(tx, blip, request_id),
         queued = Tx.queued(tx, blip),
         nil <- Enum.find(queued, &Rules.carries?(source(&1), key)) do
      case Enum.find(queued, &Rules.merges?(source(&1), ref)) do
        nil -> submit_tx(tx, blip, text, ref, request_id)
        carrier -> merge_tx(tx, carrier, text, ref)
      end
    end
  end

  defp submit_tx(tx, blip, text, ref, request_id) do
    Durable.submit_tx(tx, blip, text,
      source: %{"kind" => "signal", "signals" => [ref]},
      request_id: request_id
    )
  end

  defp merge_tx(tx, carrier, text, ref) do
    content = Rules.merge(carrier.content, Message.text(text), ref)
    Tx.update_submission(tx, carrier, content: content)
  end

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
      case Rules.without(carrier.content, key) do
        :withdraw -> _withdrawn = Tx.update_submission(tx, carrier, status: "withdrawn")
        {:keep, content} -> _kept = Tx.update_submission(tx, carrier, content: content)
        :absent -> :ok
      end

      :ok
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
