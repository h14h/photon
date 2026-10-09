defmodule Photon.Durable.ToolSchema do
  @moduledoc """
  Builds a tool's `parameters/0`: a JSON Schema object of named
  properties, each a type alone, `{type, description}`, or either with
  `enum: [...]` (`{type, enum: [...]}`, `{type, description, enum: [...]}`),
  in the subset `Photon.Durable.Schema` validates.

      ToolSchema.object([path: {:string, "The file."}, size: {:integer, "Bytes."}], [:path])
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @typedoc "One property: its JSON type, its description, and optionally its allowed values."
  @type property ::
          type()
          | {type(), String.t() | [enum: [term()]]}
          | {type(), String.t(), [enum: [term()]]}

  @typedoc "A property's JSON type."
  @type type :: :string | :integer | :boolean

  @doc "An object schema of `properties`, with `required` listing those that must be given."
  @spec object([{atom(), property()}], [atom()]) :: map()
  def object(properties, required \\ []) do
    schema = %{"type" => "object", "properties" => Map.new(properties, &property/1)}

    if required == [],
      do: schema,
      else: Map.put(schema, "required", Enum.map(required, &to_string/1))
  end

  defp property({name, type}) when is_atom(type),
    do: {to_string(name), %{"type" => to_string(type)}}

  defp property({name, {type, enum: values}}) do
    {key, schema} = property({name, type})
    {key, Map.put(schema, "enum", values)}
  end

  defp property({name, {type, description}}) do
    {key, schema} = property({name, type})
    {key, Map.put(schema, "description", description)}
  end

  defp property({name, {type, description, enum: values}}) do
    {key, schema} = property({name, {type, description}})
    {key, Map.put(schema, "enum", values)}
  end
end
