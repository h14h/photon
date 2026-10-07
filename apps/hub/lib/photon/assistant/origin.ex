defmodule Photon.Assistant.Origin do
  @moduledoc """
  Who asked for one of Blip's runs, and what that lets the run do
  (section 5.4 of `docs/plans/step-4-blip-as-coordinator.md`), as pure
  functions over the `source` maps of the submissions the run answers.

  `of/1` names who asked (`by`, and the schedule or thread it was for),
  whether the owner typed into the run (`owner_wrote?`), the `ask_blip`
  questions it carries, and whether it is `restricted?`: a run that
  carries a thread's question and that the owner hasn't typed into can't
  start, wake, stop or schedule threads, or change a project, because a
  thread can't start work (the owner's rule), and a question is a thread
  talking to Blip. An `"answer"` source (the owner's answer to a
  question, already sent to the thread) counts as the owner asking but
  doesn't lift the limits.

  A thread update leads to Blip's follow-up, never to "a thread asked":
  Blip acts on an update only to carry out what the owner asked earlier.
  Only a question is a thread asking, and `for_call/3` credits each call
  that handles one to the thread whose question it is.

  `unattended_ok?/3` bounds what Blip starts on its own: between two of
  the owner's messages, Blip can start or message threads at most the
  limit's number of times in runs the owner didn't type into, so a loop
  between Blip and a thread stops in code (section 3.7).

  These run on the harness's hook paths too (the activity log, C12), so
  they are total: any term in, a value out.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Message

  @typedoc "Who asked for a run: the owner, a schedule, Blip's follow-up, a thread, or unknown."
  @type by :: String.t()

  @typedoc "An `ask_blip` question a run carries: its ID and the thread that asked."
  @type question :: %{question_id: String.t(), thread_id: String.t() | nil}

  @typedoc """
  Who asked for a run (`by`, and `id`, the schedule or the one thread it
  was for), whether the owner typed into it, the questions it carries,
  and whether the limits on a thread's question hold in it.
  """
  @type t :: %{
          by: by(),
          id: String.t() | nil,
          owner_wrote?: boolean(),
          questions: [question()],
          restricted?: boolean()
        }

  # The tools whose calls handle one question, credited to its thread.
  @question_tools ~w(answer_question ask_owner)

  @doc """
  Who asked for a run, from the `source` maps of the submissions it
  answers. `by` and `id` come from the first of these that holds:

    * a `"user"` or `"answer"` source: `"owner"`
    * a `"routine"` source with `"asked_by" => "blip"`: `"follow_up"`,
      with the schedule
    * any other `"routine"` source: `"schedule"`, with the schedule
    * a `"signal"` source with question refs: `"thread"`, with the
      asking thread when every question is from one thread
    * a `"signal"` source with update refs only: `"follow_up"`, with the
      thread the updates are about when there is one
    * otherwise `"unknown"`
  """
  @spec of(term()) :: t()
  def of(sources) do
    sources = if is_list(sources), do: Enum.filter(sources, &is_map/1), else: []
    refs = Enum.flat_map(sources, &refs/1)
    questions = for %{"kind" => "question"} = ref <- refs, do: question(ref)
    updates = for %{"kind" => "thread_update"} = ref <- refs, do: ref["thread_id"]
    owner_wrote? = Enum.any?(sources, &(kind(&1) == "user"))
    {by, id} = by(sources, questions, updates)

    %{
      by: by,
      id: id,
      owner_wrote?: owner_wrote?,
      questions: questions,
      restricted?: questions != [] and not owner_wrote?
    }
  end

  defp by(sources, questions, updates) do
    routine = Enum.find(sources, &(kind(&1) == "routine"))

    cond do
      Enum.any?(sources, &(kind(&1) in ["user", "answer"])) -> {"owner", nil}
      routine && routine["asked_by"] == "blip" -> {"follow_up", text(routine["schedule_id"])}
      routine -> {"schedule", text(routine["schedule_id"])}
      questions != [] -> {"thread", one(Enum.map(questions, & &1.thread_id))}
      updates != [] -> {"follow_up", one(updates)}
      true -> {"unknown", nil}
    end
  end

  defp kind(%{"kind" => kind}), do: kind
  defp kind(_source), do: nil

  defp refs(%{"kind" => "signal", "signals" => refs}) when is_list(refs),
    do: Enum.filter(refs, &is_map/1)

  defp refs(_source), do: []

  defp question(ref),
    do: %{question_id: text(ref["question_id"]), thread_id: text(ref["thread_id"])}

  # The one thread all of `ids` name, or nil when they name none or several.
  defp one(ids) do
    case ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [id] -> id
      _none_or_several -> nil
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  @doc """
  Who asked for one tool call in a run of `origin`, for the activity log:
  an `answer_question` or `ask_owner` call whose `question_id` is one of
  the run's questions is the thread that asked it; any other call, or one
  whose arguments (raw: a map or the model's JSON) have no usable
  `question_id`, is the run's `by` and `id`.
  """
  @spec for_call(t(), term(), term()) :: %{by: by(), id: String.t() | nil}
  def for_call(%{by: by, id: id} = origin, name, args) when name in @question_tools do
    with {:ok, %{"question_id" => qid}} when is_binary(qid) <- arguments(args),
         %{thread_id: thread_id} <- Enum.find(questions(origin), &(&1.question_id == qid)) do
      %{by: "thread", id: thread_id}
    else
      _other -> %{by: by, id: id}
    end
  end

  def for_call(%{by: by, id: id}, _name, _args), do: %{by: by, id: id}
  def for_call(_origin, _name, _args), do: %{by: "unknown", id: nil}

  defp questions(%{questions: questions}) when is_list(questions), do: questions
  defp questions(_origin), do: []

  defp arguments(args) when is_map(args) or is_binary(args),
    do: Message.arguments(%{"arguments" => args})

  defp arguments(_args), do: :error

  @doc """
  Whether Blip may start or message one more thread in a run of
  `origin`, having done so `count` times since the owner last wrote to
  it, with at most `limit` allowed: always in a run the owner typed
  into, else only below the limit.
  """
  @spec unattended_ok?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def unattended_ok?(%{owner_wrote?: true}, _count, _limit), do: true
  def unattended_ok?(_origin, count, limit), do: count < limit

  @doc "What a tool says when a thread's question limits the run (`restricted?`)."
  @spec restricted_message() :: String.t()
  def restricted_message,
    do:
      "A thread's question can't start or change work. " <>
        "Answer it with answer_question, or ask the user with ask_owner."

  @doc "What `start_thread` and `message_thread` say at the unattended limit."
  @spec unattended_message(non_neg_integer()) :: String.t()
  def unattended_message(limit),
    do:
      "You've started or messaged threads #{limit} times since the user last wrote to you. " <>
        "Tell them what's going on and wait for them."
end
