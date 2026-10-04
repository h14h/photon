defmodule PhotonCredo.Ast do
  @moduledoc """
  AST helpers shared by Photon's custom Credo checks (`PhotonCredo.Check.*`).

  The checks reason about modules: which module a piece of code is in, what
  an alias stands for, which functions a module defines and how long they
  are. Credo hands each check a file's AST; these functions turn it into
  `t:module_info/0` maps with aliases resolved.

  Module patterns, as the checks' params take them: `"A.B"` matches the
  module `A.B` only, and `"A.B.*"` matches `A.B` and every module under it.
  Atoms work too (`A.B`).
  """

  @typedoc "A module found in a file: its name, its body without nested modules, and its aliases."
  @type module_info :: %{
          name: String.t(),
          body: Macro.t(),
          aliases: %{atom() => [atom() | String.t()]},
          line: non_neg_integer()
        }

  @typedoc "One `def`, `defp`, `defmacro` or `defmacrop` clause."
  @type clause :: %{
          kind: :def | :defp | :defmacro | :defmacrop,
          name: atom(),
          arity: non_neg_integer(),
          args: [Macro.t()],
          guards: [Macro.t()],
          body: Macro.t(),
          line: non_neg_integer(),
          body_lines: non_neg_integer()
        }

  @typedoc "A remote call: the resolved module (`Enum`, `:ets`), function, arity, line and args."
  @type remote_call :: %{
          module: String.t(),
          function: atom(),
          arity: non_neg_integer(),
          line: non_neg_integer(),
          args: [Macro.t()]
        }

  @definitions [:def, :defp, :defmacro, :defmacrop]

  ## Modules

  @doc "Every module defined in `ast`, outermost first. Nested modules come out separately."
  @spec modules(Macro.t()) :: [module_info()]
  def modules(ast), do: collect_modules(ast, nil)

  defp collect_modules(ast, parent) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [name_ast, [{:do, body}]]}, acc ->
          name = module_name(name_ast, parent)
          {nil, [collect_modules(body, name), module_info(name, body, meta) | acc]}

        node, acc ->
          {node, acc}
      end)

    found |> Enum.reverse() |> List.flatten()
  end

  defp module_info(name, body, meta) do
    own_body = strip_modules(body)

    %{
      name: name,
      body: own_body,
      aliases: collect_aliases(own_body, name),
      line: Keyword.get(meta, :line, 0)
    }
  end

  defp module_name({:__aliases__, _meta, [{:__MODULE__, _, _} | rest]}, parent),
    do: Enum.join([parent | rest], ".")

  defp module_name({:__aliases__, _meta, parts}, nil), do: Enum.join(parts, ".")
  defp module_name({:__aliases__, _meta, parts}, parent), do: Enum.join([parent | parts], ".")
  defp module_name(atom, _parent) when is_atom(atom), do: inspect(atom)
  defp module_name(_other, parent), do: parent || "?"

  defp strip_modules(body) do
    Macro.prewalk(body, fn
      {:defmodule, _meta, _args} -> nil
      node -> node
    end)
  end

  ## Aliases

  defp collect_aliases(body, current) do
    {_ast, aliases} =
      Macro.prewalk(body, %{}, fn
        {:alias, _meta, [target | opts]} = node, aliases ->
          {node, add_alias(aliases, target, List.first(opts) || [], current)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp add_alias(aliases, {{:., _, [base, :{}]}, _, children}, _opts, current) do
    base_parts = expand(base, aliases, current)

    Enum.reduce(children, aliases, fn
      {:__aliases__, _, parts}, acc -> Map.put(acc, List.last(parts), base_parts ++ parts)
      _other, acc -> acc
    end)
  end

  defp add_alias(aliases, {:__aliases__, _, parts} = target, opts, current) when is_list(opts) do
    full = expand(target, aliases, current)

    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as]} -> Map.put(aliases, as, full)
      _ -> Map.put(aliases, List.last(parts), full)
    end
  end

  defp add_alias(aliases, _target, _opts, _current), do: aliases

  defp expand({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, _aliases, current),
    do: [current | rest]

  defp expand({:__aliases__, _, [first | rest] = parts}, aliases, _current) when is_atom(first) do
    case Map.fetch(aliases, first) do
      {:ok, full} -> full ++ rest
      :error -> parts
    end
  end

  defp expand({:__MODULE__, _, _}, _aliases, current), do: [current]
  defp expand(_other, _aliases, _current), do: []

  @doc """
  The module an expression names, as a string: `"Photon.Repo"` for `Repo`
  under `alias Photon.Repo`, `":ets"` for `:ets`, or nil for anything else
  (a variable, say).
  """
  @spec resolve(Macro.t(), module_info()) :: String.t() | nil
  def resolve({:__aliases__, _, _} = ast, info) do
    case expand(ast, info.aliases, info.name) do
      [] -> nil
      parts -> Enum.map_join(parts, ".", &to_string/1)
    end
  end

  def resolve({:__MODULE__, _, _}, info), do: info.name

  def resolve(atom, _info) when is_atom(atom) and atom not in [nil, true, false],
    do: inspect(atom)

  def resolve(_other, _info), do: nil

  ## Matching

  @doc "Whether `module` (a string) matches one of `patterns` (see the moduledoc)."
  @spec matches?(String.t() | nil, [String.t() | atom()]) :: boolean()
  def matches?(nil, _patterns), do: false

  def matches?(module, patterns) when is_binary(module),
    do: Enum.any?(patterns, &match_pattern?(module, normalize(&1)))

  defp match_pattern?(module, pattern) do
    case String.split(pattern, ".*", parts: 2) do
      [namespace, ""] -> module == namespace or String.starts_with?(module, namespace <> ".")
      _ -> module == pattern
    end
  end

  @doc """
  A module pattern or name as a string: `Foo.Bar` and `"Foo.Bar"` both give
  `"Foo.Bar"`, and `:ets` gives `":ets"`.
  """
  @spec normalize(String.t() | atom()) :: String.t()
  def normalize(name) when is_binary(name), do: name
  def normalize(name) when is_atom(name), do: inspect(name)

  @doc "The value a param maps a module to, from a list of `{pattern, value}` pairs or a map."
  @spec lookup(String.t(), map() | [{String.t() | atom(), term()}]) :: term() | nil
  def lookup(module, pairs) do
    Enum.find_value(pairs, fn {pattern, value} -> if matches?(module, [pattern]), do: value end)
  end

  @doc """
  Whether an `allowed` param (`[{module_pattern, "reason"}]`) lists `module`
  with a reason. An entry without a reason allows nothing: the reason is the
  point of the allow list.
  """
  @spec allowed_with_reason?(String.t(), map() | [{String.t() | atom(), term()}]) :: boolean()
  def allowed_with_reason?(module, allowed) do
    case lookup(module, allowed) do
      reason when is_binary(reason) -> String.trim(reason) != ""
      _ -> false
    end
  end

  ## Functions

  @doc "The `def`/`defp`/`defmacro`/`defmacrop` clauses at the top level of a module body."
  @spec clauses(module_info()) :: [clause()]
  def clauses(%{body: body}) do
    body
    |> top_level_forms()
    |> Enum.flat_map(&clause/1)
  end

  @doc "The forms directly inside a module body."
  @spec top_level_forms(Macro.t()) :: [Macro.t()]
  def top_level_forms({:__block__, _meta, forms}), do: forms
  def top_level_forms(nil), do: []
  def top_level_forms(form), do: [form]

  defp clause({kind, meta, [head, body_kw]}) when kind in @definitions and is_list(body_kw) do
    {call, guards} = split_guards(head)

    case call do
      {name, _meta, args} when is_atom(name) ->
        args = if is_list(args), do: args, else: []
        body = Keyword.get(body_kw, :do)

        [
          %{
            kind: kind,
            name: name,
            arity: length(args),
            args: args,
            guards: guards,
            body: body_kw_to_block(body_kw),
            line: Keyword.get(meta, :line, 0),
            body_lines: body_lines(meta, body)
          }
        ]

      _ ->
        []
    end
  end

  defp clause(_form), do: []

  defp split_guards({:when, _meta, [call | guards]}), do: {call, guards}
  defp split_guards(call), do: {call, []}

  # `do`, plus any `rescue`/`catch`/`after`/`else` blocks, as one block.
  defp body_kw_to_block(body_kw), do: {:__block__, [], Keyword.values(body_kw)}

  # Lines between `do` and `end` for a block; the span of the body for `do:`.
  defp body_lines(meta, body) do
    case {meta[:do], meta[:end]} do
      {[_ | _] = do_meta, [_ | _] = end_meta} ->
        max(end_meta[:line] - do_meta[:line] - 1, 0)

      _ ->
        case line_span(body) do
          {first, last} -> last - first + 1
          nil -> 1
        end
    end
  end

  @doc "The first and last line an expression's metadata mentions, or nil."
  @spec line_span(Macro.t()) :: {pos_integer(), pos_integer()} | nil
  def line_span(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          {node, Enum.reject([meta[:line], get_in(meta, [:end, :line])], &is_nil/1) ++ acc}

        node, acc ->
          {node, acc}
      end)

    if lines == [], do: nil, else: Enum.min_max(lines)
  end

  ## Calls

  @doc """
  Every remote call in `ast` (`Mod.fun(...)`, `:erl.fun(...)`, and the
  right side of a pipe, which gets the piped value as an extra argument),
  with the module resolved against `info`. Calls on variables are skipped.
  """
  @spec remote_calls(Macro.t(), module_info()) :: [remote_call()]
  def remote_calls(ast, info) do
    {_ast, calls} = Macro.prewalk(ast, [], &collect_call(&1, &2, info))

    # A piped call is seen twice, as the pipe and as the call: keep the pipe's arity.
    calls
    |> Enum.reverse()
    |> Enum.uniq_by(&Map.delete(&1, :arity))
  end

  defp collect_call({:|>, _, [_left, {{:., _, [mod, fun]}, meta, args}]} = node, acc, info)
       when is_atom(fun) and is_list(args),
       do: {node, add_call(acc, info, mod, call(fun, length(args) + 1, meta, args))}

  defp collect_call({{:., _, [mod, fun]}, meta, args} = node, acc, info)
       when is_atom(fun) and is_list(args),
       do: {node, add_call(acc, info, mod, call(fun, length(args), meta, args))}

  defp collect_call(node, acc, _info), do: {node, acc}

  defp call(fun, arity, meta, args),
    do: %{function: fun, arity: arity, line: meta[:line] || 0, args: args}

  defp add_call(acc, info, mod, call) do
    case resolve(mod, info) do
      nil -> acc
      module -> [Map.put(call, :module, module) | acc]
    end
  end

  @doc "Whether a module body `use`s one of `modules` (resolved names); returns the `use` options or nil."
  @spec use_opts(module_info(), [String.t()]) :: {String.t(), Macro.t()} | nil
  def use_opts(info, modules) do
    info.body
    |> top_level_forms()
    |> Enum.find_value(fn
      {:use, _meta, [target | opts]} ->
        name = resolve(target, info)
        if name in modules, do: {name, List.first(opts)}

      _ ->
        nil
    end)
  end

  @doc "A compact source form of an expression, for issue triggers."
  @spec to_trigger(Macro.t()) :: String.t()
  def to_trigger(ast), do: ast |> Macro.to_string() |> String.split("\n") |> hd()
end
