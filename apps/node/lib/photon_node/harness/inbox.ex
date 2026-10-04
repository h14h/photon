defmodule PhotonNode.Harness.Inbox do
  @moduledoc """
  A session's input deduplication. Inputs carry caller-chosen IDs that stay
  stable across redeliveries; the first input with an ID wins and later ones
  are dropped silently. The seen set is seeded from the session log, so an
  input the hub resends after a reconnect or a node restart is ignored.

  Inputs: `%{"id", "kind" => "external" | "control" | "crash", "payload"}`.
  External payloads are `%{"content" => text | parts}`, where a part is a
  text part or an image part (see `PhotonCore.Message`); control payloads
  are `%{"mode" => "hard" | "heartbeat" | "settings", "reason",
  "parameters"}`, and only settings may carry parameters.

  Data and pure functions. `validate/1` is also what `PhotonNode.Harness`
  checks every input with before it reaches a session.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary, type: :strict, deps: []

  defstruct seen: MapSet.new()

  @modes ~w(hard heartbeat settings)

  @type t :: %__MODULE__{seen: MapSet.t(String.t())}

  @typedoc "An input; see the moduledoc."
  @type input :: %{optional(String.t()) => term()}

  @spec new([String.t()]) :: t()
  def new(ids \\ []), do: %__MODULE__{seen: MapSet.new(ids)}

  @doc "Whether an input with this ID was accepted before."
  @spec seen?(t(), String.t()) :: boolean()
  def seen?(%__MODULE__{seen: seen}, id), do: MapSet.member?(seen, id)

  @doc "`{:ok, inbox}` for a new valid input, `:duplicate`, or `{:error, reason}`."
  @spec accept(t(), input()) :: {:ok, t()} | :duplicate | {:error, String.t()}
  def accept(%__MODULE__{seen: seen} = inbox, input) do
    with :ok <- validate(input) do
      if MapSet.member?(seen, input["id"]),
        do: :duplicate,
        else: {:ok, %{inbox | seen: MapSet.put(seen, input["id"])}}
    end
  end

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(%{"id" => id, "kind" => kind} = input) when is_binary(id) and id != "",
    do: validate_payload(kind, input["payload"])

  def validate(_input), do: {:error, "input needs an id and a kind"}

  defp validate_payload("external", %{"content" => content}) when is_binary(content), do: :ok

  defp validate_payload("external", %{"content" => content}) when is_list(content) do
    if Enum.all?(content, &part?/1),
      do: :ok,
      else: {:error, "external input content must be text and image parts"}
  end

  defp validate_payload("external", _payload), do: {:error, "external input needs content"}

  defp validate_payload("control", %{"mode" => mode} = payload)
       when mode in ["hard", "heartbeat"] and is_map_key(payload, "parameters"),
       do: parameters_not_accepted(mode)

  defp validate_payload("control", %{"mode" => "heartbeat", "reason" => reason})
       when is_binary(reason) and reason != "",
       do: :ok

  defp validate_payload("control", %{"mode" => "heartbeat"}),
    do: {:error, "heartbeat needs a reason"}

  defp validate_payload("control", %{"mode" => "settings", "parameters" => params})
       when is_map(params),
       do: :ok

  defp validate_payload("control", %{"mode" => mode} = payload)
       when mode in @modes and is_map_key(payload, "parameters"),
       do: parameters_not_accepted(mode)

  defp validate_payload("control", %{"mode" => mode}) when mode in @modes, do: :ok

  defp validate_payload("control", %{"mode" => mode}),
    do: {:error, "unsupported control mode #{inspect(mode)}"}

  defp validate_payload("crash", _payload), do: :ok
  defp validate_payload(kind, _payload), do: {:error, "invalid input kind #{inspect(kind)}"}

  defp parameters_not_accepted(mode),
    do: {:error, "control mode #{inspect(mode)} does not accept parameters"}

  # The parts a model request can carry (`PhotonCore.Message`).
  defp part?(%{"type" => "text", "text" => text}) when is_binary(text), do: true

  defp part?(%{"type" => "image", "mime" => mime, "data" => data})
       when is_binary(mime) and is_binary(data),
       do: true

  defp part?(_part), do: false
end
