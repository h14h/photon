defmodule Photon.Skills.Rules do
  @moduledoc """
  The rules for skills, as pure functions. `Photon.Skills` checks input with
  these once, before or inside the commit that applies it (rule 64).
  Errors are messages that say what to do: a map of field to message for
  a skill's form (`skill/2`), a plain message elsewhere.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Text]

  alias Photon.Text

  @name_limit 64
  @description_limit 1_024
  @instructions_limit 50_000
  @scope_limit 30
  @reserved_names ~w(new install)
  @name_format ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  @name_message ~s(A skill's name uses lowercase letters, digits and hyphens, like "pdf-forms".)

  # What `mentions/2` takes for a file, with no folder listing.
  @path_like ~r{\A(?:(?:scripts|references|assets)/\S+|\S+\.(?:py|sh|js|ts))\z}
  @under_folder ~r{\A(?:scripts|references|assets)/\S+\z}

  @typedoc "A skill's fields as `skill/2` checked them."
  @type attrs :: %{name: String.t(), description: String.t(), instructions: String.t()}

  @typedoc "Form errors: each field's message."
  @type field_errors :: %{optional(:name | :description | :instructions) => String.t()}

  ## A skill's fields

  @doc """
  Checks a skill's `params` (atom or string keys `name`, `description`
  and `instructions`) against `current`, the skill being edited (any map
  with those keys), or nil for a new one. A field missing from `params`
  keeps its current value. The name and description are trimmed; the
  instructions are trimmed and their line ends made `\\n`.
  """
  @spec skill(map(), map() | nil) :: {:ok, attrs()} | {:error, field_errors()}
  def skill(params, current) do
    name = field(params, :name, current)
    description = field(params, :description, current)
    instructions = field(params, :instructions, current)

    name_result = name(name)

    label =
      case name_result do
        {:ok, name} -> name
        {:error, _message} -> nil
      end

    results = %{
      name: name_result,
      description: description(description),
      instructions: instructions(label, instructions)
    }

    case for({field, {:error, message}} <- results, into: %{}, do: {field, message}) do
      errors when errors == %{} -> {:ok, Map.new(results, fn {field, {:ok, v}} -> {field, v} end)}
      errors -> {:error, errors}
    end
  end

  defp field(params, key, current) do
    value =
      case Map.fetch(params, key) do
        {:ok, value} -> value
        :error -> Map.get(params, Atom.to_string(key), current && Map.get(current, key))
      end

    if is_binary(value), do: value, else: ""
  end

  @doc """
  A skill's name, trimmed: 1 to 64 lowercase letters, digits and single
  hyphens, not starting or ending with a hyphen, and not one the app's
  routes use (`new`, `install`).
  """
  @spec name(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def name(name) do
    name = String.trim(name)

    cond do
      String.length(name) > @name_limit -> {:error, "Keep the name to 64 characters or fewer."}
      not Regex.match?(@name_format, name) -> {:error, @name_message}
      name in @reserved_names -> {:error, "That name is taken by the app; pick another."}
      true -> {:ok, name}
    end
  end

  @doc "The error for a name another skill has, for the form."
  @spec name_taken(String.t()) :: field_errors()
  def name_taken(name), do: %{name: "There's already a skill called #{name}."}

  @doc """
  A name that follows the rule, made from `text` (a SKILL.md's name that
  doesn't): "PDF Forms" becomes `pdf-forms`, `skill` when nothing is
  left, and a reserved name gets `-skill` after it.
  """
  @spec suggest_name(String.t()) :: String.t()
  def suggest_name(text) do
    name =
      text
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> cut(@name_limit)
      |> String.trim_trailing("-")

    cond do
      name == "" -> "skill"
      name in @reserved_names -> name <> "-skill"
      true -> name
    end
  end

  # The name is ASCII by now, so bytes are characters.
  defp cut(text, limit) when byte_size(text) <= limit, do: text
  defp cut(text, limit), do: binary_part(text, 0, limit)

  @doc "A skill's description, trimmed: required, and at most 1,024 characters."
  @spec description(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def description(description) do
    description = description |> newlines() |> String.trim()

    cond do
      description == "" ->
        {:error, "Say when an agent should use this skill."}

      String.length(description) > @description_limit ->
        {:error, "Keep the description under 1,024 characters; agents read it on every request."}

      true ->
        {:ok, description}
    end
  end

  @doc """
  A skill's instructions, trimmed, with `\\n` line ends: required, and at
  most 50,000 characters (code points), since a skill is loaded whole.
  `name` names the skill in the message ("pdf-forms's instructions are
  ..."); pass nil when the name is invalid.
  """
  @spec instructions(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def instructions(name, instructions) do
    instructions = instructions |> newlines() |> String.trim()

    case code_points(instructions) do
      0 ->
        {:error, "A skill needs instructions."}

      n when n > @instructions_limit ->
        whose = if name, do: "#{name}'s instructions are", else: "The instructions are"

        {:error,
         "#{whose} #{Text.count(n)} characters; the limit is #{Text.count(@instructions_limit)}, " <>
           "since a skill is loaded whole into the conversation."}

      _fits ->
        {:ok, instructions}
    end
  end

  defp newlines(text), do: String.replace(text, "\r\n", "\n")

  # Text no longer in bytes than the limit is within it in code points too.
  defp code_points(text) when byte_size(text) <= @instructions_limit, do: byte_size(text)
  defp code_points(text), do: text |> String.to_charlist() |> length()

  ## Saving and enabling

  @doc """
  Whether a save from the skill's page may go ahead: `:ok` when the skill
  is still at the version the page loaded, `:stale` when it changed since.
  """
  @spec save_check(pos_integer(), pos_integer() | nil) :: :ok | :stale
  def save_check(version, version), do: :ok
  def save_check(_current_version, _expected_version), do: :stale

  @doc """
  Whether a skill may be turned on in a scope that has `enabled_count`
  skills on already: at most 30 per scope, since every enabled skill's
  description is in every prompt there.
  """
  @spec enable_check(non_neg_integer()) :: :ok | {:error, String.t()}
  def enable_check(enabled_count) when enabled_count < @scope_limit, do: :ok

  def enable_check(_enabled_count) do
    {:error,
     "30 skills are on here already. Turn one off first: agents read every enabled " <>
       "skill's description on every request."}
  end

  ## Machine skills

  @doc """
  Machine skills grouped by machine: `pairs` are `{machine_id, skill}` in
  the order to list the skills, `known` the machines the hub knows in the
  order to list them. Only known machines with a skill are kept, so a
  removed machine's skills are left out.
  """
  @spec by_machine([{String.t(), skill}], [String.t()]) :: [{String.t(), [skill, ...]}]
        when skill: term()
  def by_machine(pairs, known) do
    grouped = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
    for id <- known, skills = Map.get(grouped, id), do: {id, skills}
  end

  @typedoc "What `find_offered/2` needs of a skill: a `Photon.Skills.Skill` will do."
  @type named :: %{required(:name) => String.t(), optional(atom()) => term()}

  @doc """
  Where a `load_skill` call finds the skill called `name` (as listed:
  trimmed and downcased) among what the agent is `offered`:

  - `{:own, skill}` when the agent's own set has it. The own set wins
    over the machines', since a skill on for the agent applies to all its
    work, not only on a machine.
  - `{:machines, skill, ids}` when only machines have it: every machine
    that does, in `offered`'s order.
  - `{:none, own_names, machine_names}` when nothing does: the names in
    the own set, and each machine with its skills' names, for the error.
  """
  @spec find_offered(%{own: [skill], machines: [{String.t(), [skill]}]}, String.t()) ::
          {:own, skill}
          | {:machines, skill, [String.t(), ...]}
          | {:none, [String.t()], [{String.t(), [String.t()]}]}
        when skill: named()
  def find_offered(%{own: own, machines: machines}, name) do
    case named(own, name) do
      nil -> find_on_machines(machines, name, own)
      skill -> {:own, skill}
    end
  end

  defp find_on_machines(machines, name, own) do
    case for({id, skills} <- machines, skill = named(skills, name), do: {id, skill}) do
      [{_id, skill} | _more] = found ->
        {:machines, skill, Enum.map(found, &elem(&1, 0))}

      [] ->
        {:none, names(own), for({id, skills} <- machines, do: {id, names(skills)})}
    end
  end

  defp named(skills, name), do: Enum.find(skills, &(&1.name == name))

  defp names(skills), do: Enum.map(skills, & &1.name)

  ## What install left out

  @doc """
  The files the instructions mention that install didn't bring.

  With a folder listing, these are the paths in `left_out` the
  instructions name, as written or as a Markdown link's target (also
  with a leading `./`), in `left_out`'s order.

  With no listing (a paste, `left_out` empty), they are guesses in the
  order they first appear: relative Markdown link targets, and paths in
  backticks under `scripts/`, `references/` or `assets/`, or (in a code
  span, not a fenced block, where examples name the user's own files)
  ending in `.py`, `.sh`, `.js` or `.ts`.
  """
  @spec mentions(String.t(), [String.t()]) :: [String.t()]
  def mentions(instructions, []) do
    (link_targets(instructions) ++ backticked_paths(instructions))
    |> Enum.sort_by(fn {at, _path} -> at end)
    |> Enum.map(fn {_at, path} -> path end)
    |> Enum.uniq()
  end

  def mentions(instructions, left_out) do
    Enum.filter(left_out, fn path ->
      Regex.match?(~r{(?<![\w./-])(?:\./)?#{Regex.escape(path)}(?![\w/-])}u, instructions)
    end)
  end

  defp link_targets(text) do
    ~r{\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)}
    |> Regex.scan(text, return: :index, capture: :all_but_first)
    |> Enum.flat_map(fn [{at, length}] ->
      target = text |> binary_part(at, length) |> relative_path()
      if target, do: [{at, target}], else: []
    end)
  end

  # A link target as a path in the skill's folder, or nil for an address,
  # an anchor or an absolute path.
  defp relative_path(target) do
    path = target |> String.split(["#", "?"], parts: 2) |> hd() |> String.trim_leading("./")

    cond do
      path == "" -> nil
      String.starts_with?(path, ["/", "~", "../"]) -> nil
      Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9+.-]*:/, path) -> nil
      true -> path
    end
  end

  # With where each starts.
  defp backticked_paths(text) do
    fenced = Regex.scan(~r/^[ \t]*```[^\n]*\n(.*?)(?:^[ \t]*```|\z)/ms, text, return: :index)
    fenced_ranges = Enum.map(fenced, fn [whole, _body] -> whole end)

    spans =
      ~r/`([^`\n]+)`/
      |> Regex.scan(text, return: :index, capture: :all_but_first)
      |> Enum.reject(fn [{at, _length}] -> inside?(at, fenced_ranges) end)

    from_spans = Enum.flat_map(spans, fn [range] -> words(text, range, @path_like) end)

    from_fences =
      Enum.flat_map(fenced, fn [_whole, range] -> words(text, range, @under_folder) end)

    from_spans ++ from_fences
  end

  defp inside?(at, ranges),
    do: Enum.any?(ranges, fn {from, length} -> at >= from and at < from + length end)

  defp words(text, {offset, length}, pattern) do
    code = binary_part(text, offset, length)

    ~r/[^\s"'`=(),;]+/
    |> Regex.scan(code, return: :index)
    |> Enum.flat_map(fn [{at, length}] ->
      word = code |> binary_part(at, length) |> String.trim_leading("./")

      if Regex.match?(pattern, word) and relative_path(word) == word,
        do: [{offset + at, word}],
        else: []
    end)
  end
end
