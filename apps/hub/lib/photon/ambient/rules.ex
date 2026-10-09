defmodule Photon.Ambient.Rules do
  @moduledoc """
  Ambient mode's decisions, worked out from plain data with the time passed
  in.

    * The setting: `config/2` reads the Settings form over the stored doc (a
      missing or unexpected value keeps what the doc has), and `changes/3`
      says what a Save does to the two timers and to what is pending.
    * The timers: `next_firing/3` is the next time on a timer's grid
      after a firing (missed slots are skipped, not fired in a burst), and
      `next_review/2` the next 09:00 at the owner's UTC offset.
    * A firing: `firing/1` decides whether it skips (off, Blip can't
      reach its model, no consent, the last one still queued); `digest/3` sorts the pending items into new,
      smaller and gone against the board; `review/3` picks the threads
      the daily review lists. `last_touch/1` is when a thread was last
      touched, for the review.

  Items and board entries are plain maps with the fields
  `Photon.Signals.DigestItem` and `Photon.Threads.board/1` give; every
  function reads them with defaults, so a row missing a field is sorted
  as gone or left out rather than raising.
  """

  # Functional core: no processes, no I/O. The time comes in as an argument.
  use Boundary, type: :strict, deps: [Photon.Threads.State]

  alias Photon.Threads.State

  @every_options [60, 180, 360]
  @default_every 180
  @offset_range -720..840//1

  @day_ms 86_400_000
  @review_hour_ms 9 * 3_600_000

  # The longest digest: new rows and smaller rows shown, the rest counted.
  @new_limit 20
  @smaller_limit 15

  # The longest review: threads shown, the rest counted.
  @review_limit 10

  # Board states the review covers.
  @review_states [:quiet, :failed, :waiting]

  @typedoc "Unix milliseconds."
  @type ms :: integer()

  @typedoc "The setting as a Save leaves it (`config/2`)."
  @type config :: %{on?: boolean(), every_minutes: pos_integer(), offset_minutes: integer()}

  @typedoc "Whether each timer's task is live (exists and hasn't ended)."
  @type live :: %{digest: boolean(), review: boolean()}

  @typedoc """
  What a Save does to one timer: leave it, arm a new one, retire the live
  one and arm a new one, or retire the live one.
  """
  @type action :: :keep | :arm | :rearm | :retire

  @typedoc """
  What a Save does (`changes/3`): each timer's action; `clear?`, whether
  to delete every pending item and withdraw the queued digest and review
  (ambient mode was turned off); `turned_on?`, whether it was turned on.
  """
  @type changes :: %{
          digest: action(),
          review: action(),
          clear?: boolean(),
          turned_on?: boolean()
        }

  @typedoc "A pending digest item, or a map with its fields."
  @type item :: map()

  @typedoc "A board entry (`Photon.Threads.board/1`), or a map with its fields."
  @type entry :: map()

  @typedoc """
  What the digest names besides the board: `prompts`, the schedules that
  still exist, by ID; `tasks`, their current routine task, by ID (a
  schedule missing here is taken to still have the task that failed);
  `projects`, every project (with `id`, `slug` and `name`).
  """
  @type places :: %{
          required(:prompts) => %{optional(String.t()) => String.t()},
          optional(:tasks) => %{optional(String.t()) => String.t() | nil},
          required(:projects) => [map()]
        }

  @typedoc """
  One line of a digest: the item's kind, whether it is new to the owner,
  when it was collected, and what it names, read at digest time. Fields a
  kind doesn't use are nil: `title` and `thread_id` for a thread,
  `project_id`, `slug` and `project` for its project (nil for Blip's own
  schedule), `note` for a finished run, `schedule_id`, `prompt` and
  `reason` for a stopped schedule, `name`, `writer`, `writer_title` and
  `deleted?` for a context file.
  """
  @type row :: %{
          kind: String.t(),
          new?: boolean(),
          at: DateTime.t() | nil,
          thread_id: String.t() | nil,
          title: String.t() | nil,
          project_id: String.t() | nil,
          slug: String.t() | nil,
          project: String.t() | nil,
          note: String.t() | nil,
          schedule_id: String.t() | nil,
          prompt: String.t() | nil,
          reason: String.t() | nil,
          name: String.t() | nil,
          writer: String.t() | nil,
          writer_title: String.t() | nil,
          deleted?: boolean()
        }

  @typedoc "The board's counts for a digest's closing line."
  @type snapshot :: %{
          running: non_neg_integer(),
          waiting: non_neg_integer(),
          failed: non_neg_integer()
        }

  @typedoc """
  The digest (`digest/3`): the new and smaller rows shown, how many more
  of each there are, the IDs of items whose subject is gone, and the
  board's counts.
  """
  @type digest :: %{
          new: [row()],
          smaller: [row()],
          more_new: non_neg_integer(),
          more_smaller: non_neg_integer(),
          gone: [String.t()],
          snapshot: snapshot()
        }

  @typedoc "How long untouched makes a thread due for review, and for review again (seconds)."
  @type review_opts :: %{quiet_after: non_neg_integer(), again_after: non_neg_integer()}

  @typedoc """
  A thread in the review: where it is, its state, when it was last
  touched (`since`), how its last run ended (`last_run_status`) and what
  it last said that the board knows: the open question with the owner
  (Blip's wording when it gave one), or the last run's note (`detail`).
  """
  @type review_row :: %{
          thread_id: String.t(),
          title: String.t() | nil,
          project_id: String.t() | nil,
          slug: String.t() | nil,
          project: String.t() | nil,
          state: :quiet | :failed | :waiting,
          since: DateTime.t(),
          last_run_status: String.t() | nil,
          detail: String.t() | nil
        }

  @typedoc "The review (`review/3`): the threads shown, how many more, and `quiet_after`."
  @type review :: %{
          rows: [review_row()],
          more: non_neg_integer(),
          quiet_after: non_neg_integer()
        }

  @typedoc """
  What a firing knows before it reads the items (`firing/1`): whether
  ambient mode is on, whether Blip can reach its model (`thinks?`: signed
  in with plan use, or the scripted model), whether Settings lets
  schedules use the owner's plan, and whether the last one still waits.
  """
  @type firing_facts :: %{
          on?: boolean(),
          thinks?: boolean(),
          allowed?: boolean(),
          queued?: boolean()
        }

  ## The setting

  @doc "The digest intervals the owner can pick, in minutes."
  @spec every_options() :: [pos_integer()]
  def every_options, do: @every_options

  @doc """
  The setting a Save leaves, from the form's params over the stored doc.
  A key missing from `params`, or a value the form can't send, keeps the
  doc's value (and the doc's own missing or odd values read as the
  defaults: off, every #{@default_every} minutes, offset 0):

    * `"ambient"`: `"true"` turns it on, `"false"` off
    * `"ambient_every"`: one of #{inspect(@every_options)} minutes
    * `"utc_offset"`: a whole number of minutes from -720 to 840

  Never an error.
  """
  @spec config(map(), map()) :: config()
  def config(params, doc) do
    params = if is_map(params), do: params, else: %{}
    stored = stored(doc)

    %{
      on?: switch(Map.get(params, "ambient"), stored.on?),
      every_minutes: every(Map.get(params, "ambient_every"), stored.every_minutes),
      offset_minutes: offset(Map.get(params, "utc_offset"), stored.offset_minutes)
    }
  end

  # The doc's setting, with the defaults for what it lacks.
  defp stored(doc) do
    doc = if is_map(doc), do: doc, else: %{}

    %{
      on?: Map.get(doc, "on") == true,
      every_minutes: every(Map.get(doc, "every_minutes"), @default_every),
      offset_minutes: offset(Map.get(doc, "offset_minutes"), 0)
    }
  end

  defp switch(value, _old) when value in ["true", true], do: true
  defp switch(value, _old) when value in ["false", false], do: false
  defp switch(_value, old), do: old

  defp every(value, old) do
    case whole(value) do
      {:ok, minutes} when minutes in @every_options -> minutes
      _other -> old
    end
  end

  defp offset(value, old) do
    case whole(value) do
      {:ok, minutes} when minutes in @offset_range -> minutes
      _other -> old
    end
  end

  defp whole(value) when is_integer(value), do: {:ok, value}

  defp whole(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp whole(_value), do: :error

  @doc """
  What a Save does, from the stored doc, the setting it leaves (`config/2`)
  and which timers are live:

    * turned off: each live timer is retired, and everything pending is
      cleared (`clear?`)
    * turned on: both timers are armed
    * on and still on: the digest timer is replaced when the interval
      changed or it isn't live, the review timer when the offset changed
      or it isn't live; otherwise each is kept

  "Arm" over a timer that is still live retires it first (`:rearm`).
  """
  @spec changes(map(), config(), live()) :: changes()
  def changes(doc, config, live) do
    before = stored(doc)

    %{
      digest: action(before, config, Map.get(live, :digest) == true, :every_minutes),
      review: action(before, config, Map.get(live, :review) == true, :offset_minutes),
      clear?: before.on? and not config.on?,
      turned_on?: config.on? and not before.on?
    }
  end

  defp action(_before, %{on?: false}, true, _field), do: :retire
  defp action(_before, %{on?: false}, false, _field), do: :keep

  defp action(before, config, live?, field) do
    cond do
      not live? -> :arm
      not before.on? or Map.fetch!(before, field) != Map.fetch!(config, field) -> :rearm
      true -> :keep
    end
  end

  ## The timers

  @doc """
  The next time a timer fires after its firing for `at`: the first time
  after `now` on the grid of `every` from `at`. A hub that was down past
  several slots fires once when it comes back, then keeps to the grid
  (`Photon.Schedules.Rules.next_after/3`'s rule).
  """
  @spec next_firing(ms(), pos_integer(), ms()) :: ms()
  def next_firing(at, every, now)
      when is_integer(at) and is_integer(every) and every > 0 and is_integer(now) do
    missed = div(max(now - at, 0), every)
    at + (missed + 1) * every
  end

  @doc """
  The first instant after `now` when it is 09:00 at UTC offset
  `offset_minutes` (the browser's `-getTimezoneOffset()`: minutes ahead
  of UTC).
  """
  @spec next_review(ms(), integer()) :: ms()
  def next_review(now, offset_minutes) when is_integer(now) and is_integer(offset_minutes) do
    offset = offset_minutes * 60_000
    local = now + offset
    nine = Integer.floor_div(local, @day_ms) * @day_ms + @review_hour_ms
    local_next = if nine > local, do: nine, else: nine + @day_ms
    local_next - offset
  end

  ## A firing

  @doc """
  Whether a firing goes ahead, in order: ambient mode off is `"off"`;
  Blip unable to reach its model (signed out of ChatGPT, or plan use not
  allowed) is `"skipped_model"`, since its run could only fail; no
  consent to use the owner's plan is `"skipped_consent"`; the last digest
  or review still queued in Blip's inbox is `"skipped_queued"`. Every
  skip leaves the items and the review marks as they are.
  """
  @spec firing(firing_facts()) :: :go | {:skip, String.t()}
  def firing(facts) do
    cond do
      Map.get(facts, :on?) != true -> {:skip, "off"}
      Map.get(facts, :thinks?) != true -> {:skip, "skipped_model"}
      Map.get(facts, :allowed?) != true -> {:skip, "skipped_consent"}
      Map.get(facts, :queued?) == true -> {:skip, "skipped_queued"}
      true -> :go
    end
  end

  ## The digest

  @doc """
  The pending items sorted against the board and the places they name:

    * `"finished"`: new while its thread reads `:unread`, else smaller;
      gone with the thread
    * `"schedule_stopped"`: new while the schedule exists and still has
      the task that failed; gone once it is deleted or saved again
    * `"file_written"`: smaller; gone with the project
    * `"project_created"`, `"purpose_changed"`: smaller; gone with the
      project
    * `"thread_started"`: smaller; gone with the thread
    * `"resolved"`: smaller while the thread is still resolved, else gone
    * anything else: gone

  Items about the same subject fold into the newest: one per thread for
  `"finished"`, `"thread_started"` and `"resolved"`, one per schedule, one
  per project and file for `"file_written"`, one per project for
  `"project_created"` and `"purpose_changed"`. Each group is ordered by
  project name, then time, and cut at #{@new_limit} new and
  #{@smaller_limit} smaller rows with how many more. `gone` has the IDs
  of the items to delete without reporting; folded items aren't in it,
  and go with the digest that carries their subject.
  """
  @spec digest([item()], [entry()], places()) :: digest()
  def digest(items, board, places) do
    lookup = lookup(board, places)

    {rows, gone} =
      items
      |> Enum.map(&{&1, sort(&1, lookup)})
      |> Enum.reduce({%{}, []}, &keep_newest/2)

    {new, smaller} = rows |> Map.values() |> Enum.split_with(& &1.new?)
    {new, more_new} = new |> in_order() |> cut(@new_limit)
    {smaller, more_smaller} = smaller |> in_order() |> cut(@smaller_limit)

    %{
      new: new,
      smaller: smaller,
      more_new: more_new,
      more_smaller: more_smaller,
      gone: Enum.reverse(gone),
      snapshot: snapshot(board)
    }
  end

  # The board's threads by ID, the projects by ID and the prompts.
  defp lookup(board, places) do
    %{
      threads: Map.new(board, &{entry_id(&1), &1}),
      projects: projects(Map.get(places, :projects, [])),
      prompts: Map.get(places, :prompts, %{}),
      tasks: Map.get(places, :tasks, %{})
    }
  end

  defp entry_id(entry), do: Map.get(entry, :id) || get_in_thread(entry, :id)

  defp get_in_thread(entry, field) do
    case Map.get(entry, :thread) do
      thread when is_map(thread) -> Map.get(thread, field)
      _none -> nil
    end
  end

  defp projects(projects) when is_list(projects),
    do: Map.new(projects, &{Map.get(&1, :id), &1})

  defp projects(_projects), do: %{}

  # Each item is folded into its subject's newest row, or listed as gone.
  defp keep_newest({item, :gone}, {rows, gone}), do: {rows, [Map.get(item, :id) | gone]}

  defp keep_newest({_item, {subject, row}}, {rows, gone}) do
    rows = Map.update(rows, subject, row, &if(newer?(row.at, &1.at), do: row, else: &1))
    {rows, gone}
  end

  # A later item replaces an earlier one; with the same time, the later
  # item in the list (they come oldest first) wins.
  defp newer?(%DateTime{} = at, %DateTime{} = old), do: DateTime.compare(at, old) != :lt
  defp newer?(_at, _old), do: true

  # An item's subject and row, or :gone.
  defp sort(item, lookup) do
    case Map.get(item, :kind) do
      "finished" -> thread_row(item, lookup, &(&1.state == :unread))
      "thread_started" -> thread_row(item, lookup, fn _entry -> false end)
      "resolved" -> resolved_row(item, lookup)
      "schedule_stopped" -> schedule_row(item, lookup)
      "file_written" -> file_row(item, lookup)
      kind when kind in ["project_created", "purpose_changed"] -> project_row(item, lookup)
      _other -> :gone
    end
  end

  defp thread_row(item, lookup, new?) do
    case Map.get(lookup.threads, Map.get(item, :thread_id)) do
      nil -> :gone
      entry -> {{item.kind, entry_id(entry)}, row(item, new?.(entry), entry)}
    end
  end

  defp resolved_row(item, lookup) do
    case Map.get(lookup.threads, Map.get(item, :thread_id)) do
      nil ->
        :gone

      entry ->
        if get_in_thread(entry, :resolved_at),
          do: {{"resolved", entry_id(entry)}, row(item, false, entry)},
          else: :gone
    end
  end

  defp schedule_row(item, lookup) do
    schedule_id = Map.get(item, :schedule_id)

    with {:ok, prompt} <- Map.fetch(lookup.prompts, schedule_id),
         true <- failed_task_current?(item, lookup.tasks) do
      project = Map.get(lookup.projects, Map.get(item, :project_id))

      row =
        item
        |> row(true, nil)
        |> Map.merge(project_fields(project))
        |> Map.merge(%{schedule_id: schedule_id, prompt: prompt, reason: Map.get(item, :note)})

      {{"schedule_stopped", schedule_id}, row}
    else
      _gone_or_saved_again -> :gone
    end
  end

  # Whether the schedule still has the routine task whose failure the item
  # records. An item that names no task, or a schedule `tasks` doesn't
  # list, counts as current.
  defp failed_task_current?(item, tasks) do
    case {Map.get(item, :task_id), Map.fetch(tasks, Map.get(item, :schedule_id))} do
      {task_id, {:ok, current}} when is_binary(task_id) -> current == task_id
      _unknown -> true
    end
  end

  defp file_row(item, lookup) do
    case Map.get(lookup.projects, Map.get(item, :project_id)) do
      nil ->
        :gone

      project ->
        writer = Map.get(item, :writer)

        row =
          item
          |> row(false, nil)
          |> Map.merge(project_fields(project))
          |> Map.merge(%{
            name: Map.get(item, :name),
            writer: writer,
            writer_title: writer_title(writer, lookup),
            deleted?: Map.get(item, :note) == "deleted"
          })

        {{"file_written", project.id, Map.get(item, :name)}, row}
    end
  end

  defp project_row(item, lookup) do
    case Map.get(lookup.projects, Map.get(item, :project_id)) do
      nil ->
        :gone

      project ->
        {{item.kind, project.id}, item |> row(false, nil) |> Map.merge(project_fields(project))}
    end
  end

  defp writer_title(writer, lookup) do
    case Map.get(lookup.threads, writer) do
      nil -> nil
      entry -> get_in_thread(entry, :title)
    end
  end

  # The row for an item, with its thread and project when `entry` names them.
  defp row(item, new?, entry) do
    base = %{
      kind: Map.get(item, :kind),
      new?: new?,
      at: Map.get(item, :inserted_at),
      thread_id: nil,
      title: nil,
      project_id: nil,
      slug: nil,
      project: nil,
      note: if(item.kind == "finished", do: Map.get(item, :note)),
      schedule_id: nil,
      prompt: nil,
      reason: nil,
      name: nil,
      writer: nil,
      writer_title: nil,
      deleted?: false
    }

    case entry do
      nil ->
        base

      entry ->
        base
        |> Map.merge(%{thread_id: entry_id(entry), title: get_in_thread(entry, :title)})
        |> Map.merge(project_fields(Map.get(entry, :project)))
    end
  end

  defp project_fields(project) when is_map(project) do
    %{
      project_id: Map.get(project, :id),
      slug: Map.get(project, :slug),
      project: Map.get(project, :name)
    }
  end

  defp project_fields(_none), do: %{}

  # By project name (Blip's own schedule first), then the oldest first.
  defp in_order(rows) do
    Enum.sort_by(rows, fn row -> {String.downcase(row.project || ""), time_key(row.at)} end)
  end

  defp time_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp time_key(_unknown), do: 0

  defp cut(rows, limit) do
    {shown, rest} = Enum.split(rows, limit)
    {shown, length(rest)}
  end

  defp snapshot(board) do
    states = Enum.map(board, &Map.get(&1, :state))

    %{
      running: Enum.count(states, &(&1 in [:running, :asking])),
      waiting: Enum.count(states, &(&1 == :waiting)),
      failed: Enum.count(states, &(&1 == :failed))
    }
  end

  ## The review

  @doc """
  The threads the daily review lists, at `now`: those in state `:quiet`,
  `:failed` or `:waiting`, last touched (`last_touch/1`) more than
  `quiet_after` seconds ago, and not in a review since: `reviewed_at` is
  nil, before the last touch, or more than `again_after` seconds ago. The
  oldest touch first, at most #{@review_limit}, with how many more.
  """
  @spec review([entry()], DateTime.t(), review_opts()) :: review()
  def review(board, now, opts) do
    {rows, more} =
      board
      |> Enum.filter(&(Map.get(&1, :state) in @review_states))
      |> Enum.map(&{&1, last_touch(&1)})
      |> Enum.filter(&due?(&1, now, opts))
      |> Enum.sort_by(&time_key(elem(&1, 1)))
      |> Enum.map(&review_row/1)
      |> cut(@review_limit)

    %{rows: rows, more: more, quiet_after: opts.quiet_after}
  end

  defp due?({_entry, nil}, _now, _opts), do: false

  defp due?({entry, touch}, now, opts) do
    DateTime.diff(now, touch, :second) > opts.quiet_after and
      not reviewed_since?(get_in_thread(entry, :reviewed_at), touch, now, opts)
  end

  defp reviewed_since?(%DateTime{} = reviewed, touch, now, opts) do
    DateTime.compare(reviewed, touch) != :lt and
      DateTime.diff(now, reviewed, :second) <= opts.again_after
  end

  defp reviewed_since?(_never, _touch, _now, _opts), do: false

  defp review_row({entry, touch}) do
    project = Map.get(entry, :project) || %{}

    %{
      thread_id: entry_id(entry),
      title: get_in_thread(entry, :title),
      project_id: Map.get(project, :id),
      slug: Map.get(project, :slug),
      project: Map.get(project, :name),
      state: entry.state,
      since: touch,
      last_run_status: get_in_thread(entry, :last_run_status),
      detail: detail(entry)
    }
  end

  # A waiting thread's open question with the owner (Blip's wording when
  # it gave one), else the last run's note.
  defp detail(entry) do
    question =
      entry
      |> Map.get(:questions, [])
      |> Enum.find(&(Map.get(&1, :status) == "with_owner"))

    case question do
      nil -> get_in_thread(entry, :last_run_note)
      question -> Map.get(question, :wording) || Map.get(question, :question)
    end
  end

  @doc """
  When a thread on the board was last touched: the latest of its last
  activity (`Photon.Threads.State.last_activity/1`) and when its open
  questions were passed to the owner; nil when it has none of them.
  """
  @spec last_touch(entry()) :: DateTime.t() | nil
  def last_touch(entry) do
    thread = Map.get(entry, :thread) || %{}
    passed = entry |> Map.get(:questions, []) |> Enum.map(&Map.get(&1, :passed_at))

    [State.last_activity(thread) | passed]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end
end
