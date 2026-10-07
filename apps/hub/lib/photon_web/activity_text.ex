defmodule PhotonWeb.ActivityText do
  @moduledoc """
  The activity page's words and what each row shows (section 10.7 of
  `docs/plans/step-4-blip-as-coordinator.md`): the filter's options and
  how its form reads, whether a new row passes the filter, the empty
  state, which threads and schedules a page of rows names, and a row as
  the page draws it: its summary, its status, who asked
  (`Photon.Activity.Rules.origin_label/2`, with the thread to link when
  the asker is a thread the page found) and where it acted.

  Threads are named by their titles as the page reads them, not as they
  were when the row was written: a thread is named after its first run
  ends, and the owner may rename it. A call on one thread has its summary
  worded again with the thread's title now
  (`Photon.Activity.Rules.thread_summary/4`).

  Pure: the page reads the titles, prompts and projects (the `lookup`)
  and passes them in, and renders times with
  `PhotonWeb.TimeComponents.local_time/1`. A row naming something that
  is gone reads as plain text, or says nothing about where it acted.
  """

  alias Photon.Activity.{Action, Rules}

  @typedoc "The filter: one kind of asker or everyone, and whether only changes show."
  @type filter :: %{origin: Rules.origin() | nil, changes_only: boolean()}

  @typedoc "A project as a row names and links it."
  @type project :: %{name: String.t(), slug: String.t()}

  @typedoc "A thread as a row names and links it: its project's slug is for the link."
  @type thread :: %{id: String.t(), title: String.t(), slug: String.t()}

  @typedoc """
  What the page read for the IDs on a page of rows: threads' titles and
  projects (`Photon.Threads.places/1`), schedules' prompts
  (`Photon.Schedules.prompts/1`) and every project by ID.
  """
  @type lookup :: %{
          places: %{optional(String.t()) => %{title: String.t(), project_id: String.t()}},
          prompts: %{optional(String.t()) => String.t()},
          projects: %{optional(String.t()) => project()}
        }

  @typedoc "How a row's call went: through, failed, stopped, or cut short by a restart."
  @type status :: :ok | :failed | :stopped | :interrupted

  @typedoc """
  A row as the page draws it. `origin` is who asked: the words before the
  link (`lead`), and the thread to link with its title, or nil when the
  whole label is plain text (`lead` then holds it all).
  """
  @type row :: %{
          id: String.t(),
          kind: String.t(),
          tool: String.t() | nil,
          summary: String.t(),
          at: DateTime.t(),
          status: status(),
          origin: %{by: Rules.origin(), lead: String.t(), thread: thread() | nil},
          project: project() | nil,
          thread: thread() | nil
        }

  # The filter's choices, in the order the select lists them.
  @options [
    {"Everyone", ""},
    {"You", "owner"},
    {"Threads", "thread"},
    {"Schedules", "schedule"},
    {"Blip's follow-ups", "follow_up"}
  ]

  @follow_up_on "Blip's follow-up on "

  @doc "The filter with nothing chosen: everyone, every row."
  @spec all() :: filter()
  def all, do: %{origin: nil, changes_only: false}

  @doc ~S"""
  The "Who asked" select's options, as `{label, value}`: Everyone (an
  empty value), You, Threads, Schedules, Blip's follow-ups.
  """
  @spec origin_options() :: [{String.t(), String.t()}]
  def origin_options, do: @options

  @doc """
  The filter the form's params ask for (`"origin"` and `"changes"`). An
  origin the log doesn't know means everyone, and anything but `"true"`
  means every row.
  """
  @spec filter(term()) :: filter()
  def filter(%{} = params) do
    origin = params["origin"]

    %{
      origin: if(origin in Rules.origins(), do: origin),
      changes_only: params["changes"] == "true"
    }
  end

  def filter(_params), do: all()

  @doc "The filter as the form's params, to draw the form with."
  @spec params(filter()) :: %{String.t() => String.t()}
  def params(filter),
    do: %{"origin" => filter.origin || "", "changes" => to_string(filter.changes_only)}

  @doc "The filter as `Photon.Activity.list/1`'s options."
  @spec list_opts(filter()) :: keyword()
  def list_opts(filter), do: [origin: filter.origin, changes_only: filter.changes_only]

  @doc "Whether a row passes the filter, for a row recorded while the page is open."
  @spec matches?(Action.t(), filter()) :: boolean()
  def matches?(%Action{} = action, filter) do
    (is_nil(filter.origin) or action.origin == filter.origin) and
      (not filter.changes_only or action.changes == true)
  end

  @doc """
  The words with no rows: what the page is for when nothing is filtered,
  "Nothing matches." when something is.
  """
  @spec empty(filter()) :: String.t()
  def empty(%{origin: nil, changes_only: false}),
    do: "Nothing yet. When Blip runs a command, starts a thread or answers one, it shows here."

  def empty(_filter), do: "Nothing matches."

  @doc """
  The threads and schedules a page of rows names, for the page to read:
  threads who asked, threads a follow-up was about and threads a call
  acted on; schedules who asked, and those Blip made for itself a
  follow-up came from.
  """
  @spec wanted([Action.t()]) :: %{threads: [String.t()], schedules: [String.t()]}
  def wanted(actions) do
    ids = Enum.flat_map(actions, &[&1.origin_id, &1.thread_id])

    %{
      threads: ids |> Enum.filter(&thread_id?/1) |> Enum.uniq(),
      schedules:
        for(
          %Action{origin: origin, origin_id: id} <- actions,
          origin in ["schedule", "follow_up"] and is_binary(id) and not thread_id?(id),
          uniq: true,
          do: id
        )
    }
  end

  @doc """
  A row as the page draws it, with the names and links `lookup` gives
  (see `t:row/0`). A thread who asked is linked when the page found it
  and its project; a follow-up names and links the thread it was about
  the same way. Where it acted is the row's project and thread, each
  only when the page found it. A call on one thread the page found says the thread's
  title now in its summary.
  """
  @spec row(Action.t(), lookup()) :: row()
  def row(%Action{} = action, lookup) do
    thread = thread(action.thread_id, lookup)
    origin = origin(action, lookup)

    %{
      id: action.id,
      kind: action.kind,
      tool: action.tool,
      summary: summary(action, thread),
      at: action.inserted_at,
      status: status(action.status),
      origin: origin,
      project: project(action.project_id, action.thread_id, lookup),
      thread: thread
    }
  end

  # A call on one thread names the thread by its title now; any other row,
  # or a thread the page didn't find, keeps the summary as written.
  defp summary(%Action{kind: "call"} = action, %{title: title, slug: slug}),
    do: Rules.thread_summary(action.tool, action.status, title, slug) || action.summary

  defp summary(action, _thread), do: action.summary

  @doc ~S"""
  A status mark's words: "Failed", "Stopped", "Cut short by a restart",
  or nil for one that went through.
  """
  @spec status_text(status()) :: String.t() | nil
  def status_text(:failed), do: "Failed"
  def status_text(:stopped), do: "Stopped"
  def status_text(:interrupted), do: "Cut short by a restart"
  def status_text(_ok), do: nil

  defp status("error"), do: :failed
  defp status("aborted"), do: :stopped
  defp status("interrupted"), do: :interrupted
  defp status(_status), do: :ok

  defp thread_id?(id), do: is_binary(id) and String.starts_with?(id, "c_")

  # Who asked: Rules' label, with the thread split out to link when there
  # is one the page can link to.
  defp origin(action, lookup) do
    names = Map.merge(lookup.prompts, Map.new(lookup.places, fn {id, p} -> {id, p.title} end))
    label = Rules.origin_label(action, names)
    linked = if action.origin in ["thread", "follow_up"], do: thread(action.origin_id, lookup)

    {lead, thread} =
      case {action.origin, label, linked} do
        {_by, _label, nil} -> {label, nil}
        {"thread", "A thread", _thread} -> {label, nil}
        {"thread", title, thread} -> {"", %{thread | title: title}}
        {_by, @follow_up_on <> title, thread} -> {@follow_up_on, %{thread | title: title}}
        {_by, _label, _thread} -> {label, nil}
      end

    %{by: action.origin, lead: lead, thread: thread}
  end

  defp thread(id, lookup) do
    with true <- thread_id?(id),
         %{title: title, project_id: project_id} <- Map.get(lookup.places, id),
         %{slug: slug} <- Map.get(lookup.projects, project_id) do
      %{id: id, title: title, slug: slug}
    else
      _missing -> nil
    end
  end

  # The project a row acted in: its own, or else its thread's.
  defp project(project_id, thread_id, lookup) do
    case Map.get(lookup.places, thread_id) do
      %{project_id: thread_project} ->
        Map.get(lookup.projects, project_id) || Map.get(lookup.projects, thread_project)

      nil ->
        Map.get(lookup.projects, project_id)
    end
  end
end
