defmodule Photon.Projects.Rules do
  @moduledoc """
  The rules for projects and their context files, as pure functions.
  `Photon.Projects` reads what it needs inside a Store commit, asks these
  what to do, and applies the answer in the same commit. IDs and times are
  minted there, never here.

  Errors are messages that say what to do, ready to show a user or hand a
  thread's model: a map of field to message for form input
  (`project/2`), a plain message for file names, content and edits.
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [Photon.Projects.Project, Photon.Projects.ContextFile, Photon.Text]

  alias Photon.Text

  alias Photon.Projects.{ContextFile, Project}

  @purpose_limit 4_000
  @name_limit 60
  @derived_name_limit 40
  @slug_limit 40
  @slug_cut_back_after 20
  @reserved_slugs ~w(new)
  @file_name_limit 64
  @content_limit 100_000

  @typedoc "A project's fields as `project/2` checked them."
  @type project_attrs :: %{name: String.t(), purpose: String.t()}

  @typedoc "Form errors: each field's message."
  @type field_errors :: %{optional(:name | :purpose) => String.t()}

  ## Projects

  @doc """
  A context-file tool parameter both agents' tools share, for
  `Photon.Durable.ToolSchema`: `:name` (a file to read), `:new_name` (a file
  to write, with the naming rules), `:content`, `:old_text` or `:new_text`.
  """
  @spec file_field(:name | :new_name | :content | :old_text | :new_text) :: {:string, String.t()}
  def file_field(:name), do: {:string, "The file's name, like notes.md."}

  def file_field(:new_name),
    do:
      {:string,
       ~s(The file's name: letters, digits, ".", "_" and "-", like notes.md. ) <>
         "Files are flat, with no folders."}

  def file_field(:content),
    do: {:string, "The whole file, in Markdown; at most 100,000 characters."}

  def file_field(:old_text),
    do: {:string, "The passage to replace, exactly as it is in the file."}

  def file_field(:new_text), do: {:string, "What replaces it; empty to delete the passage."}

  @doc """
  Checks a project's `params` (atom or string keys `name` and `purpose`)
  against `current`, the project being edited, or nil for a new one. A
  field missing from `params` keeps its current value. Both are trimmed,
  the name's inner whitespace collapsed; a blank name is made from the
  purpose (`name_from/1`).
  """
  @spec project(map(), Project.t() | nil) :: {:ok, project_attrs()} | {:error, field_errors()}
  def project(params, current) do
    purpose = params |> field(:purpose, current) |> String.trim()
    name = params |> field(:name, current) |> collapse()

    errors =
      Map.reject(%{purpose: purpose_error(purpose), name: name_error(name)}, &is_nil(elem(&1, 1)))

    cond do
      errors != %{} -> {:error, errors}
      name == "" -> {:ok, %{name: name_from(purpose), purpose: purpose}}
      true -> {:ok, %{name: name, purpose: purpose}}
    end
  end

  defp field(params, key, current) do
    value =
      case Map.fetch(params, key) do
        {:ok, value} -> value
        :error -> Map.get(params, Atom.to_string(key), current && Map.fetch!(current, key))
      end

    if is_binary(value), do: value, else: ""
  end

  defp purpose_error(""), do: "Say what the project is for."

  defp purpose_error(purpose) do
    if String.length(purpose) > @purpose_limit,
      do: "Keep the purpose under 4,000 characters, and put the rest in a context file."
  end

  defp name_error(name) do
    if String.length(name) > @name_limit, do: "Keep the name to 60 characters or fewer."
  end

  @doc """
  A name made from a purpose: its first line, up to the end of its first
  sentence, cut to at most 40 characters at a word boundary, with trailing
  punctuation dropped. "Untitled project" if nothing is left.
  """
  @spec name_from(String.t()) :: String.t()
  def name_from(purpose) do
    name =
      purpose
      |> String.trim()
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.split(~r/(?<=[.?!])\s/u, parts: 2)
      |> hd()
      |> collapse()
      |> cut_at_word(@derived_name_limit)
      |> String.replace(~r/[\s.,;:!?…\-–—]+$/u, "")

    if name == "", do: "Untitled project", else: name
  end

  defp collapse(text), do: text |> String.split() |> Enum.join(" ")

  # At most `limit` characters, ending at a word boundary when there is one.
  defp cut_at_word(text, limit) do
    if String.length(text) <= limit do
      text
    else
      head = String.slice(text, 0, limit + 1)

      case Regex.run(~r/^(.*\S)\s/u, head) do
        [_, cut] -> String.slice(cut, 0, limit)
        nil -> String.slice(text, 0, limit)
      end
    end
  end

  ## Slugs

  @doc """
  The slug for a project called `name`: one path segment of `[a-z0-9-]`, at
  most 40 characters (cut back to a hyphen past character 20 when the cut
  splits a word), `project` when nothing is left, and never a reserved
  route segment (`new` becomes `new-project`).
  """
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    slug =
      name
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> cut_slug()

    cond do
      slug == "" -> "project"
      slug in @reserved_slugs -> slug <> "-project"
      true -> slug
    end
  end

  # Slugs are ASCII, so bytes are characters here.
  defp cut_slug(slug) when byte_size(slug) <= @slug_limit, do: slug

  defp cut_slug(slug) do
    cut = binary_part(slug, 0, @slug_limit)
    split_word? = binary_part(slug, @slug_limit, 1) != "-"

    cut =
      case List.last(:binary.matches(cut, "-")) do
        {at, 1} when split_word? and at >= @slug_cut_back_after -> binary_part(cut, 0, at)
        _no_hyphen_to_cut_back_to -> cut
      end

    String.trim_trailing(cut, "-")
  end

  @doc """
  `base`, or `base` with `-2`, `-3` and so on appended, whichever comes
  first that isn't in `taken`.
  """
  @spec unique_slug(String.t(), Enumerable.t(String.t())) :: String.t()
  def unique_slug(base, taken) do
    taken = MapSet.new(taken)

    if MapSet.member?(taken, base) do
      2
      |> Stream.iterate(&(&1 + 1))
      |> Stream.map(&"#{base}-#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, &1)))
    else
      base
    end
  end

  ## Context files

  @doc """
  A context file's name as stored: trimmed, with `.md` appended if it
  doesn't end in `.md` (in any case). It must then be 1 to 64 letters,
  digits, `.`, `_` and `-`, start with a letter or digit, and contain no
  `..`; files are flat, with no folders.
  """
  @spec file_name(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def file_name(name) do
    name = with_extension(name)

    if String.length(name) <= @file_name_limit and
         Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, name) and
         not String.contains?(name, "..") do
      {:ok, name}
    else
      {:error, ~s(A file name uses letters, digits, ".", "_" and "-", like "notes.md".)}
    end
  end

  @doc """
  The key a file is found by: its name as `file_name/1` would store it,
  downcased, so lookups ignore case and a missing `.md`.
  """
  @spec key(String.t()) :: String.t()
  def key(name), do: name |> with_extension() |> String.downcase()

  defp with_extension(name) do
    name = String.trim(name)
    if String.ends_with?(String.downcase(name), ".md"), do: name, else: name <> ".md"
  end

  @doc "Whether `content` fits in the file `name`: at most 100,000 characters (code points)."
  @spec content(String.t(), String.t()) :: :ok | {:error, String.t()}
  # Any text of at most the limit in bytes fits, without counting.
  def content(_name, content) when byte_size(content) <= @content_limit, do: :ok

  def content(name, content) do
    case content |> String.to_charlist() |> length() do
      n when n <= @content_limit ->
        :ok

      n ->
        {:error,
         "#{name} would be #{Text.count(n)} characters; the limit is #{Text.count(@content_limit)}. " <>
           "Split it into more than one file."}
    end
  end

  @doc """
  Whether a save from the user's editor may go ahead, given the file as it
  is (or nil) and the version the editor loaded (nil for a new file):

    * `:ok`: the versions match, or both are nil; also when the file was
      deleted since the editor loaded it, so saving creates it again
    * `:stale`: the file changed since the editor loaded it
    * `:exists`: a new file's name is taken
  """
  @spec save_check(ContextFile.t() | nil, pos_integer() | nil) :: :ok | :stale | :exists
  def save_check(nil, _expected_version), do: :ok
  def save_check(%ContextFile{}, nil), do: :exists
  def save_check(%ContextFile{version: version}, version), do: :ok
  def save_check(%ContextFile{}, _other_version), do: :stale

  @doc """
  Replaces `old_text` with `new_text` in the content of file `name`, when
  `old_text` occurs exactly once; otherwise a message saying it wasn't
  found, or how many times it was and that more of the passage is needed.
  """
  @spec edit(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def edit(_name, _content, "", _new_text),
    do: {:error, "old_text is empty; give the passage to replace."}

  def edit(name, content, old_text, new_text) do
    case occurrences(content, old_text, 0, []) do
      [at] ->
        length = byte_size(old_text)
        rest = byte_size(content) - at - length
        {:ok, binary_part(content, 0, at) <> new_text <> binary_part(content, at + length, rest)}

      [] ->
        {:error, "old_text wasn't found in #{name}."}

      matches ->
        {:error,
         "old_text appears #{length(matches)} times in #{name}; give more of the passage."}
    end
  end

  # Where `old_text` starts in `content`, overlapping occurrences included
  # (`:binary.matches/2` skips those, so "abab" in "ababab" would count once).
  defp occurrences(content, old_text, from, found) do
    case :binary.match(content, old_text, scope: {from, byte_size(content) - from}) do
      {at, _length} -> occurrences(content, old_text, at + 1, [at | found])
      :nomatch -> Enum.reverse(found)
    end
  end
end
