defmodule Photon.Activity do
  @moduledoc """
  The activity log: everything Blip did, and who asked for it.

  A row (`Photon.Activity.Action`) is a stored fact, written once in the
  commit that stores what it records and never changed (rule 15):

    * every result of a tool call Blip made, whatever ended it (a result,
      a raise, a Stop, a failed task), from the `"assistant"` profile's
      `on_tool_result/4` hook (`kind: "call"`)
    * every answer Blip gave in a run the owner didn't type into (one a
      thread's update or question, or a schedule, started), from its
      `on_settled/3` hook (`kind: "message"`), since the owner didn't
      watch that reply come in

  Who asked is `Photon.Assistant.Origin`'s, worked out by the caller; the
  line the page shows and whether the call changes anything are
  `Photon.Activity.Rules`'. Blip's conversation holds the same calls, but
  reading who asked from it means reading every entry with its output and
  images: this table is the index the activity page lists from.

  `record_tx/2` runs inside the harness's commits, on a Stop or a failed
  task inside the Scheduler's own, so it is total: it takes the call as
  stored, whatever its arguments are, and records less, never raises,
  when something is missing. There is no pruning in this step.

  Every row announces `{:activity_added, id}` on `"activity"`
  (`subscribe/0`) after its commit. There is no process here: the log is
  rows behind this API.
  """

  use Boundary,
    deps: [Photon.Durable, Photon.Events, Photon.Repo, PhotonCore, Ecto],
    exports: [Action, Rules]

  import Ecto.Query

  alias Photon.Activity.{Action, Rules}
  alias Photon.Durable.{Entry, TaskRecord, Tx}
  alias Photon.{Events, Repo}

  @topic "activity"

  @page 50

  @typedoc "Who asked, as `Photon.Assistant.Origin.for_call/3` gives it."
  @type origin :: %{by: String.t(), id: String.t() | nil}

  @typedoc """
  What to record: a tool call's result (the call's tool task and its
  stored `"tool_result"` entry), or a message Blip told the owner (the
  answer entry's ID and its text); each with who asked.
  """
  @type recorded ::
          %{kind: String.t(), task: TaskRecord.t(), entry: Entry.t(), origin: origin()}
          | %{kind: String.t(), entry_id: String.t(), text: String.t(), origin: origin()}

  @typedoc """
  Options for `list/1`:

    * `:limit` - at most this many rows (default 50)
    * `:before` - only rows older than this one (an `Photon.Activity.Action`,
      or its `{inserted_at, id}`), for "Show older"
    * `:origin` - only rows one kind of asker asked for
      (`Photon.Activity.Rules.origins/0`); nil or anything else for all
    * `:changes_only` - only calls that change something
  """
  @type list_opt ::
          {:limit, pos_integer()}
          | {:before, Action.t() | {DateTime.t(), String.t()} | nil}
          | {:origin, String.t() | nil}
          | {:changes_only, boolean()}

  ## Recording

  @doc """
  Records one row inside the caller's commit and announces
  `{:activity_added, id}` once it is stored. For a call, the summary
  comes from the call as stored in its task (`task.input["call"]`), the
  status and the details from its entry, and `project_id` and
  `thread_id` from the details. A second record of the same entry, or
  attributes that name no entry, record nothing. Total: it never
  raises on what it is given.
  """
  @spec record_tx(Tx.t(), recorded() | term()) :: :ok
  def record_tx(tx, %{kind: "call", task: task, entry: %Entry{id: entry_id} = entry} = record)
      when is_binary(entry_id) do
    call = call(task)
    data = if is_map(entry.data), do: entry.data, else: %{}
    details = if is_map(data["details"]), do: data["details"], else: %{}
    status = text(data["status"]) || "error"
    tool = text(call["name"]) || text(data["name"])

    insert_tx(tx, %{
      kind: "call",
      tool: tool,
      summary: Rules.summary(Map.put(call, "name", tool), status, details),
      status: status,
      changes: Rules.changes?(tool),
      origin: Map.get(record, :origin),
      project_id: detail(details, "project_id"),
      thread_id: detail(details, "thread_id"),
      entry_id: entry_id
    })
  end

  def record_tx(tx, %{kind: "message", entry_id: entry_id} = record) when is_binary(entry_id) do
    insert_tx(tx, %{
      kind: "message",
      tool: nil,
      summary: Rules.message_summary(Map.get(record, :text)),
      status: "ok",
      changes: false,
      origin: Map.get(record, :origin),
      project_id: nil,
      thread_id: nil,
      entry_id: entry_id
    })
  end

  def record_tx(_tx, _record), do: :ok

  # The call as the model sent it, from its tool task.
  defp call(%TaskRecord{input: %{"call" => call}}) when is_map(call), do: call
  defp call(_task), do: %{}

  defp detail(details, key), do: text(Map.get(details, key) || Map.get(details, atom(key)))

  defp atom("project_id"), do: :project_id
  defp atom("thread_id"), do: :thread_id

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp insert_tx(tx, fields) do
    recorded = from(a in Action, where: a.entry_id == ^fields.entry_id)

    if Repo.exists?(recorded) do
      :ok
    else
      {by, origin_id} = origin(fields.origin)

      action =
        Repo.insert!(%Action{
          id: PhotonCore.ID.new("a_"),
          kind: fields.kind,
          tool: fields.tool,
          summary: fields.summary,
          status: fields.status,
          changes: fields.changes,
          origin: by,
          origin_id: origin_id,
          project_id: fields.project_id,
          thread_id: fields.thread_id,
          entry_id: fields.entry_id,
          inserted_at: DateTime.utc_now()
        })

      Tx.announce(tx, @topic, {:activity_added, action.id})
    end
  end

  # Who asked, kept to the five kinds the log knows.
  defp origin(%{by: by} = origin) do
    if by in Rules.origins(),
      do: {by, text(Map.get(origin, :id))},
      else: {"unknown", nil}
  end

  defp origin(_origin), do: {"unknown", nil}

  ## Reading

  @doc "Subscribes to `{:activity_added, id}`, sent after a row is recorded."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @doc "The row with ID `id`, or nil."
  @spec get(String.t()) :: Action.t() | nil
  def get(id) when is_binary(id), do: Repo.get(Action, id)
  def get(_id), do: nil

  @doc """
  Rows newest first, with whether there are older ones past them
  (`{actions, more?}`). See `t:list_opt/0` for the options.
  """
  @spec list([list_opt()]) :: {[Action.t()], boolean()}
  def list(opts \\ []) do
    limit = page_size(opts[:limit])

    newest = from(a in Action, order_by: [desc: a.inserted_at, desc: a.id], limit: ^(limit + 1))

    rows =
      newest
      |> before(opts[:before])
      |> by_origin(opts[:origin])
      |> changes_only(opts[:changes_only])
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  defp page_size(limit) when is_integer(limit) and limit > 0, do: limit
  defp page_size(_limit), do: @page

  defp before(query, %Action{inserted_at: at, id: id}), do: before(query, {at, id})

  defp before(query, {%DateTime{} = at, id}) when is_binary(id),
    do: where(query, [a], a.inserted_at < ^at or (a.inserted_at == ^at and a.id < ^id))

  defp before(query, _cursor), do: query

  defp by_origin(query, origin) when is_binary(origin) do
    if origin in Rules.origins(), do: where(query, [a], a.origin == ^origin), else: query
  end

  defp by_origin(query, _origin), do: query

  defp changes_only(query, true), do: where(query, [a], a.changes)
  defp changes_only(query, _all), do: query
end
