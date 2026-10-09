defmodule PhotonCredo.Docs do
  @moduledoc """
  Checks that the docs name things that exist: local Markdown links and
  their anchors, repo paths in backticks (`apps/hub/mix.exs`), and module,
  function and type names in backticks under Photon's namespaces
  (`Photon.Durable.submit_tx/4`, `PhotonNode.Config.t`). It reads the
  repo's Markdown and the apps' and tools' sources, where those names sit
  in moduledocs, docs and comments.

  A name exists when its module is loaded and has that function, macro,
  type or callback; or, for a bare module name, when the repo's sources
  define it (another app's test support), register it as a process name
  (`name: Photon.PubSub`), or use it as a namespace. A path exists when it
  is in the repo or ignored by git (build output). Test files are checked
  for names only, since their fixtures hold made-up paths.

  `tools/check_docs.exs` runs it from `apps/hub` in the test env, where
  every app's modules are compiled; `mix precommit` there runs that. The
  lookups come in a `t:context/0`, so tests can stub them.
  """

  @typedoc "A file (relative to the repo root), a line, and what's wrong there."
  @type problem :: {String.t(), pos_integer(), String.t()}

  @typedoc """
  The lookups: whether a name exists, whether a repo path exists, and a
  Markdown file's anchors.
  """
  @type context :: %{
          resolve: (String.t() -> :ok | {:error, String.t()}),
          file?: (String.t() -> boolean()),
          anchors: (String.t() -> [String.t()])
        }

  @markdown ["README.md", "ARCHITECTURE.md", "AGENTS.md", "docs/**/*.md", "specs/**/*.md"]
  @sources [
    "apps/*/lib/**/*.{ex,exs}",
    "apps/*/test/**/*.{ex,exs}",
    "apps/*/config/*.exs",
    "apps/*/mix.exs",
    "tools/*.exs",
    "tools/credo_checks/*.exs",
    "tools/credo_checks/lib/**/*.ex"
  ]
  @skip ~r{(^|/)(deps|_build|cover|node_modules)/}

  @code_span ~r/`([^`\n]+)`/
  @link ~r/\[[^\]\n]*\]\(([^)\s]+)\)/
  @name ~r/^(?:PhotonCore|PhotonNode|PhotonWeb|PhotonCredo|Photon)(?:\.[A-Z]\w*)*(?:\.[a-z_]\w*[?!]?(?:\/\d+)?)?$/
  @repo_path ~r{^(?:apps|docs|specs|tools|scripts)/(?!\d+$)[\w./@-]+?(?::\d+(?:-\d+)?)?$}

  @doc "Every problem in the repo at `root`, with the real lookups."
  @spec run(String.t()) :: [problem()]
  def run(root) do
    context = context(root)

    for file <- files(root),
        problem <- check(file, File.read!(Path.join(root, file)), context),
        do: problem
  end

  @doc "The problems in one file's `text`; `file` is relative to the repo root."
  @spec check(String.t(), String.t(), context()) :: [problem()]
  def check(file, text, context) do
    kind = kind(file)

    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      line
      |> line_problems(file, kind, context)
      |> Enum.map(&{file, number, &1})
    end)
  end

  defp kind(file) do
    cond do
      Path.extname(file) == ".md" -> :markdown
      String.ends_with?(file, "_test.exs") -> :test
      true -> :source
    end
  end

  @doc """
  The anchors GitHub gives a Markdown text's headings: lowercased, spaces to
  hyphens, other punctuation dropped, and `-1`, `-2` on repeats.
  """
  @spec anchors(String.t()) :: [String.t()]
  def anchors(text) do
    {slugs, _counts} =
      text
      |> headings()
      |> Enum.map_reduce(%{}, fn heading, counts ->
        slug = slug(heading)
        count = Map.get(counts, slug, 0)
        {if(count == 0, do: slug, else: "#{slug}-#{count}"), Map.put(counts, slug, count + 1)}
      end)

    slugs
  end

  @doc """
  Whether a name in backticks exists: a loaded module, or a loaded module's
  function, macro, type or callback (with its arity, if given). `known` are
  the module names the sources define or register, and their namespaces;
  for one that isn't loaded, only the module name is checked.
  """
  @spec resolve(String.t(), MapSet.t(String.t())) :: :ok | {:error, String.t()}
  def resolve(name, known) do
    case Regex.run(~r/^(.*?)\.([a-z_]\w*[?!]?)(?:\/(\d+))?$/, name) do
      [_all, module, fun] -> resolve_member(module, fun, nil, known)
      [_all, module, fun, arity] -> resolve_member(module, fun, String.to_integer(arity), known)
      nil -> if module(name) || name in known, do: :ok, else: {:error, "no module #{name}"}
    end
  end

  @doc """
  The module names `sources` define (`defmodule`) or register as process
  names (`name: Photon.PubSub`), with every namespace above them.
  """
  @spec known([String.t()]) :: MapSet.t(String.t())
  def known(sources) do
    sources
    |> Enum.flat_map(
      &Regex.scan(
        ~r/(?:defmodule|name:)\s+((?:PhotonCore|PhotonNode|PhotonWeb|PhotonCredo|Photon)[\w.]*)/,
        &1
      )
    )
    |> Enum.flat_map(fn [_match, name] -> namespaces(name) end)
    |> MapSet.new()
  end

  defp namespaces(name) do
    parts = String.split(name, ".")
    for n <- 1..length(parts), do: parts |> Enum.take(n) |> Enum.join(".")
  end

  defp line_problems(line, file, kind, context) do
    spans = for [_span, inner] <- Regex.scan(@code_span, line), do: inner

    links =
      if kind == :markdown,
        do: for([_link, target] <- Regex.scan(@link, line), do: target),
        else: []

    Enum.flat_map(spans, &span_problems(&1, kind, context)) ++
      Enum.flat_map(links, &link_problems(&1, file, context))
  end

  defp span_problems(span, kind, context) do
    cond do
      Regex.match?(@name, span) -> resolved(context.resolve.(span))
      kind != :test and Regex.match?(@repo_path, span) -> path_problems(span, context)
      true -> []
    end
  end

  defp resolved(:ok), do: []
  defp resolved({:error, message}), do: [message]

  defp path_problems(span, context) do
    path = String.replace(span, ~r/:\d+(-\d+)?$/, "")
    if context.file?.(path), do: [], else: ["no file #{path}"]
  end

  defp link_problems(target, file, context) do
    if Regex.match?(~r/^[a-z]+:/, target) do
      []
    else
      [path, anchor] = target |> String.split("#", parts: 2) |> pad()

      linked =
        if path == "", do: file, else: file |> Path.dirname() |> Path.join(path) |> normalize()

      link_target_problems(linked, anchor, context)
    end
  end

  defp link_target_problems(linked, anchor, context) do
    cond do
      not context.file?.(linked) -> ["broken link to #{linked}"]
      anchor == nil or Path.extname(linked) != ".md" -> []
      anchor in context.anchors.(linked) -> []
      true -> ["no heading for ##{anchor} in #{linked}"]
    end
  end

  defp pad([path]), do: [path, nil]
  defp pad([path, anchor]), do: [path, anchor]

  # `Path.expand/1` without the absolute root: "docs/../README.md" -> "README.md".
  defp normalize(path) do
    path
    |> Path.split()
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [_dir | acc] -> acc
      part, acc -> [part | acc]
    end)
    |> Enum.reverse()
    |> Path.join()
  end

  defp headings(text) do
    {headings, _fenced?} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {headings, fenced?} ->
        cond do
          String.starts_with?(line, "```") -> {headings, not fenced?}
          fenced? -> {headings, fenced?}
          heading = heading(line) -> {[heading | headings], fenced?}
          true -> {headings, fenced?}
        end
      end)

    Enum.reverse(headings)
  end

  defp heading(line) do
    case Regex.run(~r/^#+\s+(.+?)\s*#*$/, line) do
      [_line, heading] -> heading
      nil -> nil
    end
  end

  defp slug(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_\- ]/u, "")
    |> String.replace(" ", "-")
  end

  defp resolve_member(module_name, fun, arity, known) do
    case module(module_name) do
      nil -> if module_name in known, do: :ok, else: {:error, "no module #{module_name}"}
      module -> member(module, fun, arity, module_name)
    end
  end

  defp member(module, fun, arity, module_name) do
    if member?(module, fun, arity),
      do: :ok,
      else: {:error, "no #{module_name}.#{fun}#{arity_suffix(arity)}"}
  end

  defp module(name) do
    module = Module.safe_concat([name])
    if Code.ensure_loaded?(module), do: module
  rescue
    ArgumentError -> nil
  end

  defp member?(module, fun, arity) do
    name = String.to_existing_atom(fun)

    module
    |> members()
    |> Enum.any?(fn {member, member_arity} ->
      member == name and (arity == nil or member_arity == arity)
    end)
  rescue
    ArgumentError -> false
  end

  defp members(module) do
    exported = module.__info__(:functions) ++ module.__info__(:macros)

    types =
      for {_kind, {member, _, args}} <- typespecs(&Code.Typespec.fetch_types/1, module),
          do: {member, length(args)}

    callbacks =
      for {member_arity, _specs} <- typespecs(&Code.Typespec.fetch_callbacks/1, module),
          do: member_arity

    exported ++ types ++ callbacks
  end

  defp typespecs(fetch, module) do
    case fetch.(module) do
      {:ok, specs} -> specs
      :error -> []
    end
  end

  defp arity_suffix(nil), do: ""
  defp arity_suffix(arity), do: "/#{arity}"

  defp context(root) do
    known = root |> files() |> Enum.map(&File.read!(Path.join(root, &1))) |> known()

    %{
      resolve: &resolve(&1, known),
      file?: &(File.exists?(Path.join(root, &1)) or ignored?(root, &1)),
      anchors: &anchors(File.read!(Path.join(root, &1)))
    }
  end

  # A directory pattern (`/apps/node/dist/`) matches a missing path only
  # with its trailing slash.
  defp ignored?(root, path) do
    {_output, status} =
      System.cmd("git", ["check-ignore", path, String.trim_trailing(path, "/") <> "/"], cd: root)

    status == 0
  end

  defp files(root) do
    (@markdown ++ @sources)
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&Regex.match?(@skip, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
