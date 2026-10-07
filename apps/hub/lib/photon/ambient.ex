defmodule Photon.Ambient do
  @moduledoc """
  Ambient mode (`docs/plans/step-5-ambient-mode.md`): a setting, off by
  default, that lets Blip follow along with the owner's projects and speak
  up on its own. While it is on, Blip also gets a digest of what changed
  every hour, 3 hours or 6 hours, and a daily review, around 09:00 at the
  owner's UTC offset, of threads left stopped, failed or waiting on the
  owner for days. Off, what reaches Blip is exactly quiet mode's.

  ## The setting

  Its settings are the durable doc `global/ambient` (section 2.1), which
  `Photon.Signals` reads and writes for everyone, since the threads'
  settle hook reads the mode in its own commit. `configure/1` reads the
  Settings form over the doc (`Photon.Ambient.Rules.config/2`: a missing
  or unexpected value keeps what was there) and, in one commit, writes the
  doc and arms or retires the two timers by `Photon.Ambient.Rules.changes/3`.
  A file write and a database commit can't be one step, so the setting
  lives here and not in the settings file: no timer ever runs against a
  doc that says off. `status/0` is what the Settings and home pages show.

  ## The timers

  Each timer is a durable task of kind `"ambient"` (`Photon.Ambient.Timer`),
  the shape of a schedule's routine: it waits until its time, fires in
  one fenced commit (`Photon.Durable.Runtime.commit/2`), and waits again on
  its grid (`Photon.Ambient.Rules.next_firing/3`; slots missed while the
  hub was down fire once, not in a burst). The next times are read from
  the tasks, never stored on the doc (rule 15). Retiring a timer is
  `Photon.Durable.Tx.request_abort/3` in the commit that changes the
  setting, so a firing step of the old task commits nothing afterwards.

  ## A firing

  `fire_tx/3` is every read and write of one firing, inside the caller's
  commit, so a firing the fence ignores leaves everything as it was. It
  skips while ambient mode is off, while Blip can't reach its model
  (signed out of ChatGPT, or plan use not allowed), while Settings
  doesn't let schedules use the owner's plan, and while the last digest
  (or review) still waits in Blip's inbox
  (`Photon.Ambient.Rules.firing/1`). Otherwise:

    * a digest reads the pending items (`Photon.Signals.pending_tx/1`,
      collected where each change is made) and sorts them against the
      board (`Photon.Ambient.Rules.digest/3`). With nothing new to the
      owner it posts nothing; the smaller items wait. With something new
      it posts one `[Digest]` signal (`Photon.Ambient.Text`) and marks
      every item it read as carried by it, in the same commit, so none is
      reported twice.
    * a review picks the threads untouched for `quiet_after`
      (`Photon.Ambient.Rules.review/3`), posts one `[Daily review]`
      signal, and marks them reviewed (`Photon.Threads.mark_reviewed_tx/3`),
      so each is raised once per quiet spell and again after
      `review_again_days`.

  ## After Blip's run

  What a digest carried is used up only when Blip has read it.
  `settled_tx/2`, from Blip's settle hook, deletes a digest's items when
  the run on it answers or the owner stops it; when the run fails (the
  request failed, or the round limit), the items wait for the next
  digest again and a review's threads lose their mark, since Blip never
  told the owner about them. A digest or review the owner withdraws from
  Blip's inbox (`withdrawn_tx/2`) is dropped as turning ambient mode off
  drops it: its items are deleted, and its threads lose their mark.

  Either records its outcome on the doc and announces `{:ambient_changed}`.
  `digest_now/0` and `review_now/0` run the same firing in a commit of
  their own, for the scripted model's buttons and the tests.

  ## Turning it off

  Turning it off, in one commit: both timers are retired, every pending
  item is deleted, a digest or review still queued in Blip's inbox is
  withdrawn, and the threads a withdrawn review named lose their mark.
  Collection reads the mode in each change's own commit, so nothing is
  collected afterwards.

  ## Cost

  Every digest and review is a run on the owner's ChatGPT plan, so they
  are bounded (rule 73): at most one digest per interval, and only when
  something in it is new to the owner; one review a day, only when
  threads qualify; neither stacks behind one Blip hasn't read; the texts
  are cut (`Photon.Ambient.Text`); and the runs they start only report
  (section 5.2), so they can't cause the changes a later digest carries.

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
      PhotonCore
    ],
    exports: []

  alias Photon.Ambient.{Rules, Text, Timer}
  alias Photon.{ChatGPT, Durable, Events, Projects, Schedules, Settings, Signals, Threads}
  alias Photon.Durable.{Submission, TaskRecord, Tx}
  alias Photon.Signals.Rules, as: SignalRules

  @jobs ["digest", "review"]

  @day_ms 86_400_000

  # How long after a review listed a thread it may list it again, when the
  # config doesn't say.
  @review_again_days 7

  @typedoc "Unix milliseconds."
  @type ms :: integer()

  @typedoc "Which timer: the digest or the daily review."
  @type job :: String.t()

  @typedoc """
  What a firing goes on, read before its commit: whether Blip can reach
  its model (`thinks?`), whether it may use the owner's plan
  (`allowed?`), the key of the signal it posts, and the clock.
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
  What the Settings page shows (section 7.2): the setting, the timers'
  next times (nil when not running), the pending items counted by the
  digest's own rule, the last firing of each, a timer that stopped,
  whether Settings lets schedules use the owner's plan, whether Blip can
  reach its model, and whether the hub runs the scripted model.
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

  @typedoc """
  What the home page's warnings read (`brief/0`): `t:status/0` without
  the timers' next times and the pending counts.
  """
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
  Ambient mode as the pages show it (`t:status/0`). The pending counts
  are what a digest would send now: the items sorted against the board
  by `Photon.Ambient.Rules.digest/3`, so opening a finished thread moves
  it from new to smaller.
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
  What the home page's warnings need (`t:brief/0`): the setting, the last
  firings, a stopped timer, consent and whether Blip can think. Unlike
  `status/0` it reads no items and no board, so a page can call it on
  every `{:ambient_changed}`.
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
  # use allowed, or the scripted model. A firing reads it before its
  # commit, as it reads consent.
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
  Saves ambient mode's part of the Settings form (`"ambient"`,
  `"ambient_every"`, `"utc_offset"`; any other key is ignored, and a
  missing one keeps what was saved) in one commit, with the timers
  section 2.3's table asks for: armed when it is turned on, replaced when
  the interval or the offset changed or a timer isn't running, and
  retired when it is turned off. Turning it off also deletes every
  pending item, withdraws a digest or review still queued in Blip's
  inbox, and clears the marks of the threads a withdrawn review named.
  Announces `{:ambient_changed}`. Never an error.
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

  # A timer's task is live while it exists, hasn't ended and isn't on its
  # way out.
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

  # Applies one timer's action; returns the doc's task ID for it.
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

  # Marks a timer's task for abort (a no-op on one that ended); its firing
  # step is then fenced out.
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

  # Everything pending when it is turned off: the items, carried or not,
  # and a digest or review Blip hasn't seen, whose threads lose their
  # review mark.
  defp clear_tx(tx) do
    :ok = Signals.drop_items_tx(tx, :all)
    thread_ids = Enum.flat_map(Signals.withdraw_ambient_tx(tx), &review_threads/1)
    Threads.unmark_reviewed_tx(tx, Enum.uniq(thread_ids))
  end

  # The threads a review ref listed; none for any other ref.
  defp review_threads(%{"kind" => "review", "items" => items}) when is_list(items),
    do: for(%{"thread_id" => id} when is_binary(id) <- items, do: id)

  defp review_threads(_ref), do: []

  ## After Blip's run

  @doc """
  What a settle of Blip's run means for the digests and reviews it
  closed, inside the settle's commit (Blip's `on_settled/3`):

    * a digest the run answered, or that the owner stopped: the items it
      carries are deleted
    * a digest whose run failed (the request failed, the round limit, the
      task failed): its items wait for the next digest again
    * a review whose run failed: its threads lose their review mark, so
      Home doesn't say they were in a review Blip never told the owner
      about, and the next review lists them

  Total, as the settle hook must be: anything else does nothing.
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
  Sends a digest now, outside the timer, as a firing would (consent taken
  as given), and returns what it did. The timer doesn't move. Only the
  scripted model's button and the tests call it.
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
  # One firing of `job` inside the caller's commit (section 3.3 for the
  # digest, 4.2 for the review), for the timer and `digest_now/0` and
  # `review_now/0`. Records the outcome on the doc and announces it,
  # except while ambient mode is off, when it does nothing at all.
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

  # Posts the signal; "sent" when it starts Blip's run, "queued" when Blip
  # was busy and it waits.
  defp post_tx(tx, signal) do
    idle? = Tx.active_run(tx, Signals.blip_conversation_tx(tx)) == nil
    # The submission is Blip's to run; the firing only says whether it
    # started a run or waits.
    _submission = Signals.post_tx(tx, signal)
    if idle?, do: "sent", else: "queued"
  end

  # Writes the outcome on the doc for the pages and announces it; a firing
  # while ambient mode is off (only `digest_now/0` or `review_now/0` can
  # reach one) leaves the doc alone.
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
