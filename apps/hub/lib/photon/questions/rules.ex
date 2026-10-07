defmodule Photon.Questions.Rules do
  @moduledoc """
  The rules of an `ask_blip` question (section 4.2 of
  `docs/plans/step-4-blip-as-coordinator.md`), as pure functions.

    * `question/1` and `answer/1` check what a thread asks and what an
      answer says
    * `step/2` is the question's transitions: Blip answers it or passes
      it to the owner, the hub passes on one Blip didn't get to, the owner
      answers one that is with them, and a stopped call withdraws it.
      Blip's answer to a question that is with the owner counts only when
      the owner wrote to Blip in the run making it (`{:blip, true}`), and
      is then recorded as the owner's: otherwise a guess of Blip's could
      pass as the owner's decision
    * `message/3` says why a step was refused, in one set of words for
      Blip (naming the question by ID, as its tools do) and one for the
      owner (naming the thread by title, with no ID)
    * `askable?/1` is the fence the ask commit checks itself: a question
      is only made for a tool call that is still running and not being
      stopped
    * `escalate?/2` says when the hub passes a question to the owner:
      Blip's run has been through the message carrying it and the
      question is still Blip's
    * `result/1` is what the thread's call gets back once it is answered

  Everything here is total: `Photon.Questions.withdraw_tx/2` runs inside
  the harness's abort and fail commits.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @question_limit 2_000
  @answer_limit 4_000

  # Durable task statuses that are not yet terminal (`Photon.Durable.TaskRecord`).
  @unfinished_tasks ~w(pending running waiting)

  # Carrier statuses after which Blip's run can no longer handle the question.
  @carrier_closed ~w(done unanswered withdrawn)

  @open ~w(asked with_owner)

  @typedoc "Where a question is."
  @type status :: String.t()

  @typedoc """
  Something that happens to a question: an answer (by the owner, or by
  Blip, with whether the owner wrote to Blip in that run), a pass to the
  owner (by Blip's `ask_owner`, or by the hub), or a withdraw.
  """
  @type event ::
          {:answer, :owner | {:blip, boolean()}}
          | {:pass, :blip | :hub}
          | :withdraw

  @typedoc "Why a step was refused."
  @type reason :: :with_owner | :already_passed | :with_blip | :answered | :withdrawn | :invalid

  @typedoc "Who reads a refusal: Blip, or the owner."
  @type audience :: :blip | :owner

  @doc """
  A thread's question, trimmed: required, and at most
  #{@question_limit} characters. Blip's wording for the owner
  (`ask_owner`) follows the same rule.
  """
  @spec question(term()) :: {:ok, String.t()} | {:error, String.t()}
  def question(text) do
    checked(
      text,
      @question_limit,
      "Ask one specific question.",
      "Keep the question under 2,000 characters; put background in a context file and say which."
    )
  end

  @doc "An answer, trimmed: required, and at most #{@answer_limit} characters."
  @spec answer(term()) :: {:ok, String.t()} | {:error, String.t()}
  def answer(text) do
    checked(text, @answer_limit, "Write an answer.", "Keep the answer under 4,000 characters.")
  end

  defp checked(text, limit, blank, long) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, blank}
      text -> if String.length(text) <= limit, do: {:ok, text}, else: {:error, long}
    end
  end

  defp checked(_text, _limit, blank, _long), do: {:error, blank}

  @doc ~s{Whether a question with `status` is open: `"asked"` or `"with_owner"`.}
  @spec open?(term()) :: boolean()
  def open?(status), do: status in @open

  @doc "The open statuses, for queries."
  @spec open_statuses() :: [status()]
  def open_statuses, do: @open

  @doc """
  A question's transition on `event` from `status`: `{:ok, new_status,
  answered_by}` (`answered_by` is nil unless the event answers it), or
  `{:error, reason}`. A withdraw leaves an answered question as it is.
  """
  @spec step(term(), term()) :: {:ok, status(), String.t() | nil} | {:error, reason()}
  def step("asked", {:answer, {:blip, _owner_wrote?}}), do: {:ok, "answered", "blip"}
  def step("asked", {:pass, by}) when by in [:blip, :hub], do: {:ok, "with_owner", nil}
  def step("asked", {:answer, :owner}), do: {:error, :with_blip}
  def step("with_owner", {:answer, :owner}), do: {:ok, "answered", "owner"}
  def step("with_owner", {:answer, {:blip, true}}), do: {:ok, "answered", "owner"}
  def step("with_owner", {:answer, {:blip, false}}), do: {:error, :with_owner}
  def step("with_owner", {:pass, _by}), do: {:error, :already_passed}
  def step(status, :withdraw) when status in @open, do: {:ok, "withdrawn", nil}
  def step("answered", :withdraw), do: {:ok, "answered", nil}
  def step("answered", _event), do: {:error, :answered}
  def step("withdrawn", _event), do: {:error, :withdrawn}
  def step(_status, _event), do: {:error, :invalid}

  @doc """
  Why a step was refused, for `audience`, about `question` (with its `id`
  and `thread_title`). Blip's words name the question by ID; the owner's
  name the thread by title and never show an ID. `:not_found` is for a
  question that doesn't exist.
  """
  @spec message(reason() | :not_found, audience(), map() | nil) :: String.t()
  def message(reason, :owner, question), do: owner(reason, title(question))
  def message(reason, _blip, question), do: blip(reason, id(question))

  defp blip(:with_owner, id),
    do: "#{id} is with the user. Wait for their answer; it goes to the thread without you."

  defp blip(:already_passed, id), do: "You already asked the user about #{id}."

  defp blip(:with_blip, id),
    do: "#{id} is yours to answer: use answer_question, or ask the user with ask_owner."

  defp blip(:answered, id), do: "#{id} was already answered."
  defp blip(:withdrawn, id), do: "#{id} was withdrawn: its thread was stopped."
  defp blip(:not_found, id), do: "There's no open question #{id}."
  defp blip(_reason, id), do: "#{id} can't take that now."

  defp owner(:with_owner, title), do: "#{title}'s question is waiting for your answer."
  defp owner(:already_passed, title), do: "#{title}'s question is already with you."

  defp owner(:with_blip, title),
    do: "Blip has #{title}'s question; it'll ask you if it needs to."

  defp owner(:answered, title), do: "#{title}'s question was already answered."
  defp owner(:withdrawn, title), do: "#{title} was stopped, so its question was withdrawn."
  defp owner(:not_found, _title), do: "That question isn't there any more."
  defp owner(_reason, title), do: "#{title}'s question can't take an answer now."

  defp id(%{id: id}) when is_binary(id), do: id
  defp id(_question), do: "That question"

  defp title(%{thread_title: title}) when is_binary(title), do: ~s{"#{title}"}
  defp title(_question), do: "The thread"

  @doc """
  Whether the ask commit may make a question for this tool task (nil when
  there is none): only while it is unfinished and not marked for abort.
  The ask commits outside the step's fence, so it checks the fence's facts
  itself, as `Photon.Machines.start/1` does for an op.
  """
  @spec askable?(term()) :: boolean()
  def askable?(%{status: status, abort_requested: abort?}),
    do: status in @unfinished_tasks and abort? != true

  def askable?(_task), do: false

  @doc """
  Whether the hub passes `question` to the owner: it is still `"asked"`,
  and its carrier (the message in Blip's conversation) has settled, been
  withdrawn, or is gone, so no run of Blip's will see it again.
  """
  @spec escalate?(term(), term()) :: boolean()
  def escalate?(%{status: "asked"}, nil), do: true
  def escalate?(%{status: "asked"}, %{status: status}), do: status in @carrier_closed
  def escalate?(_question, _carrier), do: false

  @doc """
  What the thread's `ask_blip` call returns once its question is
  answered. An owner's answer comes with how Blip put the question to
  them, when Blip did, so a short answer reads against the question the
  owner actually saw.
  """
  @spec result(map()) :: String.t()
  def result(%{answered_by: "blip"} = question), do: "Blip answered: " <> answer_text(question)

  def result(%{wording: wording} = question) when is_binary(wording) and wording != "",
    do: "Blip asked the user: #{wording}\nThey answered: #{answer_text(question)}"

  def result(question), do: "The user answered: " <> answer_text(question)

  defp answer_text(%{answer: answer}) when is_binary(answer), do: answer
  defp answer_text(_question), do: ""
end
