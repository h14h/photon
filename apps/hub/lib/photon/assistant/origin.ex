defmodule Photon.Assistant.Origin do
  @moduledoc """
  Who asked for one of Blip's runs, and what that lets the run do, as pure
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

  `unattended_ok?/3` bounds what Blip starts on its own: between two of the
  owner's messages, Blip can start or message threads at most the limit's
  number of times in runs the owner didn't type into, so a loop between Blip
  and a thread stops in code
  (`docs/decisions.md#what-blip-may-do-on-its-own`). Only those calls count:
  `unattended_details/1` marks them in their results. `schedule_work_ok?/1`
  keeps project schedules, whose firings start threads with no limit, to
  runs the owner typed into.

  A run that only handles threads' questions (`quiet?`: signals carrying
  questions and no updates, nothing the owner or a schedule sent) answers
  to the threads, not the owner: Blip's reply in it makes no bubble and
  no "Told you" row. Its `ask_owner` question still reaches the owner.

  In ambient mode a digest or a daily review reaches Blip as a signal too. A
  run it starts is Blip's follow-up on it (`by: "follow_up"`, `id: "digest"`
  or `"review"`), and it only reports (`report_only?`) until the owner types
  into it: every tool that starts, messages or stops threads, or changes a
  project or a schedule, refuses with `report_only_message/0`. Such a run
  starts nothing, so it can't cause the work that would make the next
  digest.

  These run on the harness's hook paths too (the activity log), so they
  are total: any term in, a value out.
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
  was for, or `"digest"` or `"review"`), whether the owner typed into it,
  the questions it carries, whether the limits on a thread's question
  hold in it, whether it only handles threads' questions (`quiet?`), and
  whether it only reports (`report_only?`: a digest or review run the
  owner hasn't typed into).
  """
  @type t :: %{
          by: by(),
          id: String.t() | nil,
          owner_wrote?: boolean(),
          questions: [question()],
          restricted?: boolean(),
          quiet?: boolean(),
          report_only?: boolean()
        }

  # The tools whose calls handle one question, credited to its thread.
  @question_tools ~w(answer_question ask_owner)

  # The ref kinds of ambient mode's messages to Blip: a digest and a
  # daily review.
  @ambient_kinds ~w(digest review)

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
    * a `"signal"` source with a digest or review ref: `"follow_up"`,
      with `"digest"` or `"review"`
    * otherwise `"unknown"`

  `report_only?` is true when the run carries a digest or review ref and
  the owner didn't type into it; an `"answer"` source doesn't lift it, as
  it doesn't lift `restricted?`.
  """
  @spec of(term()) :: t()
  def of(sources) do
    sources = maps(sources)
    carried = carried(Enum.flat_map(sources, &refs/1))
    owner_wrote? = Enum.any?(sources, &(kind(&1) == "user"))
    {by, id} = by(sources, carried)

    %{
      by: by,
      id: id,
      owner_wrote?: owner_wrote?,
      questions: carried.questions,
      restricted?: carried.questions != [] and not owner_wrote?,
      quiet?: quiet?(by, carried.updates),
      report_only?: carried.ambient != [] and not owner_wrote?
    }
  end

  # What a run's signal refs carry: its questions, the threads its
  # updates are about, and the kinds of its digest or review.
  defp carried(refs) do
    %{
      questions: for(%{"kind" => "question"} = ref <- refs, do: question(ref)),
      updates: for(%{"kind" => "thread_update"} = ref <- refs, do: ref["thread_id"]),
      ambient: for(%{"kind" => kind} when kind in @ambient_kinds <- refs, do: kind)
    }
  end

  defp maps(sources) when is_list(sources), do: Enum.filter(sources, &is_map/1)
  defp maps(_sources), do: []

  # Only questions: no update, and nothing from the owner or a schedule.
  defp quiet?(by, updates), do: by == "thread" and updates == []

  defp by(sources, carried) do
    routine = Enum.find(sources, &(kind(&1) == "routine"))

    cond do
      Enum.any?(sources, &(kind(&1) in ["user", "answer"])) -> {"owner", nil}
      routine && routine["asked_by"] == "blip" -> {"follow_up", text(routine["schedule_id"])}
      routine -> {"schedule", text(routine["schedule_id"])}
      true -> signalled(carried)
    end
  end

  # Who asked for a run that only signals started.
  defp signalled(%{questions: [_ | _] = questions}),
    do: {"thread", one(Enum.map(questions, & &1.thread_id))}

  defp signalled(%{updates: [_ | _] = updates}), do: {"follow_up", one(updates)}
  defp signalled(%{ambient: [kind | _rest]}), do: {"follow_up", kind}
  defp signalled(_carried), do: {"unknown", nil}

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
  Why a schedule Blip makes in a run of `origin` was made, for its
  `asked_by`: `"owner"` when the owner typed into the run, `"blip"`
  otherwise (Blip set it up on its own, say from a schedule's firing or
  a thread update). Its firings then read as a schedule or as Blip's
  follow-up (`of/1`).
  """
  @spec asked_by(t() | term()) :: String.t()
  def asked_by(%{owner_wrote?: true}), do: "owner"
  def asked_by(_origin), do: "blip"

  @doc """
  Whether Blip may start or message one more thread in a run of
  `origin`, having done so `count` times since the owner last wrote to
  it, with at most `limit` allowed: always in a run the owner typed
  into, else only below the limit.
  """
  @spec unattended_ok?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def unattended_ok?(%{owner_wrote?: true}, _count, _limit), do: true
  def unattended_ok?(_origin, count, limit), do: count < limit

  @doc """
  What a `start_thread` or `message_thread` call in a run of `origin`
  adds to its result's details: `%{"unattended" => true}` when the owner
  didn't type into the run, so the call counts towards the unattended
  limit, else nothing.
  """
  @spec unattended_details(t() | term()) :: %{optional(String.t()) => true}
  def unattended_details(%{owner_wrote?: true}), do: %{}
  def unattended_details(_origin), do: %{"unattended" => true}

  @doc """
  Whether Blip may make a project's schedule in a run of `origin`: only
  when the owner typed into it. Each firing starts or wakes a thread,
  with no limit, so Blip can't set one up on its own, nor because a
  thread said so.
  """
  @spec schedule_work_ok?(t() | term()) :: boolean()
  def schedule_work_ok?(%{owner_wrote?: true}), do: true
  def schedule_work_ok?(_origin), do: false

  @doc "What `schedule` says to a project's schedule in a run the owner didn't type into."
  @spec schedule_work_message() :: String.t()
  def schedule_work_message,
    do:
      "Only the user can set up work in a project on a schedule. Ask them, " <>
        "or leave out project for a reminder to yourself."

  @doc "What a tool says when a thread's question limits the run (`restricted?`)."
  @spec restricted_message() :: String.t()
  def restricted_message,
    do:
      "A thread's question can't start or change work. " <>
        "Answer it with answer_question, or ask the user with ask_owner."

  @doc "What a tool that starts or changes work says in a digest or review run (`report_only?`)."
  @spec report_only_message() :: String.t()
  def report_only_message,
    do:
      "A digest or review run only reports. " <>
        "Tell the user what you'd do, and do it when they say so."

  @doc "What `start_thread` and `message_thread` say at the unattended limit."
  @spec unattended_message(non_neg_integer()) :: String.t()
  def unattended_message(limit),
    do:
      "You've started or messaged threads #{limit} times since the user last wrote to you. " <>
        "Tell them what's going on and wait for them."
end
