defmodule PhotonCredo.Check.SmallTuples do
  use Credo.Check,
    id: "PH0012",
    base_priority: :normal,
    category: :refactor,
    param_defaults: [
      max_size: 3,
      max_tagged_size: 4,
      max_elem_index: 1,
      ignored_tags: [
        :DOWN,
        :EXIT,
        :"$gen_call",
        :"$gen_cast",
        :nodedown,
        :nodeup,
        :tcp,
        :ssl,
        :udp
      ]
    ],
    explanations: [
      check: """
      Use tuples for small fixed-position data and tagged results, and switch
      to a map once you can't remember what a position means (Designing
      Elixir Systems with OTP, rule 25 in docs/otp-design-guide.md).
      Positions carry no labels.

      This check flags tuple literals (built or matched) with more than
      `max_size` elements, or `max_tagged_size` when the first element is an
      atom tag, and `elem/2` with an index above `max_elem_index`. Shapes
      OTP decided are ignored: its messages (`{:DOWN, ref, :process, pid,
      reason}`, ...) by their tag, and IP addresses (four or eight integers,
      or wildcards in a pattern). Typespecs are not checked.
      """,
      params: [
        max_size: "The most elements an untagged tuple may have.",
        max_tagged_size:
          "The most elements a tuple tagged with an atom may have, the tag included.",
        max_elem_index: "The highest index `elem/2` may read.",
        ignored_tags: "Tags of tuples whose shape someone else decided (OTP messages)."
      ]
    ]

  @typespecs [:spec, :type, :typep, :opaque, :callback, :macrocallback]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    limits =
      Map.new([:max_size, :max_tagged_size, :max_elem_index, :ignored_tags], fn key ->
        {key, Params.get(params, key, __MODULE__)}
      end)

    {_ast, issues} =
      Macro.prewalk(SourceFile.ast(source_file), [], &collect(&1, &2, limits, issue_meta))

    Enum.reverse(issues)
  end

  defp collect({:@, _meta, [{attribute, _, _}]}, acc, _limits, _issue_meta)
       when attribute in @typespecs,
       do: {nil, acc}

  defp collect({:{}, meta, elements} = node, acc, limits, issue_meta) when is_list(elements),
    do: {node, tuple_issue(elements, meta, limits, issue_meta) ++ acc}

  defp collect({:elem, meta, [_tuple, index]} = node, acc, limits, issue_meta)
       when is_integer(index),
       do: {node, elem_issue(index, meta, limits, issue_meta) ++ acc}

  defp collect({:|>, _, [_tuple, {:elem, meta, [index]}]} = node, acc, limits, issue_meta)
       when is_integer(index),
       do: {node, elem_issue(index, meta, limits, issue_meta) ++ acc}

  defp collect(node, acc, _limits, _issue_meta), do: {node, acc}

  defp tuple_issue([tag | _] = elements, meta, limits, issue_meta) do
    if allowed_tuple?(tag, elements, limits),
      do: [],
      else: [issue(issue_meta, length(elements), meta[:line])]
  end

  defp tuple_issue([], _meta, _limits, _issue_meta), do: []

  defp allowed_tuple?(tag, elements, limits) do
    ip_address?(elements) or (is_atom(tag) and tag in limits.ignored_tags) or
      length(elements) <= max_size(tag, limits)
  end

  defp max_size(tag, limits) when is_atom(tag), do: limits.max_tagged_size
  defp max_size(_tag, limits), do: limits.max_size

  # `:inet.ip_address()`: four or eight integers (or wildcards, in a pattern).
  defp ip_address?(elements),
    do: length(elements) in [4, 8] and Enum.all?(elements, &(is_integer(&1) or wildcard?(&1)))

  defp wildcard?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: String.starts_with?(Atom.to_string(name), "_")

  defp wildcard?(_element), do: false

  defp elem_issue(index, meta, limits, issue_meta) do
    if index > limits.max_elem_index do
      [
        format_issue(issue_meta,
          message:
            "elem/2 reads position #{index}. Match the tuple, or use a map or struct whose " <>
              "fields have names.",
          trigger: "elem",
          line_no: meta[:line]
        )
      ]
    else
      []
    end
  end

  defp issue(issue_meta, size, line) do
    format_issue(issue_meta,
      message:
        "A #{size}-element tuple: positions carry no labels. Use a map or a struct, " <>
          "or group the values.",
      trigger: "{",
      line_no: line
    )
  end
end
