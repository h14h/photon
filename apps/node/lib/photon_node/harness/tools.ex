defmodule PhotonNode.Harness.Tools do
  @moduledoc """
  The tool registry. Tools are translators: functions that validate a tool
  call and turn it into a status plus operations (`translate/2`), and format
  a recorded status plus operation snapshots into what the model sees
  (`format/2`). They run inside the session core and do no I/O; the only
  impurity is the operation ID `PhotonCore.Operation.new/4` mints.

  A status is `%{"error" => text, "waiting_for" => [operation id]}`; an error
  status has no operations.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [PhotonCore, Jason]

  alias PhotonCore.{Operation, Output}
  alias PhotonNode.Harness.Tools.{Bash, SkillUse, ViewImage}

  @static [Bash, ViewImage, SkillUse]

  @typedoc "A tool call's status; see the moduledoc."
  @type status :: %{optional(String.t()) => term()}

  @typedoc """
  What translators may read: `:workspace`, `:shell`, `:operations_dir` and
  `:skills` (see `PhotonNode.Harness.Session.env/0`).
  """
  @type env :: %{optional(atom()) => term()}

  @callback name() :: String.t()
  @callback definition() :: map()
  @callback translate(call :: map(), env :: env()) :: {status(), [Operation.t()]}
  @callback format(status :: status(), operations :: [Operation.t()]) :: [map()]

  @doc "Enabled tool names: Bash and ViewImage, SkillUse when there are skills, minus disallowed ones."
  @spec enabled([String.t()] | nil, [map()]) :: [String.t()]
  def enabled(disallowed, skills) do
    names = ["Bash", "ViewImage"] ++ if(skills != [], do: ["SkillUse"], else: [])
    names -- (disallowed || [])
  end

  @spec definitions([String.t()]) :: [map()]
  def definitions(enabled) do
    for module <- @static, module.name() in enabled, do: module.definition()
  end

  @doc "The translator for an enabled tool, or nil."
  @spec resolve(String.t() | nil, [String.t()]) :: module() | nil
  def resolve(name, enabled) do
    if name in enabled, do: Enum.find(@static, &(&1.name() == name))
  end

  @spec error_status(String.t(), non_neg_integer()) :: status()
  def error_status(message, limit \\ Output.default_limit()) do
    {text, truncated} = Output.bound(message, limit)
    %{"error" => text, "error_truncated" => truncated, "waiting_for" => []}
  end

  @spec ok_status([Operation.t()]) :: status()
  def ok_status(operations),
    do: %{"error" => "", "waiting_for" => Enum.map(operations, & &1["id"])}

  @doc """
  Decodes a call's JSON arguments, which must be an object; missing or empty
  arguments are `{}`. `describe_error` turns `:not_an_object` or a
  `Jason.DecodeError` into the message the model sees.
  """
  @spec decode_arguments(String.t() | nil, (:not_an_object | Exception.t() -> String.t())) ::
          {:ok, map()} | {:error, String.t()}
  def decode_arguments(arguments, describe_error) do
    json = if arguments in [nil, ""], do: "{}", else: arguments

    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, describe_error.(:not_an_object)}
      {:error, error} -> {:error, describe_error.(error)}
    end
  end
end
