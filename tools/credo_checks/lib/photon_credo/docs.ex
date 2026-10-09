defmodule PhotonCredo.Docs do
  @moduledoc """
  Checks that the docs name things that exist: local Markdown links and
  their anchors, repo paths in backticks (`apps/hub/mix.exs`), and module,
  function and type names in backticks under Photon's namespaces
  (`Photon.Durable.submit_tx/4`, `PhotonNode.Config.t`). It reads the
  repo's Markdown and the apps' and tools' sources, where those names sit
  in moduledocs, docs and comments.

  A name exists when its module is loaded and has that function, macro,
  type or callback. A module that isn't loaded here (another app's test
  support) is read from its source instead: it exists when a source defines
  it, and has a member when that source defines one by the name. A bare
  name may also be a registered process name (`name: Photon.PubSub`) or a
  namespace. A path exists when it is in the repo or ignored by git (build
  output), though a generated Markdown file's anchors can't be checked.
  Test files are checked for names only, since their fixtures hold made-up
  paths.

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
          anchors: (String.t() -> [String.t()] | :unavailable)
        }

  @typedoc """
  What the sources say about modules this VM may not have loaded: the
  members each defined module's source defines, and the other names that
  may stand alone (registered process names and namespaces).
  """
  @type known :: %{defined: %{String.t() => MapSet.t(String.t())}, bare: MapSet.t(String.t())}

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
  @link ~r/\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/
  @link_definition ~r/^ {0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?/
  @roots "(?:PhotonCore|PhotonNode|PhotonWeb|PhotonCredo|Photon)"
  @name ~r/^#{@roots}(?:\.[A-Z]\w*)*(?:\.[a-z_]\w*[?!]?(?:\/\d+)?)?$/
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
  function, macro, type or callback (with its arity, if given). For a
  module that isn't loaded, `known` says (see `t:known/0`); arities aren't
  checked there.
  """
  @spec resolve(String.t(), known()) :: :ok | {:error, String.t()}
  def resolve(name, known) do
    case Regex.run(~r/^(.*?)\.([a-z_]\w*[?!]?)(?:\/(\d+))?$/, name) do
      [_all, module, fun] -> resolve_member(module, fun, nil, known)
      [_all, module, fun, arity] -> resolve_member(module, fun, String.to_integer(arity), known)
      nil -> resolve_module(name, known)
    end
  end

  defp resolve_module(name, known) do
    if module(name) || Map.has_key?(known.defined, name) || name in known.bare,
      do: :ok,
      else: {:error, "no module #{name}"}
  end

  @doc """
  What `sources` say about modules (`t:known/0`): each module a source
  defines, with the functions, macros, types and callbacks it defines, and
  the process names they register (`name: Photon.PubSub`), with every
  namespace above both. A source that doesn't parse adds nothing.
  """
  @spec known([String.t()]) :: known()
  def known(sources) do
    defined =
      sources
      |> Enum.flat_map(&defined_modules/1)
      |> Enum.reduce(%{}, fn {name, members}, acc ->
        Map.update(acc, name, members, &MapSet.union(&1, members))
      end)

    bare =
      (Map.keys(defined) ++ Enum.flat_map(sources, &registered_names/1))
      |> Enum.flat_map(&namespaces/1)
      |> MapSet.new()

    %{defined: defined, bare: bare}
  end

  defp registered_names(source) do
    for [_match, name] <- Regex.scan(~r/name:\s+(#{@roots}[\w.]*)/, source), do: name
  end

  defp defined_modules(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> modules_in(ast)
      {:error, _reason} -> []
    end
  end

  defp modules_in(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _, parts}, body]} = node, acc ->
          {node, [{Enum.map_join(parts, ".", &to_string/1), members_in(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    modules
  end

  @definitions [:def, :defp, :defmacro, :defmacrop, :defdelegate, :defguard]
  @attributes [:type, :typep, :opaque, :callback, :macrocallback]

  defp members_in(body) do
    {_ast, names} =
      Macro.prewalk(body, MapSet.new(), fn
        {kind, _meta, [head | _]} = node, acc when kind in @definitions ->
          {node, add_name(acc, head)}

        {:@, _meta, [{attribute, _, [spec]}]} = node, acc when attribute in @attributes ->
          {node, add_name(acc, spec)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp add_name(acc, {:when, _meta, [head | _]}), do: add_name(acc, head)
  defp add_name(acc, {:"::", _meta, [head | _]}), do: add_name(acc, head)

  defp add_name(acc, {name, _meta, _args}) when is_atom(name),
    do: MapSet.put(acc, Atom.to_string(name))

  defp add_name(acc, _head), do: acc

  defp namespaces(name) do
    parts = String.split(name, ".")
    for n <- 1..length(parts), do: parts |> Enum.take(n) |> Enum.join(".")
  end

  defp line_problems(line, file, kind, context) do
    spans = for [_span, inner] <- Regex.scan(@code_span, line), do: inner

    links =
      if kind == :markdown,
        do:
          for(
            [_link, target] <- Regex.scan(@link, line) ++ Regex.scan(@link_definition, line),
            do: target
          ),
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
      true -> anchor_problems(anchor, linked, context.anchors.(linked))
    end
  end

  defp anchor_problems(anchor, linked, :unavailable),
    do: ["can't check ##{anchor}: #{linked} isn't in the repo"]

  defp anchor_problems(anchor, linked, anchors) do
    if anchor in anchors, do: [], else: ["no heading for ##{anchor} in #{linked}"]
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
    |> join()
  end

  defp join([]), do: "."
  defp join(parts), do: Path.join(parts)

  # ATX (`## Title`) and setext (a paragraph underlined with `===` or `---`)
  # headings, outside ``` and ~~~ fences.
  defp headings(text) do
    {headings, _fence, _paragraph} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], nil, nil}, &heading_line/2)

    Enum.reverse(headings)
  end

  defp heading_line(line, {headings, nil = _fence, paragraph}) do
    cond do
      fence = fence_opener(line) ->
        {headings, fence, nil}

      heading = atx(line) ->
        {[heading | headings], nil, nil}

      paragraph && Regex.match?(~r/^ {0,3}(=+|-+)\s*$/, line) ->
        {[paragraph | headings], nil, nil}

      String.trim(line) == "" ->
        {headings, nil, nil}

      true ->
        {headings, nil, join_paragraph(paragraph, line)}
    end
  end

  defp heading_line(line, {headings, fence, _paragraph}) do
    if String.starts_with?(String.trim_leading(line), fence),
      do: {headings, nil, nil},
      else: {headings, fence, nil}
  end

  defp fence_opener(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line) do
      [_line, fence] -> fence
      nil -> nil
    end
  end

  defp atx(line) do
    case Regex.run(~r/^ {0,3}\#{1,6}\s+(.+?)(?:\s+#+)?\s*$/, line) do
      [_line, heading] -> heading
      nil -> nil
    end
  end

  defp join_paragraph(nil, line), do: String.trim(line)
  defp join_paragraph(paragraph, line), do: paragraph <> " " <> String.trim(line)

  defp slug(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_\- ]/u, "")
    |> String.replace(" ", "-")
  end

  defp resolve_member(module_name, fun, arity, known) do
    case {module(module_name), Map.fetch(known.defined, module_name)} do
      {nil, {:ok, members}} -> source_member(members, fun, arity, module_name)
      {nil, :error} -> {:error, "no module #{module_name}"}
      {module, _source} -> member(module, fun, arity, module_name)
    end
  end

  defp source_member(members, fun, arity, module_name) do
    if fun in members,
      do: :ok,
      else: {:error, "no #{module_name}.#{fun}#{arity_suffix(arity)}"}
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
      anchors: &read_anchors(Path.join(root, &1))
    }
  end

  defp read_anchors(path) do
    case File.read(path) do
      {:ok, text} -> anchors(text)
      {:error, _reason} -> :unavailable
    end
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
