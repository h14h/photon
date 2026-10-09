defmodule Photon.Ambient do
  @moduledoc """
  Ambient mode: a setting, off by default, that lets Blip follow along with
  the owner's projects and speak up on its own. While it is on, Blip also
  gets a digest of what changed every hour, 3 hours or 6 hours, and a daily
  review, around 09:00 at the owner's UTC offset, of threads left stopped,
  failed or waiting on the owner for days. Off, what reaches Blip is exactly
  quiet mode's.

  ## The setting

  Its settings are the durable doc `global/ambient` (see `Photon.Signals`).
  A Save writes the doc and arms or retires the two timers in one commit,
  so no timer ever runs against a doc that says off; a file write and a
  database commit can't be one step, so the setting lives here and not in
  the settings file.

  ## The timers

  Each timer is a durable task of kind `"ambient"` (`Photon.Ambient.Timer`),
  the shape of a schedule's routine: it waits until its time, fires in
  one fenced commit (`Photon.Durable.Runtime.commit/2`), and waits again on
  its grid (`Photon.Ambient.Rules.next_firing/3`). The next times are read
  from the tasks, never stored on the doc (rule 15). Retiring a timer is
  `Photon.Durable.Tx.request_abort/3` in the commit that changes the
  setting, so a firing step of the old task commits nothing afterwards.

  ## A firing

  `fire_tx/3` is every read and write of one firing, inside the caller's
  commit, so a firing the fence ignores leaves everything as it was.
  Unless it skips (`Photon.Ambient.Rules.firing/1`):

    * a digest sorts the pending items against the board
      (`Photon.Ambient.Rules.digest/3`). With nothing new to the owner it
      posts nothing and the smaller items wait. Otherwise it posts one
      `[Digest]` signal and marks every item it read as carried by it, in
      the same commit, so none is reported twice.
    * a review posts one `[Daily review]` signal for the threads
      `Photon.Ambient.Rules.review/3` picks and marks them reviewed, so
      each is raised once per quiet spell and again after
      `review_again_days`.

  What a digest carried is used up only when Blip has read it
  (`settled_tx/2`, `withdrawn_tx/2`).

  ## Cost

  Every digest and review is a run on the owner's ChatGPT plan, so they are
  bounded (rule 73): at most one digest per interval, and only when
  something in it is new to the owner; one review a day, only when threads
  qualify; neither stacks behind one Blip hasn't read; the texts are cut
  (`Photon.Ambient.Text`); and the runs they start only report, so they
  can't cause the changes a later digest carries.

  There is no process here (rules 3, 31, 89): the timers are durable
  tasks the Scheduler already runs, and the doc and the items are rows.
  """

  use Boundary,
    deps: [
      Photon.ChatGPT,
      Photon.Durable,
      Photon.Events,
      Photon.Projects,
      Photon.Schedules,
      Photon.Settings,
      Photon.Signals,
      Photon.Threads,
      Photon.Threads.State,
      PhotonCore
    ],
    exports: []

  alias Photon.Ambient.{Rules, Text, Timer}
  alias Photon.{ChatGPT, Durable, Events, Projects, Schedules, Settings, Signals, Threads}
  alias Photon.Durable.{Submission, TaskRecord, Tx}
  alias Photon.Signals.Rules, as: SignalRules

  @jobs ["digest", "review"]

  @day_ms 86_400_000

  # How long after a review listed a thread it may list it again.
  @review_again_days 7

  @typedoc "Unix milliseconds."
  @type ms :: integer()

  @typedoc "Which timer: the digest or the daily review."
  @type job :: String.t()

  @typedoc """
  What a firing goes on, read before its commit: whether Blip can reach
  its model, whether it may use the owner's plan, the key of the signal it
  posts, and the clock.
  """
  @type firing :: %{thinks?: boolean(), allowed?: boolean(), key: String.t(), now: ms()}

  @typedoc """
  What a firing did: when, its outcome (`"sent"`, `"queued"`,
  `"skipped_nothing"`, `"skipped_model"`, `"skipped_consent"`,
  `"skipped_queued"` or `"off"`) and how many changes or threads it
  carried (0 when it posted nothing).
  """
  @type result :: %{at: DateTime.t(), outcome: String.t(), count: non_neg_integer()}

  @typedoc "A timer that stopped after an error: which, and why."
  @type stopped :: %{job: job(), reason: String.t()}

  @typedoc """
  What the Settings page shows. The timers' next times are nil when not
  running; `consent?` is whether Settings lets schedules use the owner's
  plan, and `thinks?` whether Blip can reach its model.
  """
  @type status :: %{
          on?: boolean(),
          every_minutes: pos_integer(),
          next_digest_at: DateTime.t() | nil,
          next_review_at: DateTime.t() | nil,
          pending: %{new: non_neg_integer(), smaller: non_neg_integer()},
          last_digest: result() | nil,
          last_review: result() | nil,
          stopped: stopped() | nil,
          consent?: boolean(),
          thinks?: boolean(),
          scripted?: boolean()
        }

  @typedoc "`t:status/0` without the timers' next times and the pending counts."
  @type brief :: %{
          on?: boolean(),
          last_digest: result() | nil,
          last_review: result() | nil,
          stopped: stopped() | nil,
          consent?: boolean(),
          thinks?: boolean(),
          scripted?: boolean()
        }

  ## Reading

  @doc "Subscribes to `{:ambient_changed}`, sent after every save, firing, failed timer and collected item."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(Signals.ambient_topic())

  @doc "The digest intervals the owner can pick, in minutes."
  @spec every_options() :: [pos_integer()]
  def every_options, do: Rules.every_options()

  @doc """
  Ambient mode as the pages show it. The pending counts are what a digest
  would send now (`Photon.Ambient.Rules.digest/3`), so opening a finished
  thread moves it from new to smaller.
  """
  @spec status() :: status()
  def status do
    doc = Signals.ambient_doc()
    config = Rules.config(%{}, doc)

    doc
    |> brief_of()
    |> Map.merge(%{
      every_minutes: config.every_minutes,
      next_digest_at: next_at(Map.get(doc, "digest_task_id")),
      next_review_at: next_at(Map.get(doc, "review_task_id")),
      pending: pending(config.on?)
    })
  end

  @doc """
  What the home page's warnings need. Unlike `status/0` it reads no items
  and no board, so a page can call it on every `{:ambient_changed}`.
  """
  @spec brief() :: brief()
  def brief, do: brief_of(Signals.ambient_doc())

  defp brief_of(doc) do
    %{
      on?: Rules.config(%{}, doc).on?,
      last_digest: result(Map.get(doc, "last_digest")),
      last_review: result(Map.get(doc, "last_review")),
      stopped: stopped(Map.get(doc, "stopped")),
      consent?: Settings.scheduled_work?(Settings.load()),
      thinks?: thinks?(),
      scripted?: scripted?()
    }
  end

  @doc false
  # Whether Blip can reach its model now: signed in to ChatGPT with plan
  # use allowed, or the scripted model. A firing reads it before its commit.
  @spec thinks?() :: boolean()
  def thinks?, do: ChatGPT.ready?(ChatGPT.status())

  # A live timer's next time, from its task (rule 15).
  defp next_at(nil), do: nil

  defp next_at(task_id) do
    case Durable.task(task_id) do
      %TaskRecord{} = task ->
        if live_task?(task), do: datetime(task.checkpoint["next_at"] || task.input["first_at"])

      nil ->
        nil
    end
  end

  defp pending(false), do: %{new: 0, smaller: 0}

  defp pending(true) do
    case Signals.pending() do
      [] ->
        %{new: 0, smaller: 0}

      items ->
        digest = Rules.digest(items, Threads.board(:all), places(items))
        %{new: length(digest.new) + digest.more_new, smaller: smaller_count(digest)}
    end
  end

  defp smaller_count(digest), do: length(digest.smaller) + digest.more_smaller

  defp result(%{"at" => at, "outcome" => outcome} = stored) when is_binary(outcome) do
    case DateTime.from_iso8601(to_string(at)) do
      {:ok, at, _offset} -> %{at: at, outcome: outcome, count: count(stored["count"])}
      {:error, _reason} -> nil
    end
  end

  defp result(_none), do: nil

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_n), do: 0

  defp stopped(%{"job" => job, "reason" => reason}), do: %{job: job, reason: to_string(reason)}
  defp stopped(_none), do: nil

  defp scripted?, do: Application.get_env(:photon, :mock_model, false) == true

  ## The setting

  @doc """
  Saves ambient mode's part of the Settings form in one commit
  (`Photon.Ambient.Rules.config/2`), with the timers the setting calls for
  (`Photon.Ambient.Rules.changes/3`). Turning it off also deletes every
  pending item, withdraws a digest or review still queued in Blip's inbox,
  and clears the marks of the threads a withdrawn review named; collection
  stops from the next commit. Announces `{:ambient_changed}`. Never an
  error.
  """
  @spec configure(map()) :: :ok
  def configure(params) do
    now = System.system_time(:millisecond)
    Durable.commit(&configure_tx(&1, params, now))
  end

  defp configure_tx(tx, params, now) do
    doc = Signals.ambient_doc_tx(tx)
    config = Rules.config(params, doc)
    live = %{digest: live?(tx, doc["digest_task_id"]), review: live?(tx, doc["review_task_id"])}
    changes = Rules.changes(doc, config, live)
    armed? = Enum.any?([changes.digest, changes.review], &(&1 in [:arm, :rearm]))
    version = version(doc) + if(armed?, do: 1, else: 0)
    arming = %{config: config, version: version, now: now}

    timers = %{
      "digest_task_id" => timer_tx(tx, "digest", changes.digest, doc["digest_task_id"], arming),
      "review_task_id" => timer_tx(tx, "review", changes.review, doc["review_task_id"], arming)
    }

    :ok = if changes.clear?, do: clear_tx(tx), else: :ok

    fields =
      Map.merge(timers, %{
        "on" => config.on?,
        "every_minutes" => config.every_minutes,
        "offset_minutes" => config.offset_minutes,
        "version" => version
      })

    :ok = put_doc_tx(tx, saved(doc, fields, changes, now))
    Tx.announce(tx, Signals.ambient_topic(), {:ambient_changed})
  end

  defp live?(_tx, nil), do: false

  defp live?(tx, task_id) do
    case Tx.get_task(tx, task_id) do
      %TaskRecord{} = task -> live_task?(task)
      nil -> false
    end
  end

  defp live_task?(task), do: not task.abort_requested and not TaskRecord.terminal?(task)

  defp version(%{"version" => version}) when is_integer(version), do: version
  defp version(_doc), do: 0

  # Returns the doc's task ID for the timer.
  defp timer_tx(_tx, _job, :keep, task_id, %{config: %{on?: true}}), do: task_id
  defp timer_tx(_tx, _job, :keep, _task_id, _arming), do: nil

  defp timer_tx(tx, _job, :retire, task_id, _arming) do
    :ok = retire_tx(tx, task_id)
    nil
  end

  defp timer_tx(tx, job, :arm, _task_id, arming), do: arm_tx(tx, job, arming)

  defp timer_tx(tx, job, :rearm, task_id, arming) do
    :ok = retire_tx(tx, task_id)
    arm_tx(tx, job, arming)
  end

  defp retire_tx(_tx, nil), do: :ok

  defp retire_tx(tx, task_id) do
    case Tx.get_task(tx, task_id) do
      %TaskRecord{} = task ->
        _retired = Tx.request_abort(tx, task, background: true)
        :ok

      nil ->
        :ok
    end
  end

  # The digest first fires one interval from now, so turning it on posts
  # nothing at once; the review at the next 09:00 at the owner's offset.
  defp arm_tx(tx, job, %{config: config, version: version, now: now}) do
    {first_at, every_ms} =
      case job do
        "digest" -> {now + config.every_minutes * 60_000, config.every_minutes * 60_000}
        "review" -> {Rules.next_review(now, config.offset_minutes), @day_ms}
      end

    task =
      Tx.create_task(
        tx,
        Timer.task(job, %{first_at: first_at, every_ms: every_ms, version: version})
      )

    task.id
  end

  defp clear_tx(tx) do
    :ok = Signals.drop_items_tx(tx, :all)
    thread_ids = Enum.flat_map(Signals.withdraw_ambient_tx(tx), &review_threads/1)
    Threads.unmark_reviewed_tx(tx, Enum.uniq(thread_ids))
  end

  defp review_threads(%{"kind" => "review", "items" => items}) when is_list(items),
    do: for(%{"thread_id" => id} when is_binary(id) <- items, do: id)

  defp review_threads(_ref), do: []

  ## After Blip's run

  @doc """
  What a settle of Blip's run means for the digests and reviews it
  closed, inside the settle's commit (Blip's `on_settled/3`): a digest
  the run answered, or that the owner stopped, has its items deleted.
  When the run failed (the request failed, the round limit, the task
  failed), a digest's items wait for the next digest again and a review's
  threads lose their review mark, since Blip never told the owner about
  them. Total, as the settle hook must be: anything else does nothing.
  """
  @spec settled_tx(Tx.t(), map()) :: :ok
  def settled_tx(tx, %{outcome: outcome, submissions: submissions}) when is_list(submissions) do
    Enum.each(submissions, &(:ok = settled_ref_tx(tx, outcome, ambient_ref(&1))))
  end

  def settled_tx(_tx, _settled), do: :ok

  defp settled_ref_tx(tx, "failed", %{"kind" => "digest", "key" => key}) when is_binary(key),
    do: Signals.release_items_tx(tx, key)

  defp settled_ref_tx(tx, _done_or_stopped, %{"kind" => "digest", "key" => key})
       when is_binary(key),
       do: Signals.drop_carried_tx(tx, key)

  defp settled_ref_tx(tx, "failed", %{"kind" => "review"} = ref),
    do: Threads.unmark_reviewed_tx(tx, review_threads(ref))

  defp settled_ref_tx(_tx, _outcome, _ref), do: :ok

  @doc """
  What withdrawing `submission` from Blip's inbox means, inside the
  commit that withdrew it: a digest's items are deleted, and a review's
  threads lose their review mark, as turning ambient mode off does. Blip
  never read it. Anything else does nothing.
  """
  @spec withdrawn_tx(Tx.t(), Submission.t()) :: :ok
  def withdrawn_tx(tx, %Submission{status: "withdrawn"} = submission) do
    case ambient_ref(submission) do
      %{"kind" => "digest", "key" => key} when is_binary(key) -> Signals.drop_carried_tx(tx, key)
      %{"kind" => "review"} = ref -> Threads.unmark_reviewed_tx(tx, review_threads(ref))
      _other -> :ok
    end
  end

  def withdrawn_tx(_tx, _submission), do: :ok

  defp ambient_ref(%Submission{content: %{"source" => source}}),
    do: SignalRules.ambient_ref(source)

  defp ambient_ref(_submission), do: nil

  # The doc a Save leaves. Arming clears a stopped timer's warning, and so
  # does turning it off; turning it on starts the digest's window afresh,
  # since nothing from before reaches a digest.
  defp saved(doc, fields, changes, now) do
    armed? = Enum.any?([changes.digest, changes.review], &(&1 in [:arm, :rearm]))

    doc
    |> Map.merge(fields)
    |> then(&if(armed? or not fields["on"], do: Map.put(&1, "stopped", nil), else: &1))
    |> then(fn doc ->
      if changes.turned_on?,
        do: Map.merge(doc, %{"on_since" => iso(now), "last_sent_at" => nil}),
        else: doc
    end)
  end

  ## Firing

  @doc """
  Sends a digest now, as a firing would (consent taken as given), without
  moving the timer. Only the scripted model's button and the tests call it.
  """
  @spec digest_now() :: result()
  def digest_now, do: fire_now("digest")

  @doc "Runs the daily review now, as `digest_now/0` does the digest."
  @spec review_now() :: result()
  def review_now, do: fire_now("review")

  defp fire_now(job) do
    firing = %{
      thinks?: thinks?(),
      allowed?: true,
      key: "#{job}:now:#{PhotonCore.ID.new()}",
      now: System.system_time(:millisecond)
    }

    Durable.commit(&fire_tx(&1, job, firing))
  end

  @doc false
  # One firing of `job` inside the caller's commit. Records the outcome on
  # the doc and announces it, except while ambient mode is off.
  @spec fire_tx(Tx.t(), job(), firing()) :: result()
  def fire_tx(tx, job, firing) when job in @jobs do
    doc = Signals.ambient_doc_tx(tx)

    facts = %{
      on?: doc["on"] == true,
      thinks?: firing.thinks?,
      allowed?: firing.allowed?,
      queued?: Signals.queued_ambient?(tx, job)
    }

    {outcome, count} =
      case Rules.firing(facts) do
        :go -> go_tx(tx, job, doc, firing)
        {:skip, outcome} -> {outcome, 0}
      end

    result = %{at: datetime(firing.now), outcome: outcome, count: count}
    :ok = record_tx(tx, job, result)
    result
  end

  defp go_tx(tx, "digest", doc, firing) do
    items = Signals.pending_tx(tx)
    digest = Rules.digest(items, Threads.board(:all), places(items))

    case digest.new do
      [] ->
        :ok = Signals.drop_items_tx(tx, digest.gone)
        {"skipped_nothing", 0}

      _new ->
        at = datetime(firing.now)

        outcome =
          post_tx(tx, %{
            key: firing.key,
            text: Text.digest(digest, doc),
            ref: Text.digest_ref(digest, firing.key),
            older: Text.digest_older(digest, at)
          })

        # Every item it read goes with it: those shown, those counted and
        # those folded into a newer one about the same subject wait for
        # Blip's run to settle (`settled_tx/2`); those gone are deleted.
        carried = Enum.map(items, & &1.id) -- digest.gone
        :ok = Signals.carry_items_tx(tx, carried, firing.key)
        :ok = Signals.drop_items_tx(tx, digest.gone)
        :ok = put_doc_tx(tx, Map.put(doc, "last_sent_at", iso(firing.now)))
        {outcome, length(digest.new) + digest.more_new + smaller_count(digest)}
    end
  end

  defp go_tx(tx, "review", _doc, firing) do
    at = datetime(firing.now)
    review = Rules.review(Threads.board(:all), at, review_opts())

    case review.rows do
      [] ->
        {"skipped_nothing", 0}

      rows ->
        outcome =
          post_tx(tx, %{
            key: firing.key,
            text: Text.review(review, answers(rows), at),
            ref: Text.review_ref(review, firing.key),
            older: Text.review_older(review, at)
          })

        :ok = Threads.mark_reviewed_tx(tx, Enum.map(rows, & &1.thread_id), at)
        {outcome, length(rows) + review.more}
    end
  end

  # What the digest names besides the board: the prompts and current tasks
  # of the schedules its items name that still exist, and every project.
  defp places(items) do
    schedule_ids = for %{schedule_id: id} when is_binary(id) <- items, uniq: true, do: id
    schedules = Schedules.lookup(schedule_ids)

    %{
      prompts: Map.new(schedules, fn {id, schedule} -> {id, schedule.prompt} end),
      tasks: Map.new(schedules, fn {id, schedule} -> {id, schedule.task_id} end),
      projects: Projects.list()
    }
  end

  # A stopped thread's line quotes its latest answer; failed and waiting
  # lines use what the board has. At most one read per thread shown.
  defp answers(rows),
    do:
      for(%{state: :quiet, thread_id: id} <- rows, into: %{}, do: {id, Threads.latest_answer(id)})

  defp review_opts do
    days =
      :photon
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:review_again_days, @review_again_days)

    %{quiet_after: Threads.quiet_after(), again_after: days * 86_400}
  end

  defp post_tx(tx, signal) do
    idle? = Tx.active_run(tx, Signals.blip_conversation_tx(tx)) == nil
    # The submission is Blip's to run; the firing only says whether it
    # started a run or waits.
    _submission = Signals.post_tx(tx, signal)
    if idle?, do: "sent", else: "queued"
  end

  # A firing while ambient mode is off (only `digest_now/0` or
  # `review_now/0` can reach one) leaves the doc alone.
  defp record_tx(_tx, _job, %{outcome: "off"}), do: :ok

  defp record_tx(tx, job, result) do
    field = if job == "digest", do: "last_digest", else: "last_review"

    stored = %{
      "at" => DateTime.to_iso8601(result.at),
      "outcome" => result.outcome,
      "count" => result.count
    }

    :ok = put_doc_tx(tx, Map.put(Signals.ambient_doc_tx(tx), field, stored))
    Tx.announce(tx, Signals.ambient_topic(), {:ambient_changed})
  end

  @doc false
  # Records that timer `task_id` (job `job`) failed, inside the Scheduler's
  # fail commit, when it is still the doc's: the pages then say it stopped
  # and why, until a Save arms a new one. Total: anything else writes
  # nothing.
  @spec stopped_tx(Tx.t(), String.t(), term(), term()) :: :ok
  def stopped_tx(tx, task_id, job, reason) do
    doc = Signals.ambient_doc_tx(tx)

    if is_binary(task_id) and task_id in [doc["digest_task_id"], doc["review_task_id"]] do
      stopped = %{"job" => text(job), "reason" => text(reason)}
      :ok = put_doc_tx(tx, Map.put(doc, "stopped", stopped))
      Tx.announce(tx, Signals.ambient_topic(), {:ambient_changed})
    else
      :ok
    end
  end

  defp put_doc_tx(tx, doc) do
    # It returns the doc it wrote, which the caller already has; a failed
    # write raises and rolls the commit back.
    _doc = Signals.put_ambient_doc_tx(tx, doc)
    :ok
  end

  defp text(value) when is_binary(value), do: String.slice(value, 0, 600)
  defp text(value), do: value |> inspect() |> String.slice(0, 600)

  defp datetime(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp datetime(_none), do: nil

  defp iso(ms), do: ms |> datetime() |> DateTime.to_iso8601()
end
