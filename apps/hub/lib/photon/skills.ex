defmodule Photon.Skills do
  @moduledoc """
  Skills (section 2 of `docs/plans/step-3-skills-and-schedules.md`):
  instructions an agent loads when a task calls for them. The owner writes
  them in the app or installs them from a SKILL.md; either way a skill is
  only its name, description and Markdown instructions. Nothing else from
  a SKILL.md's folder is kept, and no skill runs anything.

  A skill is on or off per scope. A scope is `:blip` (Blip's own set) or
  `{:project, project_id}` (that project's threads); a new skill is on
  nowhere. Each scope holds at most 30, since an agent's prompt lists
  every enabled skill's name and description on every request. Turning a
  skill on stores one `Photon.Skills.Enablement` row, and turning it off
  deletes it. Room for machines: a later step can add the machines a skill
  is on for to that row, and an argument to `enabled/1`, without
  redesigning either.

  Every write is a `Photon.Durable.commit/1`, as `Photon.Projects` does it:
  it reads what it needs inside the commit, asks `Photon.Skills.Rules`
  (rule 64: input is checked once, here), applies the answer and
  announces `{:skills_changed, skill_id}` on `"skills"` (`subscribe/0`)
  with `Photon.Durable.Tx.announce/3`, so a page hears of a change only
  once it is stored: when a skill is created, installed, saved or deleted,
  or turned on or off anywhere.

  Agents see the skills on for their scope through
  `Photon.Skills.Prompt` (the prompt's Skills section, which both profiles
  build from `enabled/1` on every model request), and load one with
  `load_skill`: Blip's and a thread's tools call `load_tx/3` inside the
  commit that records the call's result, so a load and a toggle are
  ordered by the Store and a load never returns a skill that was already
  off. `Photon.Skills.MockPhrases` are the skill phrasings both scripted
  models share.

  Installing starts from a candidate: `read/1` makes one from a pasted
  SKILL.md, and `fetch/1` downloads them from a link (through
  `Photon.Skills.Fetch`, with `Photon.Skills.Source` deciding what a link
  is and what the answers mean). Neither writes anything; `install/2`
  does, from the preview form and the candidate.

  There is no process here: the rows hold the state and the Store's
  commit line orders the writes. `fetch/1` runs in its caller's process
  (the install page's `start_async` task).
  """

  use Boundary,
    deps: [
      Photon.Durable,
      Photon.Events,
      Photon.Projects,
      Photon.Repo,
      PhotonCore,
      PhotonCore.LLM,
      Ecto,
      Jason,
      Req
    ],
    exports: [Skill, Prompt, MockPhrases]

  import Ecto.Query

  alias Photon.{Durable, Events, Projects, Repo}
  alias Photon.Durable.Tx
  alias Photon.Skills.{Enablement, Fetch, Prompt, Rules, Skill, Source}

  @topic "skills"
  @blip "blip"

  @typedoc "Where a skill can be on: Blip's own set, or a project's."
  @type scope :: :blip | {:project, String.t()}

  @typedoc "Form errors: each field's message, e.g. `%{name: \"There's already ...\"}`."
  @type field_errors :: Rules.field_errors()

  @typedoc "A skill with the scopes it is on in, Blip first; `id` is the skill's."
  @type listed :: %{id: String.t(), skill: Skill.t(), scopes: [scope()]}

  @typedoc """
  What install keeps from the SKILL.md it read (section 2.4): how it
  arrived (`"pasted"` or `"fetched"`), the link for a fetched one, the
  notes the preview showed, and the files left out that an agent might
  look for, and what those were made from (`found`, see
  `Photon.Skills.Source.candidate/0`). The form gives the name,
  description and instructions; these come from the candidate the page
  holds. Other keys are ignored.
  """
  @type candidate :: %{
          required(:origin) => String.t(),
          optional(:source_url) => String.t() | nil,
          optional(:notes) => [String.t()],
          optional(:files_left_out) => [String.t()],
          optional(:found) => Source.found_facts(),
          optional(atom()) => term()
        }

  ## Subscriptions

  @doc "Subscribes to `{:skills_changed, skill_id}`."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  ## Reading

  @doc "Every skill, by name, each with the scopes it is on in."
  @spec list() :: [listed()]
  def list do
    scopes =
      Enablement
      |> scopes_order()
      |> Repo.all()
      |> Enum.group_by(& &1.skill_id, &scope/1)

    Skill
    |> order_by([s], asc: s.name)
    |> Repo.all()
    |> Enum.map(&%{id: &1.id, skill: &1, scopes: blip_first(Map.get(scopes, &1.id, []))})
  end

  @doc "The skill with ID `id`, or nil."
  @spec get(String.t()) :: Skill.t() | nil
  def get(id), do: Repo.get(Skill, id)

  @doc "The skill called `name`, or nil."
  @spec get_by_name(String.t()) :: Skill.t() | nil
  def get_by_name(name), do: Repo.get_by(Skill, name: name)

  @doc """
  The message for `name` (trimmed) when another skill has it, or nil:
  what the install page says of a listed skill or the name typed in its
  preview. Install checks it again in its commit.
  """
  @spec name_taken(String.t() | nil) :: String.t() | nil
  def name_taken(name) when is_binary(name) do
    name = String.trim(name)

    case name != "" and get_by_name(name) do
      %Skill{} -> Rules.name_taken(name).name
      _free -> nil
    end
  end

  def name_taken(_name), do: nil

  @doc """
  The messages the install preview shows under its fields before Install,
  for `params` (`name`, `description`): the rule's message for a name or
  a description left empty, as a SKILL.md without one opens, and a name
  another skill has. Everything else is checked on install.
  """
  @spec preview_errors(map()) :: field_errors()
  def preview_errors(params) do
    blank =
      case Rules.skill(params, nil) do
        {:ok, _attrs} -> %{}
        {:error, errors} -> Map.filter(errors, fn {field, _} -> blank?(params, field) end)
      end

    case name_taken(params["name"]) do
      nil -> blank
      message -> Map.put(blank, :name, message)
    end
  end

  defp blank?(params, field) when field in [:name, :description],
    do: String.trim(params[Atom.to_string(field)] || "") == ""

  defp blank?(_params, _field), do: false

  @doc """
  The skills on in `scope`, by name: what its agents' prompts list and
  what they may load. One query; both profiles run it on every model
  request.
  """
  @spec enabled(scope()) :: [Skill.t()]
  def enabled(scope) do
    column = scope_column(scope)

    Skill
    |> join(:inner, [s], e in Enablement, on: e.skill_id == s.id and e.scope == ^column)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc "The scopes skill `skill_id` is on in: Blip first, then projects in the order they were turned on."
  @spec scopes(String.t()) :: [scope()]
  def scopes(skill_id) do
    Enablement
    |> where([e], e.skill_id == ^skill_id)
    |> scopes_order()
    |> Repo.all()
    |> Enum.map(&scope/1)
    |> blip_first()
  end

  @doc """
  For the `load_skill` tools, inside the commit that records the call's
  result: the skill called `name` (trimmed and downcased) if it is on in
  `scope`, as the tool's result (`Photon.Skills.Prompt.loaded/1`, with the
  skill's name and version and how to load it again in the details), or
  an error that names the skills that are on.
  """
  @spec load_tx(Tx.t(), scope(), String.t()) ::
          {:ok, String.t(), %{String.t() => term()}} | {:error, String.t()}
  def load_tx(_tx, scope, name) do
    name = name |> String.trim() |> String.downcase()
    skills = enabled(scope)

    case Enum.find(skills, &(&1.name == name)) do
      %Skill{} = skill ->
        {:ok, Prompt.loaded(skill),
         %{
           "skill" => skill.name,
           "version" => skill.version,
           "full_output" => Prompt.full_output_hint(skill.name)
         }}

      nil ->
        {:error, Prompt.not_loaded(name, Enum.map(skills, & &1.name))}
    end
  end

  defp scopes_order(query), do: order_by(query, [e], asc: e.inserted_at, asc: e.scope)

  defp blip_first(scopes), do: Enum.sort_by(scopes, &(&1 != :blip))

  ## Candidates to install

  @doc """
  Reads a pasted SKILL.md into a candidate for the install preview
  (section 2.4), with `origin: "pasted"` and notes on what install leaves
  out. Errors are the parser's messages: no front matter, front matter
  that never ends, or no instructions.
  """
  @spec read(String.t()) :: {:ok, Source.candidate()} | {:error, String.t()}
  def read(text) do
    case Source.candidate("pasted", Source.pasted(), {:ok, text}) do
      %{error: nil} = candidate -> {:ok, candidate}
      %{error: message} -> {:error, message}
    end
  end

  @doc """
  Fetches the skills a link points to: a SKILL.md, a skill's folder on
  GitHub, or a GitHub folder or repository holding several (up to 30,
  with a notice when there were more). Each candidate has
  `origin: "fetched"`; one whose download failed carries its `error`.
  A link that finds a single skill it can't read is an error instead.
  Makes HTTP requests, so it runs in a task, never in a LiveView
  callback.
  """
  @spec fetch(String.t()) :: Fetch.fetched()
  def fetch(url) do
    case Source.classify(url) do
      {:ok, {:github, link}} -> Fetch.github(link)
      {:ok, {:web, url}} -> Fetch.web(url)
      {:error, message} -> {:error, message}
    end
  end

  ## Writing skills

  @doc """
  Creates a skill written in the app from `params` (`name`, `description`
  and `instructions`; atom or string keys), on nowhere.
  """
  @spec create(map()) :: {:ok, Skill.t()} | {:error, field_errors()}
  def create(params) do
    with {:ok, attrs} <- Rules.skill(params, nil) do
      insert(Map.merge(attrs, %{origin: "written", files_left_out: []}))
    end
  end

  @doc """
  Installs a skill: the name, description and instructions from the
  preview form's `params`, and how it arrived, its link, its notes and
  the files left out from `candidate` (section 2.4), never from the form.
  The notes and files left out are said again for what was saved
  (`Photon.Skills.Source.saved/3`): a name the owner changed, and only
  the files the saved instructions mention. On nowhere.
  """
  @spec install(map(), candidate()) :: {:ok, Skill.t()} | {:error, field_errors()}
  def install(params, candidate) do
    with {:ok, attrs} <- Rules.skill(params, nil) do
      %{notes: notes, files_left_out: left_out} =
        Source.saved(candidate, attrs.name, attrs.instructions)

      insert(
        Map.merge(attrs, %{
          origin: Map.fetch!(candidate, :origin),
          source_url: Map.get(candidate, :source_url),
          install_notes: if(notes == [], do: nil, else: Enum.join(notes, "\n")),
          files_left_out: left_out
        })
      )
    end
  end

  defp insert(attrs) do
    id = PhotonCore.ID.new("sk_")

    Durable.commit(fn tx ->
      with :ok <- name_free(attrs.name, id) do
        skill = Repo.insert!(struct!(%Skill{id: id, version: 1}, attrs))
        :ok = announce(tx, id)
        {:ok, skill}
      end
    end)
  end

  @doc """
  Saves skill `id` from its page, given the `version` the page loaded.
  `params` are as for `create/1`; a field left out keeps its value. The
  version goes up by one. Errors: `:not_found`, `:stale` (the skill
  changed since the page loaded it), or a field map.
  """
  @spec update(String.t(), map(), pos_integer()) ::
          {:ok, Skill.t()} | {:error, :not_found | :stale | field_errors()}
  def update(id, params, version) do
    Durable.commit(fn tx ->
      with {:ok, skill} <- fetch_skill(id),
           :ok <- not_stale(skill, version),
           {:ok, attrs} <- Rules.skill(params, skill),
           :ok <- name_free(attrs.name, id) do
        skill =
          skill
          |> Ecto.Changeset.change(Map.put(attrs, :version, skill.version + 1))
          |> Repo.update!()

        :ok = announce(tx, id)
        {:ok, skill}
      end
    end)
  end

  defp not_stale(skill, version) do
    case Rules.save_check(skill.version, version) do
      :ok -> :ok
      :stale -> {:error, :stale}
    end
  end

  # Inside a commit, so two saves can't both take a name; the unique index
  # backs this up.
  defp name_free(name, id) do
    taken? = Repo.exists?(where(Skill, [s], s.name == ^name and s.id != ^id))
    if taken?, do: {:error, Rules.name_taken(name)}, else: :ok
  end

  @doc "Deletes skill `id`; the scopes it was on in lose it in the same commit."
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) do
    Durable.commit(fn tx ->
      with {:ok, skill} <- fetch_skill(id) do
        # The enablements go with it (`on_delete: :delete_all`).
        _deleted = Repo.delete!(skill)
        announce(tx, id)
      end
    end)
  end

  ## Turning skills on and off

  @doc """
  Turns skill `skill_id` on in `scope`. Does nothing when it is on
  already. Errors: `:not_found` for the skill, or a message when the
  project doesn't exist or the scope has 30 skills on.
  """
  @spec enable(String.t(), scope()) :: :ok | {:error, :not_found | String.t()}
  def enable(skill_id, scope) do
    column = scope_column(scope)

    Durable.commit(fn tx ->
      with {:ok, _skill} <- fetch_skill(skill_id),
           :ok <- scope_exists(scope),
           false <- on?(skill_id, column),
           :ok <- Rules.enable_check(Repo.aggregate(in_scope(column), :count)) do
        _enablement = Repo.insert!(%Enablement{skill_id: skill_id, scope: column})
        announce(tx, skill_id)
      else
        true -> :ok
        error -> error
      end
    end)
  end

  @doc "Turns skill `skill_id` off in `scope`. Does nothing when it isn't on."
  @spec disable(String.t(), scope()) :: :ok
  def disable(skill_id, scope) do
    column = scope_column(scope)

    Durable.commit(fn tx ->
      deleted =
        column
        |> in_scope()
        |> where([e], e.skill_id == ^skill_id)
        |> Repo.delete_all()

      case deleted do
        {0, _} -> :ok
        {_deleted, _} -> announce(tx, skill_id)
      end
    end)
  end

  defp in_scope(column), do: where(Enablement, [e], e.scope == ^column)

  defp on?(skill_id, column) do
    column
    |> in_scope()
    |> where([e], e.skill_id == ^skill_id)
    |> Repo.exists?()
  end

  defp scope_exists(:blip), do: :ok

  defp scope_exists({:project, project_id}) do
    if Projects.get(project_id), do: :ok, else: {:error, "That project doesn't exist."}
  end

  ## Helpers

  defp fetch_skill(id) do
    case get(id) do
      %Skill{} = skill -> {:ok, skill}
      nil -> {:error, :not_found}
    end
  end

  # Only this module turns a scope into the column's string and back.
  defp scope_column(:blip), do: @blip
  defp scope_column({:project, project_id}) when is_binary(project_id), do: project_id

  defp scope(%Enablement{scope: @blip}), do: :blip
  defp scope(%Enablement{scope: project_id}), do: {:project, project_id}

  defp announce(tx, skill_id), do: Tx.announce(tx, @topic, {:skills_changed, skill_id})
end
