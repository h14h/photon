defmodule Photon.Schedules.Rules do
  @moduledoc """
  The rules for schedules (sections 3.1 to 3.5 of
  `docs/plans/step-3-skills-and-schedules.md`), as pure functions.
  `Photon.Schedules` and its routine read the clock and the committed
  facts, ask these what to do, and apply the answer in the same commit.

  Times are Unix milliseconds where the routine's task keeps them
  (`arm/4`, `fired_through/3`, `next_after/3`, and the `now` every
  function takes), and `DateTime`s where a schedule's row keeps them
  (`first_at` in what `schedule/2` and `from_tool/2` return, and
  `when_text/2`).

  - Reading input: `schedule/2` checks the owner's form, `from_tool/2`
    Blip's `schedule` tool's arguments. Both accept a time up to a
    minute ago, since the form's time input only goes down to the minute
    and Blip's "now" is a few milliseconds old by the time it is stored.
  - Arming: `arm/4` is the first time a new or edited schedule's task
    waits for, given what the task it replaces already fired
    (`fired_through/3`), so an edit neither skips nor repeats a firing.
    `next_after/3` is the next time after a firing.
  - Firing: `target/1` says where a schedule fires, and `fire/2` what a
    firing does there, from the consent and overlap facts (section 3.5);
    `text/1`, `skipped_note/2` and `request_id/3` are what it writes.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @prompt_limit 4_000
  @grace_ms 60_000
  @min_minutes 5
  @max_minutes 52 * 10_080
  @units %{"minutes" => 1, "hours" => 60, "days" => 1_440, "weeks" => 10_080}

  @prompt_required "Say what this schedule should ask for."
  @prompt_too_long "Keep the prompt under 4,000 characters, and put the rest in a context file."
  @every_message "Repeat every whole number of minutes, hours, days or weeks."

  @typedoc "Unix milliseconds."
  @type ms :: integer()

  @typedoc "Where a schedule fires: Blip's conversation, one thread, or a new thread each time."
  @type target :: :blip | :thread | :new_thread

  @typedoc "A schedule's fields as `schedule/2` checked them."
  @type attrs :: %{
          prompt: String.t(),
          first_at: DateTime.t(),
          every_minutes: pos_integer() | nil,
          conversation_id: String.t() | nil
        }

  @typedoc "A schedule's fields as `from_tool/2` read them from Blip's arguments."
  @type tool_attrs :: %{
          prompt: String.t(),
          first_at: DateTime.t(),
          every_minutes: pos_integer() | nil
        }

  @typedoc "Form errors: each field's message."
  @type field_errors :: %{optional(:prompt | :at | :repeat | :every | :target) => String.t()}

  @typedoc """
  What a firing knows, read inside its commit (section 3.5). A fact that
  doesn't apply to the target may be left out, and counts as false:
  `last_thread_running?` is for a new-thread target, and `thread?`,
  `queued?` and `busy?` for a target with a conversation.
  """
  @type facts :: %{
          optional(:allowed?) => boolean(),
          optional(:last_thread_running?) => boolean(),
          optional(:queued?) => boolean(),
          optional(:thread?) => boolean(),
          optional(:busy?) => boolean()
        }

  @typedoc "What a firing outcome is called on the row (`last_outcome`)."
  @type outcome :: String.t()

  @typedoc """
  What a firing does: start a thread, submit the prompt, or skip, with or
  without a notice entry in the target's conversation. Each carries the
  outcome to store on the row.
  """
  @type decision ::
          {:start, outcome()} | {:submit, outcome()} | {:skip, outcome(), :notice | :quiet}

  ## Reading input

  @doc """
  Checks the owner's form (section 3.4): `params` with string (or atom)
  keys `prompt`, `at` (ISO 8601 with an offset), `repeat` (`"once"` or
  `"every"`), `every` and `unit` (with `"every"`), and `target`
  (`"new_thread"` or a thread's ID). `now` is Unix milliseconds;
  `thread_ids` are the project's threads.

  Returns the row's fields, `conversation_id` nil for a new thread each
  time, or every field's error.
  """
  @spec schedule(map(), %{now: ms(), thread_ids: [String.t()]}) ::
          {:ok, attrs()} | {:error, field_errors()}
  def schedule(params, %{now: now, thread_ids: thread_ids}) do
    repeat = param(params, :repeat)

    results = %{
      prompt: prompt(param(params, :prompt)),
      at: at(param(params, :at), repeat, now),
      repeat: repeat(repeat),
      every: every(repeat, param(params, :every), param(params, :unit)),
      target: target_param(param(params, :target), thread_ids)
    }

    collect(results)
  end

  # Every field's error, or the row's fields once all of them are ok.
  defp collect(results) do
    case for({field, {:error, message}} <- results, into: %{}, do: {field, message}) do
      errors when errors == %{} -> {:ok, attrs(Map.new(results, fn {k, {:ok, v}} -> {k, v} end))}
      errors -> {:error, errors}
    end
  end

  defp attrs(values) do
    %{
      prompt: values.prompt,
      first_at: datetime(values.at),
      every_minutes: values.every,
      conversation_id: values.target
    }
  end

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp prompt(prompt) when is_binary(prompt) do
    prompt = prompt |> String.replace("\r\n", "\n") |> String.trim()

    cond do
      prompt == "" -> {:error, @prompt_required}
      String.length(prompt) > @prompt_limit -> {:error, @prompt_too_long}
      true -> {:ok, prompt}
    end
  end

  defp prompt(_prompt), do: {:error, @prompt_required}

  defp at(at, repeat, now) do
    case parse_time(at) do
      {:ok, ms} when repeat == "once" and ms < now - @grace_ms ->
        {:error, "That time has passed."}

      {:ok, ms} ->
        {:ok, ms}

      :error ->
        {:error, "Pick a date and time."}
    end
  end

  defp parse_time(at) when is_binary(at) do
    case DateTime.from_iso8601(String.trim(at)) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime, :millisecond)}
      {:error, _reason} -> :error
    end
  end

  defp parse_time(_at), do: :error

  defp repeat(repeat) when repeat in ["once", "every"], do: {:ok, repeat}
  defp repeat(_repeat), do: {:error, "Pick Once or Every."}

  defp every("every", every, unit) do
    case {whole_number(every), Map.get(@units, unit)} do
      {nil, _factor} -> {:error, @every_message}
      {_count, nil} -> {:error, @every_message}
      {count, factor} -> every_minutes(count * factor)
    end
  end

  defp every(_repeat, _every, _unit), do: {:ok, nil}

  defp every_minutes(minutes) when minutes < @min_minutes,
    do: {:error, "Repeat no more often than every 5 minutes."}

  defp every_minutes(minutes) when minutes > @max_minutes,
    do: {:error, "Repeat at least once a year."}

  defp every_minutes(minutes), do: {:ok, minutes}

  defp whole_number(number) when is_integer(number), do: number

  defp whole_number(number) when is_binary(number) do
    case Integer.parse(String.trim(number)) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp whole_number(_number), do: nil

  defp target_param("new_thread", _thread_ids), do: {:ok, nil}

  defp target_param(id, thread_ids) when is_binary(id) do
    if id in thread_ids, do: {:ok, id}, else: target_error()
  end

  defp target_param(_id, _thread_ids), do: target_error()

  defp target_error,
    do: {:error, "Pick one of this project's threads, or a new thread each time."}

  @doc """
  Reads Blip's `schedule` tool's arguments (`prompt`, `in_minutes` or
  `at`, `every_minutes`) with the tool's messages, at `now` (Unix
  milliseconds). An `at` more than a minute ago is refused, the same
  grace as the form's; without a time, a repeating schedule first fires
  one interval from now.
  """
  @spec from_tool(map(), ms()) :: {:ok, tool_attrs()} | {:error, String.t()}
  def from_tool(args, now) do
    with {:ok, prompt} <- prompt(args["prompt"]),
         {:ok, first_at} <- tool_first_at(args, now),
         {:ok, every} <- tool_every(args["every_minutes"]) do
      {:ok, %{prompt: prompt, first_at: datetime(first_at), every_minutes: every}}
    end
  end

  defp tool_first_at(%{"in_minutes" => minutes}, now) when is_integer(minutes) and minutes >= 0,
    do: {:ok, now + minutes * 60_000}

  defp tool_first_at(%{"at" => at}, now) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} ->
        ms = DateTime.to_unix(datetime, :millisecond)
        if ms < now - @grace_ms, do: {:error, "#{at} is in the past."}, else: {:ok, ms}

      {:error, _reason} ->
        {:error, "at must be ISO 8601 with a UTC offset, like 2026-10-04T09:00:00-05:00."}
    end
  end

  defp tool_first_at(%{"every_minutes" => every}, now) when is_integer(every),
    do: {:ok, now + every * 60_000}

  defp tool_first_at(_args, _now), do: {:error, "Give in_minutes or at."}

  defp tool_every(nil), do: {:ok, nil}

  defp tool_every(minutes) when is_integer(minutes) and minutes >= @min_minutes,
    do: {:ok, minutes}

  defp tool_every(_minutes), do: {:error, "every_minutes must be at least 5."}

  ## Arming

  @doc """
  The first time a new or edited schedule's task waits for (Unix
  milliseconds), or `:finished` when there is none (section 3.3).

  `first_at` and `every` (nil for a one-off) are the schedule's times,
  `now` the clock the input was checked against, and `fired_through` the
  latest of those times the replaced task already fired or skipped as
  missed (`fired_through/3`), nil for a new schedule. A time up to a
  minute before `now` still fires, but never one at or before
  `fired_through`.
  """
  @spec arm(ms(), pos_integer() | nil, ms(), ms() | nil) :: ms() | :finished
  def arm(first_at, every, now, fired_through) do
    lower = lower(now, fired_through)

    cond do
      first_at >= lower -> first_at
      every == nil -> :finished
      true -> first_at + ceil_div(lower - first_at, every) * every
    end
  end

  defp lower(now, nil), do: now - @grace_ms
  defp lower(now, fired_through), do: max(now - @grace_ms, fired_through + 1)

  defp ceil_div(a, b), do: div(a + b - 1, b)

  @doc """
  The latest time on a schedule's times that its routine task has fired
  (or skipped as missed), from the task's `input`, `checkpoint` and
  `status` as plain maps, or nil when it hasn't fired.

  A one-off that finished `"done"` fired at its `first_at`. A repeating
  task that has fired waits for `next_at`, and every slot before it
  counts as fired: the ones between its last firing and `next_at` were
  missed while the hub was down and skipped. A firing still in flight
  hasn't committed, so it doesn't count.
  """
  @spec fired_through(map(), map(), String.t()) :: ms() | nil
  def fired_through(input, checkpoint, status) do
    every = input["every_ms"]

    cond do
      every == nil and status == "done" -> input["first_at"]
      every == nil -> nil
      (checkpoint["runs"] || 0) == 0 -> nil
      true -> checkpoint["next_at"] - every
    end
  end

  @doc """
  The first whole hour (UTC) after `now`: the schedule form's starting
  time.
  """
  @spec next_hour(ms()) :: ms()
  def next_hour(now), do: (div(now, 3_600_000) + 1) * 3_600_000

  @doc """
  The first time after `now` on the grid that `at` (a time it fired for)
  is on, so slots missed while the hub was down are skipped rather than
  fired in a burst.
  """
  @spec next_after(ms(), pos_integer(), ms()) :: ms()
  def next_after(at, every, now) do
    missed = div(max(now - at, 0), every)
    at + (missed + 1) * every
  end

  ## Firing

  @doc """
  Where a schedule (any map with `project_id` and `conversation_id`)
  fires: Blip's conversation when it belongs to no project, the thread
  it names, or a new thread each time when it names none.
  """
  @spec target(%{
          :project_id => String.t() | nil,
          :conversation_id => String.t() | nil,
          optional(atom()) => term()
        }) :: target()
  def target(%{project_id: nil}), do: :blip
  def target(%{conversation_id: nil}), do: :new_thread
  def target(%{}), do: :thread

  @doc """
  What a firing at `target` does, given the `facts` read in its commit
  (section 3.5): skip it when the thread it would wake is gone, when
  scheduled work isn't allowed (leaving a notice where there is a
  conversation to put one in), when its last new thread is still
  running, or when its last prompt is still queued; otherwise start a
  thread, or submit the prompt, which starts a run in an idle
  conversation or queues behind a busy one.
  """
  @spec fire(target(), facts()) :: decision()
  def fire(target, facts) do
    cond do
      target == :thread and not fact(facts, :thread?) -> {:skip, "skipped_missing", :quiet}
      not fact(facts, :allowed?) -> {:skip, "skipped_consent", consent_note(target)}
      true -> fire_allowed(target, facts)
    end
  end

  defp fire_allowed(:new_thread, facts) do
    if fact(facts, :last_thread_running?),
      do: {:skip, "skipped_running", :quiet},
      else: {:start, "started"}
  end

  defp fire_allowed(_target, facts) do
    cond do
      fact(facts, :queued?) -> {:skip, "skipped_queued", :quiet}
      fact(facts, :busy?) -> {:submit, "queued"}
      true -> {:submit, "sent"}
    end
  end

  defp fact(facts, key), do: Map.get(facts, key, false) == true

  defp consent_note(:new_thread), do: :quiet
  defp consent_note(_target), do: :notice

  @doc "What a firing says: the prompt, marked as scheduled."
  @spec text(String.t()) :: String.t()
  def text(prompt), do: "[Scheduled] " <> prompt

  @doc """
  The notice entry a firing skipped for want of consent leaves in Blip's
  conversation or a thread. It is never sent to the model.
  """
  @spec skipped_note(:blip | :thread, String.t()) :: %{String.t() => String.t() | true}
  def skipped_note(:blip, prompt) do
    notice(
      ~s{Skipped "#{prompt}": scheduled work is off. Turn it on in Settings to let me use your plan while you're away.}
    )
  end

  def skipped_note(:thread, prompt) do
    notice(
      ~s{Skipped the scheduled prompt "#{prompt}": scheduled work is off. Turn it on in Settings to let schedules use your ChatGPT plan while you're away.}
    )
  end

  defp notice(message), do: %{"message" => message, "notice" => true}

  @doc """
  The request ID of a firing's submission: one per schedule, task and
  firing (`runs`, the task's count of firings), so a step that runs again
  submits once.
  """
  @spec request_id(String.t(), String.t(), non_neg_integer()) :: String.t()
  def request_id(schedule_id, task_id, runs), do: "schedule:#{schedule_id}:#{task_id}:#{runs}"

  @doc """
  When a schedule fires, in Blip's tool's words: "first at 2026-10-08
  09:00 UTC, then every 1440 minutes", or only the first part for a
  one-off.
  """
  @spec when_text(DateTime.t(), pos_integer() | nil) :: String.t()
  def when_text(first_at, every_minutes) do
    first = "first at " <> Calendar.strftime(first_at, "%Y-%m-%d %H:%M UTC")
    if every_minutes, do: "#{first}, then every #{every_minutes} minutes", else: first
  end

  @doc "Unix milliseconds as a `DateTime` a schedule's row stores."
  @spec datetime(ms()) :: DateTime.t()
  def datetime(ms), do: DateTime.from_unix!(ms * 1_000, :microsecond)
end
