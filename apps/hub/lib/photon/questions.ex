defmodule Photon.Questions do
  @moduledoc """
  `ask_blip` questions: a thread asks Blip one specific question and its
  tool call waits, durably, for the answer.

  A question is a row (`Photon.Questions.Question`), one per tool call,
  posted to Blip as a signal. Blip answers it from what it knows, or
  passes it to the owner in its own words. The owner's answer goes
  straight to the thread, by code; Blip also gets it as a message of its
  own (`Photon.Signals.answer_tx/3`) so it can remember what it learned.

  ## The fenced ask

  `ask/1` commits outside the tool step's own fenced commit, so it checks
  the fence's facts itself (hub rule 9, as `Photon.Machines.start/1`
  does; `Photon.Questions.Rules.askable?/1`). Otherwise a Stop landing
  between the step's start and the ask would leave a question open with
  no call waiting for it. A rerun of the step finds the question by its
  task and makes nothing new.

  ## The relay

  Every answer records the signal `signal_key/1` in its commit, which
  wakes the parked call; the call reads the answered row and returns
  `Photon.Questions.Rules.result/1`. Blip, the owner and the call's
  withdraw race on one row, and each change is one commit that applies
  `Photon.Questions.Rules.step/2` to the row as it is then, so a question
  is answered at most once and never after it was withdrawn.

  ## Escalation

  If Blip's run goes past the question without answering or passing it,
  the waiting call, checking every `check_ms/0`, has the hub pass it to
  the owner (`escalate/1`). When the call ends first (a Stop, a failed
  task), the question is withdrawn in the commit that ends it
  (`withdraw_tx/2`).

  Every change announces `{:questions_changed, thread_id}` after its
  commit (`subscribe/0`).

  There is no process here: the question is a row, the wait is the
  thread's tool task, and the answer is a durable signal, so a hub
  restart loses nothing.
  """

  use Boundary,
    deps: [Photon.Durable, Photon.Events, Photon.Repo, Photon.Signals, PhotonCore, Ecto],
    exports: [Question, Rules]

  import Ecto.Query

  alias Photon.{Durable, Events, Repo, Signals}
  alias Photon.Durable.Tx
  alias Photon.Questions.{Question, Rules}
  alias Photon.Signals.Rules, as: SignalRules
  alias Photon.Signals.Text, as: SignalText

  @topic "questions"

  @check_ms 60_000

  @typedoc """
  A new question: the `ask_blip` call's tool task, the thread and where
  it is (as the signal names it), and the question, already checked with
  `Photon.Questions.Rules.question/1`.
  """
  @type new :: %{
          task_id: String.t(),
          thread_id: String.t(),
          thread_title: String.t(),
          project_id: String.t(),
          project_slug: String.t(),
          project_name: String.t(),
          question: String.t()
        }

  @typedoc "Why a change to a question was refused."
  @type reason :: Rules.reason() | :not_found

  ## Subscriptions and reading

  @doc """
  Subscribes to `{:questions_changed, thread_id}`, sent after a question
  is asked, passed, answered, escalated or withdrawn.
  """
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @doc "The question with ID `id`, or nil."
  @spec get(String.t()) :: Question.t() | nil
  def get(id) when is_binary(id), do: Repo.get(Question, id)
  def get(_id), do: nil

  @doc "The questions with IDs among `ids`, in no particular order. One query."
  @spec get_many([String.t()]) :: [Question.t()]
  def get_many([]), do: []

  def get_many(ids) do
    query = from(q in Question, where: q.id in ^ids)
    Repo.all(query)
  end

  @doc "The question tool task `task_id` asked, or nil."
  @spec by_task(String.t()) :: Question.t() | nil
  def by_task(task_id) when is_binary(task_id), do: Repo.get_by(Question, task_id: task_id)
  def by_task(_task_id), do: nil

  @doc """
  The open questions (asked, or with the owner) of `thread_ids`, by
  thread, each thread's oldest first; a thread with none is left out. One
  query.
  """
  @spec open_by_thread([String.t()]) :: %{optional(String.t()) => [Question.t()]}
  def open_by_thread([]), do: %{}

  def open_by_thread(thread_ids) do
    open_query()
    |> where([q], q.thread_id in ^thread_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.thread_id)
  end

  @doc "Every open question, oldest first."
  @spec open() :: [Question.t()]
  def open, do: Repo.all(open_query())

  defp open_query do
    from(q in Question,
      where: q.status in ^Rules.open_statuses(),
      order_by: [asc: q.inserted_at, asc: q.id]
    )
  end

  @doc "The durable signal that wakes the call waiting on question `id`."
  @spec signal_key(String.t()) :: String.t()
  def signal_key(id), do: "question:" <> id

  @doc "How often, in milliseconds, a waiting call checks whether Blip got to its question."
  @spec check_ms() :: pos_integer()
  def check_ms do
    :photon |> Application.get_env(__MODULE__, []) |> Keyword.get(:check_ms, @check_ms)
  end

  ## Asking

  @doc """
  Stores a thread's question and posts it to Blip, in one commit (see
  "The fenced ask"). A question already stored for the tool task is
  returned as it is; `{:error, :stopped}`, with nothing stored or posted,
  when the tool task has ended or is being stopped.
  """
  @spec ask(new()) :: {:ok, Question.t()} | {:error, :stopped}
  def ask(new), do: Durable.commit(&ask_tx(&1, new))

  defp ask_tx(tx, new) do
    case by_task(new.task_id) do
      %Question{} = question ->
        {:ok, question}

      nil ->
        if Rules.askable?(Tx.get_task(tx, new.task_id)),
          do: {:ok, insert_tx(tx, new)},
          else: {:error, :stopped}
    end
  end

  defp insert_tx(tx, new) do
    question =
      Repo.insert!(%Question{
        id: PhotonCore.ID.new("q_"),
        task_id: new.task_id,
        thread_id: new.thread_id,
        thread_title: new.thread_title,
        project_id: new.project_id,
        project_slug: new.project_slug,
        project_name: new.project_name,
        question: new.question,
        status: "asked"
      })

    carrier = Signals.post_tx(tx, signal(question))
    update_tx(tx, question, submission_id: carrier.id)
  end

  # The question as Blip reads it, with the ref the panel draws it from.
  defp signal(question) do
    key = SignalRules.key({:question, question.id})

    ref =
      SignalRules.question_ref(question.id, key, %{
        thread_id: question.thread_id,
        title: question.thread_title,
        project_id: question.project_id,
        slug: question.project_slug,
        project: question.project_name
      })

    %{key: key, text: SignalText.question(ref, question.question), ref: ref}
  end

  ## Answering and passing on

  @doc """
  The owner's answer to question `id`, in one commit: the thread gets it
  unchanged, and Blip gets it as a message of its own. A refusal, or an
  empty or overlong answer, is returned in the owner's words, which the
  pages show as they are.
  """
  @spec answer(String.t(), String.t()) :: {:ok, Question.t()} | {:error, String.t()}
  def answer(id, text) do
    with {:ok, text} <- Rules.answer(text), do: Durable.commit(&owner_answer_tx(&1, id, text))
  end

  defp owner_answer_tx(tx, id, text) do
    case answer_tx(tx, id, text, :owner) do
      {:ok, question} ->
        # The message is written in this commit; `answer_tx/3` returns no
        # error, only the submission that carries it.
        _message = Signals.answer_tx(tx, question, text)
        {:ok, question}

      {:error, reason} ->
        {:error, Rules.message(reason, :owner, get(id))}
    end
  end

  @doc """
  Answers question `id` inside the caller's commit and records the signal
  that wakes the thread's call. `by` is `:owner`, or `{:blip,
  owner_wrote?}` for Blip's `answer_question` (whether the owner wrote to
  Blip in the run making the call). `text` is already checked with
  `Photon.Questions.Rules.answer/1`.
  """
  @spec answer_tx(Tx.t(), String.t(), String.t(), :owner | {:blip, boolean()}) ::
          {:ok, Question.t()} | {:error, reason()}
  def answer_tx(tx, id, text, by) do
    with %Question{} = question <- get(id),
         {:ok, status, answered_by} <- Rules.step(question.status, {:answer, by}) do
      answered =
        update_tx(tx, question,
          status: status,
          answer: text,
          answered_by: answered_by,
          answered_at: DateTime.utc_now()
        )

      :ok = Tx.signal(tx, signal_key(id), %{})
      {:ok, answered}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Passes question `id` to the owner inside the caller's commit: `by` is
  `:blip` (`ask_owner`, with Blip's `wording`, already checked with
  `Photon.Questions.Rules.question/1`) or `:hub` (no wording, so the owner
  sees the thread's own question).
  """
  @spec pass_tx(Tx.t(), String.t(), String.t() | nil, :blip | :hub) ::
          {:ok, Question.t()} | {:error, reason()}
  def pass_tx(tx, id, wording, by) do
    with %Question{} = question <- get(id),
         {:ok, status, _answered_by} <- Rules.step(question.status, {:pass, by}) do
      {:ok,
       update_tx(tx, question,
         status: status,
         wording: wording,
         passed_by: Atom.to_string(by),
         passed_at: DateTime.utc_now()
       )}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Passes question `id` to the owner when Blip didn't get to it, and leaves
  a notice in Blip's conversation, in one commit; only if
  `Photon.Questions.Rules.escalate?/2` holds for both rows as they are in
  this commit. Returns the question as it is afterwards, passed on or not.
  """
  @spec escalate(String.t()) :: {:ok, Question.t()} | {:error, :not_found}
  def escalate(id), do: Durable.commit(&escalate_tx(&1, id))

  defp escalate_tx(tx, id) do
    with %Question{} = question <- get(id),
         true <- Rules.escalate?(question, carrier(tx, question)),
         {:ok, passed} <- pass_tx(tx, id, nil, :hub) do
      :ok = Signals.notice_tx(tx, passed, :escalated)
      {:ok, passed}
    else
      nil -> {:error, :not_found}
      _not_now -> {:ok, get(id)}
    end
  end

  defp carrier(_tx, %Question{submission_id: nil}), do: nil
  defp carrier(tx, %Question{submission_id: id}), do: Tx.get_submission(tx, id)

  ## Withdrawing

  @doc """
  Withdraws the open question tool task `task_id` asked, inside the
  commit that ends the call: takes its signal back if Blip hasn't seen
  it, and leaves a notice in Blip's conversation if the owner had it. It
  runs inside the harness's abort and fail commits, so it never raises.
  """
  @spec withdraw_tx(Tx.t(), String.t()) :: :ok
  def withdraw_tx(tx, task_id) do
    with %Question{} = question <- by_task(task_id),
         true <- Rules.open?(question.status),
         {:ok, status, _answered_by} <- Rules.step(question.status, :withdraw) do
      # The row is written in this commit; `update_tx/3` raises rather
      # than return an error.
      _withdrawn = update_tx(tx, question, status: status)
      :ok = Signals.unpost_tx(tx, SignalRules.key({:question, question.id}))
      withdrawn_notice_tx(tx, question)
    else
      _closed_or_none -> :ok
    end
  end

  defp withdrawn_notice_tx(tx, %Question{status: "with_owner"} = question),
    do: Signals.notice_tx(tx, question, :withdrawn)

  defp withdrawn_notice_tx(_tx, _question), do: :ok

  defp update_tx(tx, question, changes) do
    updated = Repo.update!(Ecto.Changeset.change(question, changes))
    :ok = Tx.announce(tx, @topic, {:questions_changed, question.thread_id})
    updated
  end
end
