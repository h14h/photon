defmodule Photon.Projects do
  @moduledoc """
  Projects and their context files (section 2 of
  `docs/plans/step-2-projects-and-threads.md`).

  A project is a context for any body of work, not only code: a purpose,
  the only required field, and a name, made from the purpose when left
  blank. Nothing else prescribes how it is run. Its context files are
  freeform Markdown notes kept on the hub, which the user edits on the
  project's pages and the project's threads read and write with tools.

  Each project has a slug, made from its name when the project is created
  and never changed after. It names the project's folder on every machine
  (`<workspace>/<slug>`), and commands in its threads, and anything the user
  set up there by hand, depend on that path; so a rename leaves it alone. A
  slug is one path segment of `[a-z0-9-]`, so it can't climb out of the
  workspace. Two projects with one name get `garden` and `garden-2`: the
  taken slugs are read inside the commit that inserts the project, and the
  unique index backs that up.

  Every write is a `Photon.Durable.commit/1`, as `Photon.Machines` does it:
  SQLite has one writer, and a thread's file write has to land in the same
  commit as the tool result that reports it. Each write reads what it needs
  inside the commit, asks `Photon.Projects.Rules` (rule 64: input is checked
  once, here), applies the answer and announces it with
  `Photon.Durable.Tx.announce/3`, so a page hears of a change only once it
  is stored, and a commit that rolls back announces nothing:

    * `"projects"` (`subscribe/0`): `{:projects_changed, project_id}` when a
      project is created or edited, or a thread is started in it or sent a
      message (`threads_changed_tx/2`)
    * `"project:" <> id` (`subscribe_files/1`):
      `{:project_files_changed, project_id, key}` when a context file is
      created, written, edited or deleted, by the user, a thread or Blip

  `write_file_tx/5` and `edit_file_tx/6` are for the file tools of
  threads and of Blip, inside the commit that records the tool's result:
  they check the name and content themselves and return `{:error,
  message}` for the model, worded for the writer (a thread's ID or
  `"blip"`), so the tools check nothing.

  There is no process here: the rows hold the state and the Store's commit
  line orders the writes.
  """

  use Boundary,
    deps: [Photon.Durable, Photon.Events, Photon.Repo, PhotonCore, Ecto],
    exports: [Project, ContextFile]

  import Ecto.Query

  alias Photon.{Durable, Events, Repo}
  alias Photon.Durable.Tx
  alias Photon.Projects.{ContextFile, Project, Rules}

  @topic "projects"
  @owner "owner"
  @blip "blip"

  @typedoc "Form errors: each field's message, e.g. `%{purpose: \"Say what the project is for.\"}`."
  @type field_errors :: %{optional(:name | :purpose | :content) => String.t()}

  @typedoc "Why a save from the user's editor didn't happen; see `save_file/4`."
  @type save_error :: :stale | :exists | :not_found | field_errors()

  ## Subscriptions

  @doc "Subscribes to `{:projects_changed, project_id}`."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @doc "Subscribes to `{:project_files_changed, project_id, key}` for one project."
  @spec subscribe_files(String.t()) :: :ok
  def subscribe_files(project_id), do: Events.subscribe(files_topic(project_id))

  defp files_topic(project_id), do: "project:" <> project_id

  ## Projects

  @doc "Every project, by name."
  @spec list() :: [Project.t()]
  def list do
    Project
    |> order_by([p], asc: fragment("lower(?)", p.name), asc: p.id)
    |> Repo.all()
  end

  @doc "The project with ID `id`, or nil."
  @spec get(String.t()) :: Project.t() | nil
  def get(id), do: Repo.get(Project, id)

  @doc "The project whose slug is `slug`, or nil."
  @spec get_by_slug(String.t()) :: Project.t() | nil
  def get_by_slug(slug), do: Repo.get_by(Project, slug: slug)

  @doc """
  Creates a project from `params` (`purpose`, required, and `name`,
  optional; atom or string keys). Its slug comes from the name, with a
  `-2`, `-3` suffix when another project has it.
  """
  @spec create(map()) :: {:ok, Project.t()} | {:error, field_errors()}
  def create(params) do
    with {:ok, _attrs} <- Rules.project(params, nil),
         do: Durable.commit(&create_tx(&1, params))
  end

  @doc """
  `create/1` inside the caller's commit, for Blip's `start_project` tool,
  which makes the project in the commit that records its result. Errors
  are `create/1`'s and make nothing, so the caller's commit can go on.
  """
  @spec create_tx(Tx.t(), map()) :: {:ok, Project.t()} | {:error, field_errors()}
  def create_tx(tx, params) do
    with {:ok, attrs} <- Rules.project(params, nil),
         do: {:ok, insert_tx(tx, PhotonCore.ID.new("p_"), attrs)}
  end

  defp insert_tx(tx, id, attrs) do
    base = Rules.slug(attrs.name)

    slug = Rules.unique_slug(base, taken(base))
    project = Repo.insert!(struct!(%Project{id: id, slug: slug}, attrs))

    :ok = Tx.announce(tx, @topic, {:projects_changed, id})
    project
  end

  # The slugs that `base` or a suffixed `base` would collide with.
  defp taken(base) do
    Project
    |> where([p], p.slug == ^base or like(p.slug, ^"#{base}-%"))
    |> select([p], p.slug)
    |> Repo.all()
  end

  @doc """
  Changes a project's name and purpose from `params`; a field left out
  keeps its value, and a name cleared is made from the purpose again. The
  slug stays.
  """
  @spec update(String.t(), map()) :: {:ok, Project.t()} | {:error, field_errors() | :not_found}
  def update(project_id, params) do
    Durable.commit(fn tx ->
      with %Project{} = project <- get(project_id) || {:error, :not_found},
           {:ok, attrs} <- Rules.project(params, project) do
        project = project |> Ecto.Changeset.change(attrs) |> Repo.update!()
        :ok = Tx.announce(tx, @topic, {:projects_changed, project.id})
        {:ok, project}
      end
    end)
  end

  @doc """
  Inside a commit that started a thread in project `project_id` or sent
  one a message: announces `{:projects_changed, project_id}`, since the
  project's list of threads, ordered by their last activity, changed.
  `Photon.Threads` calls it.
  """
  @spec threads_changed_tx(Tx.t(), String.t()) :: :ok
  def threads_changed_tx(tx, project_id),
    do: Tx.announce(tx, @topic, {:projects_changed, project_id})

  ## Context files, for the user

  @doc "A project's context files, most recently changed first."
  @spec list_files(String.t()) :: [ContextFile.t()]
  def list_files(project_id) do
    ContextFile
    |> where([f], f.project_id == ^project_id)
    |> order_by([f], desc: f.updated_at, asc: f.key)
    |> Repo.all()
  end

  @doc "How many context files each project has, by project ID; a project with none is left out."
  @spec file_counts() :: %{optional(String.t()) => pos_integer()}
  def file_counts do
    ContextFile
    |> group_by([f], f.project_id)
    |> select([f], {f.project_id, count(f.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  A project's context file called `name`, or nil. Case doesn't matter, and
  neither does a missing `.md`: `Notes` finds `notes.md`.
  """
  @spec get_file(String.t(), String.t()) :: ContextFile.t() | nil
  def get_file(project_id, name),
    do: Repo.get_by(ContextFile, project_id: project_id, key: Rules.key(name))

  @doc """
  Creates a context file from the user's form: `name` and `content` (atom
  or string keys). `{:error, :exists}` when the project has a file by that
  name; see `save_file/4` for the rest.
  """
  @spec create_file(String.t(), map()) :: {:ok, ContextFile.t()} | {:error, save_error()}
  def create_file(project_id, params) do
    save_file(project_id, param(params, :name), param(params, :content), nil)
  end

  defp param(params, key) do
    case Map.get(params, key, Map.get(params, Atom.to_string(key))) do
      value when is_binary(value) -> value
      _missing -> ""
    end
  end

  @doc """
  Saves a context file from the user's editor, given the `version` the
  editor loaded, or nil for a new file. Errors:

    * `:stale`: the file changed since the editor loaded it
    * `:exists`: a new file's name is taken
    * `:not_found`: the project doesn't exist
    * `%{name: message}` or `%{content: message}`: the name or content
      breaks a rule

  A file deleted since the editor loaded it is created again.
  """
  @spec save_file(String.t(), String.t(), String.t(), pos_integer() | nil) ::
          {:ok, ContextFile.t()} | {:error, save_error()}
  def save_file(project_id, name, content, version) do
    with {:name, {:ok, name}} <- {:name, Rules.file_name(name)},
         {:content, :ok} <- {:content, Rules.content(name, content)} do
      Durable.commit(&save_tx(&1, project_id, name, content, version))
    else
      {field, {:error, message}} -> {:error, %{field => message}}
    end
  end

  defp save_tx(tx, project_id, name, content, version) do
    current = get_file(project_id, name)

    with :ok <- project_exists(project_id),
         :ok <- Rules.save_check(current, version) do
      {:ok, put_file(tx, current || new_file(project_id, name), content, @owner)}
    else
      error -> {:error, error}
    end
  end

  defp project_exists(project_id),
    do: if(Repo.exists?(where(Project, [p], p.id == ^project_id)), do: :ok, else: :not_found)

  @doc "Deletes a project's context file called `name`."
  @spec delete_file(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_file(project_id, name) do
    Durable.commit(fn tx ->
      case get_file(project_id, name) do
        %ContextFile{} = file ->
          _deleted = Repo.delete!(file)

          :ok =
            Tx.announce(
              tx,
              files_topic(project_id),
              {:project_files_changed, project_id, file.key}
            )

        nil ->
          {:error, :not_found}
      end
    end)
  end

  ## Context files, for file tools inside their commit

  @doc """
  Inside the commit that records a file tool's result: creates the file
  `name` or replaces all of it with `content`, with no version check (last
  write wins), as written by `writer`: a thread's ID, or `"blip"`. Checks
  the name, the content and that the project is still there, and returns
  a message for the model when one fails, worded for the writer; a
  refused write changes nothing.
  """
  @spec write_file_tx(Tx.t(), String.t(), String.t(), String.t(), ContextFile.writer()) ::
          {:ok, %{file: ContextFile.t(), created?: boolean()}} | {:error, String.t()}
  def write_file_tx(tx, project_id, name, content, writer) do
    with {:ok, name} <- Rules.file_name(name),
         :ok <- Rules.content(name, content),
         :ok <- project_for(writer, project_id) do
      current = get_file(project_id, name)
      file = put_file(tx, current || new_file(project_id, name), content, writer)
      {:ok, %{file: file, created?: current == nil}}
    end
  end

  @doc """
  Inside the commit that records a file tool's result: replaces
  `old_text`, which must occur exactly once in file `name`, with
  `new_text`, as written by `writer` (a thread's ID, or `"blip"`). Returns
  a message for the model, worded for the writer, when the project or the
  file is missing, the passage isn't found exactly once or the result is
  too long; a refused edit changes nothing.
  """
  @spec edit_file_tx(
          Tx.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          ContextFile.writer()
        ) :: {:ok, ContextFile.t()} | {:error, String.t()}
  # The plan's signature (section 3.3): the tool's three arguments, and
  # the commit, the project and the writer they apply to.
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def edit_file_tx(tx, project_id, name, old_text, new_text, writer) do
    with {:ok, name} <- Rules.file_name(name),
         :ok <- project_for(writer, project_id),
         {:ok, file} <- existing_file(project_id, name),
         {:ok, content} <- Rules.edit(file.name, file.content, old_text, new_text),
         :ok <- Rules.content(file.name, content) do
      {:ok, put_file(tx, file, content, writer)}
    end
  end

  # The project a file tool writes to must still be there. Blip names
  # projects itself, so for Blip it is "that project"; a thread only ever
  # writes to its own.
  defp project_for(writer, project_id) do
    case {project_exists(project_id), writer} do
      {:ok, _writer} -> :ok
      {:not_found, @blip} -> {:error, "That project no longer exists."}
      {:not_found, _thread} -> {:error, "This thread's project no longer exists."}
    end
  end

  defp existing_file(project_id, name) do
    case get_file(project_id, name) do
      %ContextFile{} = file -> {:ok, file}
      nil -> missing_file(project_id, name)
    end
  end

  defp missing_file(project_id, name) do
    names = project_id |> list_files() |> Enum.map_join(", ", & &1.name)

    case names do
      "" -> {:error, "There's no #{name}. This project has no context files yet."}
      names -> {:error, "There's no #{name}. This project's context files are: #{names}."}
    end
  end

  ## Writing

  # A file not stored yet, for `put_file/4` to create.
  defp new_file(project_id, name),
    do: %ContextFile{project_id: project_id, name: name, key: Rules.key(name)}

  # Creates `file` (one from `new_file/2`) or writes over it, as written by
  # `writer`, and announces it.
  defp put_file(tx, %ContextFile{} = file, content, writer) do
    file =
      case file do
        %ContextFile{id: nil} ->
          Repo.insert!(%{
            file
            | id: PhotonCore.ID.new("f_"),
              content: content,
              version: 1,
              updated_by: writer
          })

        %ContextFile{version: version} ->
          file
          |> Ecto.Changeset.change(content: content, version: version + 1, updated_by: writer)
          |> Repo.update!()
      end

    :ok =
      Tx.announce(
        tx,
        files_topic(file.project_id),
        {:project_files_changed, file.project_id, file.key}
      )

    file
  end
end
