defmodule Photon.Skills.Source do
  @moduledoc """
  Where a skill comes from (section 2.4 of
  `docs/plans/step-3-skills-and-schedules.md`), as pure functions: what a
  link is, which GitHub addresses to ask, which folders in a repository
  hold a SKILL.md, and how a SKILL.md and its folder become a candidate
  the install page shows. `Photon.Skills.Fetch` makes the requests and
  hands the answers here; `Photon.Skills.read/1` builds a pasted
  candidate here too.

  Install strips rather than refuses: other files in a skill's folder are
  never downloaded, front matter other than `name` and `description` is
  dropped, and the instructions are kept as written. A candidate's
  `notes` say all of that, and its `files_left_out` lists the paths an
  agent might go looking for. Only what isn't a readable skill is
  refused: a web page, a file that isn't text or is over 256 KB, or a
  SKILL.md without instructions.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Skills.Rules, Photon.Skills.SkillMd]

  alias Photon.Skills.{Rules, SkillMd}

  @skill_file "SKILL.md"
  @most_candidates 30
  @most_named 20

  @not_a_link "Give an https:// link to a SKILL.md, or to a folder on GitHub."
  @no_skill "There's no SKILL.md in that folder."
  @too_big_to_list "That repository is too big to list in one go. Link to the skill's folder " <>
                     "or its SKILL.md instead."
  @not_listed "Couldn't list the folder on GitHub, so other files it may have weren't checked."
  @not_a_listing "GitHub's answer for that folder couldn't be read."

  @typedoc """
  A link on GitHub: the repository, the ref (nil for a repository's root
  link, until its default branch is known), and the path in it, which is
  a folder or a file (`""` is the root folder).
  """
  @type github :: %{
          owner: String.t(),
          repo: String.t(),
          ref: String.t() | nil,
          path: String.t(),
          kind: :folder | :file
        }

  @typedoc "What `classify/1` makes of a link: a place on GitHub, or a file anywhere else."
  @type link :: {:github, github()} | {:web, String.t()}

  @typedoc """
  A folder in a GitHub tree that holds a skill: its path (`""` for the
  root), the file to download (its SKILL.md, or the file a link named),
  and every other file under it, relative to it, sorted.
  """
  @type found :: %{path: String.t(), file: String.t(), files: [String.t()]}

  @typedoc """
  What a candidate's folder adds to its SKILL.md: the folder's path, the
  other files in it (`[]` when unknown, as for a paste), where the
  SKILL.md came from, and notes about the folder itself.
  """
  @type folder :: %{
          path: String.t(),
          files: [String.t()],
          source_url: String.t() | nil,
          notes: [String.t()]
        }

  @typedoc """
  A skill the install page offers (section 2.4). `name` is as found, or
  `Rules.suggest_name/1`'s when that breaks the rule; it, `description`
  and `instructions` are nil when missing. `error` is nil, or why this
  one can't be installed.
  """
  @type candidate :: %{
          origin: String.t(),
          path: String.t(),
          source_url: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          instructions: String.t() | nil,
          notes: [String.t()],
          files_left_out: [String.t()],
          error: String.t() | nil
        }

  @typedoc """
  Why a request failed: an HTTP status, a timeout, a body this refuses
  (`:too_big`, `:web_page`, `:not_text`, `:unreadable` for an API answer
  that isn't JSON), or a transport reason as text.
  """
  @type failure ::
          pos_integer() | :timeout | :too_big | :web_page | :not_text | :unreadable | String.t()

  @typedoc """
  Who answered, for the error message: GitHub's API or GitHub's file
  server (each with the place asked about, as a github.com address
  without its scheme), or any other site.
  """
  @type answerer :: {:api, String.t()} | {:github, String.t()} | :web

  ## Links

  @doc """
  What a link is: a repository's root folder (`https://github.com/o/r`,
  optionally with `.git` or a trailing slash), a folder
  (`.../tree/<ref>/<path>`), a file (`.../blob/<ref>/<path>`, or
  `https://raw.githubusercontent.com/<o>/<r>/<ref>/<path>`), or a file at
  any other address. The ref is the first path segment after `tree` or
  `blob`, so a branch name with a slash in it misses (and the 404 says
  so).
  """
  @spec classify(String.t()) :: {:ok, link()} | {:error, String.t()}
  def classify(url) do
    url = String.trim(url)

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, by_host(String.downcase(host), segments(uri.path), url)}

      _not_a_web_link ->
        {:error, @not_a_link}
    end
  end

  defp segments(nil), do: []

  defp segments(path) do
    path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)
  end

  defp by_host(host, segments, url) when host in ["github.com", "www.github.com"],
    do: on_github(segments) || {:web, url}

  defp by_host("raw.githubusercontent.com", segments, url), do: on_raw(segments) || {:web, url}
  defp by_host(_host, _segments, url), do: {:web, url}

  defp on_github([owner, repo]),
    do: {:github, github(owner, String.replace_suffix(repo, ".git", ""), nil, [], :folder)}

  defp on_github([owner, repo, "tree", ref | path]),
    do: {:github, github(owner, repo, ref, path, :folder)}

  defp on_github([owner, repo, "blob", ref | [_ | _] = path]),
    do: {:github, github(owner, repo, ref, path, :file)}

  defp on_github(_other_page), do: nil

  # The long form of a raw address names the ref after refs/heads/.
  defp on_raw([owner, repo, "refs", heads, ref | [_ | _] = path]) when heads in ["heads", "tags"],
    do: {:github, github(owner, repo, ref, path, :file)}

  defp on_raw([owner, repo, ref | [_ | _] = path]),
    do: {:github, github(owner, repo, ref, path, :file)}

  defp on_raw(_other), do: nil

  defp github(owner, repo, ref, path, kind),
    do: %{owner: owner, repo: repo, ref: ref, path: Enum.join(path, "/"), kind: kind}

  @doc "The GitHub API's address for the repository, which names its default branch."
  @spec repo_url(github()) :: String.t()
  def repo_url(link), do: "https://api.github.com/repos/#{repo_path(link)}"

  @doc "The GitHub API's address for the whole tree at the link's ref, in one call."
  @spec tree_url(github()) :: String.t()
  def tree_url(%{ref: ref} = link) when is_binary(ref),
    do: "https://api.github.com/repos/#{repo_path(link)}/git/trees/#{encode(ref)}?recursive=1"

  @doc "The raw address of `file` (a path in the repository) at the link's ref."
  @spec raw_url(github(), String.t()) :: String.t()
  def raw_url(%{ref: ref} = link, file) when is_binary(ref),
    do: "https://raw.githubusercontent.com/#{repo_path(link)}/#{encode(ref)}/#{encode_path(file)}"

  @doc "The github.com address of `file` at the link's ref, which a fetched skill keeps."
  @spec blob_url(github(), String.t()) :: String.t()
  def blob_url(%{ref: ref} = link, file) when is_binary(ref),
    do: "https://github.com/#{repo_path(link)}/blob/#{encode(ref)}/#{encode_path(file)}"

  @doc """
  Where a link points, as GitHub shows it without the scheme, for
  messages: `github.com/o/r` for a root link without a ref.
  """
  @spec place(github()) :: String.t()
  def place(%{ref: nil} = link), do: "github.com/#{repo_path(link)}"

  def place(%{kind: :file} = link),
    do: link |> blob_url(link.path) |> String.replace_prefix("https://", "")

  def place(%{ref: ref, path: path} = link) do
    "github.com/#{repo_path(link)}/tree/#{encode(ref)}"
    |> join(encode_path(path))
  end

  defp repo_path(link), do: "#{encode(link.owner)}/#{encode(link.repo)}"

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp encode_path(path), do: path |> String.split("/") |> Enum.map_join("/", &encode/1)

  ## Finding skills in a tree

  @doc """
  The skills a link finds in `tree`, GitHub's answer for the whole tree
  (`"tree"` entries with `"path"` and `"type"`, and `"truncated"`):

    * a file link: the file's folder holds the skill, and the file is
      what to download
    * a folder link whose folder has a SKILL.md: that folder
    * any other folder link: every folder under it that has a SKILL.md,
      at any depth, by path, at most 30 (the notice says how many there
      were); a SKILL.md inside another one's folder belongs to it

  Returns the folders and a notice (nil, or the cut to 30), or an error
  for none or a tree too big for GitHub to list.
  """
  @spec skills_in_tree(map(), String.t(), :folder | :file) ::
          {:ok, [found()], String.t() | nil} | {:error, String.t()}
  def skills_in_tree(%{"truncated" => true}, _path, _kind), do: {:error, @too_big_to_list}

  def skills_in_tree(%{"tree" => entries}, path, kind) when is_list(entries) do
    files =
      for %{"type" => "blob", "path" => file} when is_binary(file) <- entries,
          do: file

    in_tree(files, path, kind)
  end

  def skills_in_tree(_answer, _path, _kind), do: {:error, @not_a_listing}

  defp in_tree(files, path, :file), do: {:ok, [found(parent(path), path, files)], nil}

  defp in_tree(files, path, :folder) do
    own = join(path, @skill_file)

    if own in files do
      {:ok, [found(path, own, files)], nil}
    else
      files
      |> Enum.filter(&(under?(&1, path) and basename(&1) == @skill_file))
      |> Enum.map(&parent/1)
      |> Enum.sort()
      |> outermost()
      |> cut(files)
    end
  end

  # Drops each folder that is inside one already kept; sorted input puts
  # a folder before the folders inside it.
  defp outermost(folders) do
    folders
    |> Enum.reduce([], fn folder, kept ->
      if Enum.any?(kept, &under?(folder, &1)), do: kept, else: [folder | kept]
    end)
    |> Enum.reverse()
  end

  defp cut([], _files), do: {:error, @no_skill}

  defp cut(folders, files) do
    count = length(folders)

    notice =
      if count > @most_candidates,
        do:
          "This folder has #{count} skills; showing the first #{@most_candidates}. " <>
            "Link to a deeper folder for the rest."

    found =
      folders
      |> Enum.take(@most_candidates)
      |> Enum.map(&found(&1, join(&1, @skill_file), files))

    {:ok, found, notice}
  end

  defp found(folder, file, files) do
    others =
      files
      |> Enum.filter(&(under?(&1, folder) and &1 != file))
      |> Enum.map(&relative(&1, folder))
      |> Enum.sort()

    %{path: folder, file: file, files: others}
  end

  # Whether `file` is inside `folder` (`""` holds everything).
  defp under?(_file, ""), do: true
  defp under?(file, folder), do: String.starts_with?(file, folder <> "/")

  defp relative(file, ""), do: file
  defp relative(file, folder), do: String.replace_prefix(file, folder <> "/", "")

  defp parent(path) do
    case path |> String.split("/") |> Enum.drop(-1) do
      [] -> ""
      parts -> Enum.join(parts, "/")
    end
  end

  defp basename(path), do: path |> String.split("/") |> List.last()

  defp join("", name), do: name
  defp join(folder, ""), do: folder
  defp join(folder, name), do: folder <> "/" <> name

  ## Folders

  @doc "The folder facts for a skill `skills_in_tree/3` found behind a GitHub link."
  @spec folder(github(), found()) :: folder()
  def folder(link, found),
    do: %{path: found.path, files: found.files, source_url: blob_url(link, found.file), notes: []}

  @doc """
  The folder facts for a GitHub file link whose folder couldn't be listed:
  no other files known, and a note saying they weren't checked.
  """
  @spec unlisted(github()) :: folder()
  def unlisted(link),
    do: %{
      path: parent(link.path),
      files: [],
      source_url: blob_url(link, link.path),
      notes: [@not_listed]
    }

  @doc "The folder facts for a file at any other address."
  @spec web(String.t()) :: folder()
  def web(url), do: %{path: "", files: [], source_url: url, notes: []}

  @doc "The folder facts for a pasted SKILL.md: no folder, no link."
  @spec pasted() :: folder()
  def pasted, do: %{path: "", files: [], source_url: nil, notes: []}

  ## Candidates

  @doc """
  A candidate from its `origin` (`"pasted"` or `"fetched"`), its folder's
  facts, and the SKILL.md's text or the message for why it couldn't be
  had. A text that doesn't parse gives a candidate with the parser's
  message as its error.

  `files_left_out` is what an agent might look for: the files the
  instructions mention first, then the folder's other files,
  deduplicated, at most 20. With no folder listing, the mentions are
  `Rules.mentions/2`'s guesses from the text alone.
  """
  @spec candidate(String.t(), folder(), {:ok, String.t()} | {:error, String.t()}) ::
          candidate()
  def candidate(origin, folder, {:ok, text}) do
    case SkillMd.parse(text) do
      {:ok, parsed} ->
        mentioned = Rules.mentions(parsed.instructions, folder.files)

        %{
          base(origin, folder)
          | name: name(parsed.name),
            description: parsed.description,
            instructions: parsed.instructions,
            notes: notes(folder, parsed, mentioned),
            files_left_out: Enum.take(Enum.uniq(mentioned ++ folder.files), @most_named)
        }

      {:error, message} ->
        candidate(origin, folder, {:error, message})
    end
  end

  def candidate(origin, folder, {:error, message}) do
    name = if folder.path == "", do: nil, else: Rules.suggest_name(basename(folder.path))
    %{base(origin, folder) | name: name, notes: folder.notes, error: message}
  end

  defp base(origin, folder) do
    %{
      origin: origin,
      path: folder.path,
      source_url: folder.source_url,
      name: nil,
      description: nil,
      instructions: nil,
      notes: [],
      files_left_out: [],
      error: nil
    }
  end

  defp name(nil), do: nil

  defp name(found) do
    case Rules.name(found) do
      {:ok, name} -> name
      {:error, _message} -> Rules.suggest_name(found)
    end
  end

  @doc """
  What install says it left out, for the preview and the skill's
  `install_notes`, in this order: the folder's other files (20 named,
  then how many more), the front matter it ignored, the files the
  instructions mention that weren't installed (`mentioned`, from
  `Rules.mentions/2`), a name it changed and why, then the folder's own
  notes.
  """
  @spec notes(folder(), SkillMd.parsed(), [String.t()]) :: [String.t()]
  def notes(folder, parsed, mentioned) do
    Enum.reject(
      [
        left_out_note(folder.files),
        ignored_note(parsed.ignored),
        mentions_note(mentioned),
        renamed_note(parsed.name)
      ],
      &is_nil/1
    ) ++ folder.notes
  end

  defp left_out_note([]), do: nil

  defp left_out_note(files),
    do: "Left out: #{some(files, ", ")}. Photon skills are instructions only."

  defp ignored_note([]), do: nil
  defp ignored_note(keys), do: "Ignored front matter: #{Enum.join(keys, ", ")}."

  defp mentions_note([]), do: nil

  defp mentions_note([file]),
    do: "The instructions mention #{file}, which wasn't installed."

  defp mentions_note(files),
    do: "The instructions mention #{some(files, " and ")}, which weren't installed."

  # Up to 20 names, then how many more: "a, b and c", or "a, b, ... and
  # 14 more". `last` joins the last two of a short list.
  defp some(names, last) do
    {named, rest} = Enum.split(names, @most_named)

    case {named, length(rest)} do
      {named, 0} ->
        {init, [final]} = Enum.split(named, -1)
        if init == [], do: final, else: Enum.join(init, ", ") <> last <> final

      {named, more} ->
        Enum.join(named, ", ") <> ", and #{more} more"
    end
  end

  defp renamed_note(nil), do: nil

  defp renamed_note(found) do
    case Rules.name(found) do
      {:ok, _name} ->
        nil

      {:error, message} ->
        ~s(Renamed from "#{found}" to #{Rules.suggest_name(found)}: #{why(message)})
    end
  end

  defp why("Keep the name to 64" <> _), do: "names are at most 64 characters."
  defp why("That name is taken by the app" <> _), do: "the app uses that name."
  defp why(_format), do: "names use lowercase letters, digits and hyphens."

  @doc """
  The answer for the install page: the candidates and the notice, or,
  when a link found a single skill that can't be installed, its error,
  so the page shows it under the field instead of a list of one.
  """
  @spec result([candidate()], String.t() | nil) ::
          {:ok, [candidate()], String.t() | nil} | {:error, String.t()}
  def result([%{error: message}], _notice) when is_binary(message), do: {:error, message}
  def result(candidates, notice), do: {:ok, candidates, notice}

  ## Answers

  @doc """
  A downloaded file's body, as the text of a SKILL.md, or why not: a web
  page (an HTML content type, or a body starting with `<!DOCTYPE` or
  `<html`), or not text (not UTF-8, or with a NUL byte). `content_types`
  are the response's `content-type` values.
  """
  @spec text(binary(), [String.t()]) :: {:ok, String.t()} | {:error, :web_page | :not_text}
  def text(body, content_types) do
    cond do
      web_page?(body, content_types) -> {:error, :web_page}
      not String.valid?(body) or String.contains?(body, <<0>>) -> {:error, :not_text}
      true -> {:ok, body}
    end
  end

  defp web_page?(body, content_types) do
    html_type? = Enum.any?(content_types, &String.starts_with?(String.downcase(&1), "text/html"))

    # Bytes, not characters: the body may not be text at all.
    start = binary_part(body, 0, min(byte_size(body), 256))
    html_type? or Regex.match?(~r/\A(?:\xEF\xBB\xBF)?\s*<(?:!doctype|html)/i, start)
  end

  @doc "What to tell the owner when a request failed: what happened and what to do."
  @spec error_message(failure(), answerer()) :: String.t()
  def error_message(404, {_github, place}),
    do:
      "GitHub says there's nothing at #{place}. If the branch name has a slash in it, " <>
        "link to the SKILL.md's raw address instead."

  def error_message(404, :web), do: "Nothing at that address (404)."

  def error_message(status, {:api, _place}) when status in [403, 429],
    do:
      "GitHub's limit for requests without a sign-in was reached. Try again within the hour, " <>
        "or paste the SKILL.md."

  def error_message(:too_big, {:api, _place}), do: @too_big_to_list
  def error_message(:unreadable, _answerer), do: "GitHub's answer couldn't be read."
  def error_message(:timeout, _answerer), do: "The download didn't finish in 15 seconds."
  def error_message(:too_big, _answerer), do: "That file is over 256 KB, too big for a skill."

  def error_message(:web_page, _answerer),
    do:
      "That link is a web page, not a SKILL.md. Link to the file on GitHub, " <>
        "or to its raw address."

  def error_message(:not_text, _answerer), do: "That file isn't text."

  def error_message(status, _answerer) when is_integer(status),
    do: "The download failed: HTTP #{status}."

  def error_message(reason, _answerer), do: "The download failed: #{reason}."
end
