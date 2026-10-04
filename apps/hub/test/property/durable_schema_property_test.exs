defmodule Photon.Property.DurableSchemaTest do
  @moduledoc """
  `Photon.Durable.Schema.validate/2` checks model-written arguments. It must
  never raise, and its verdict must match the JSON Schema subset it claims.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Photon.Durable.Schema

  @types ~w(string integer number boolean array object)

  defp json_value do
    tree(
      one_of([constant(nil), boolean(), integer(), float(), string(:printable, max_length: 5)]),
      fn leaf ->
        one_of([
          list_of(leaf, max_length: 3),
          map(list_of({string(:alphanumeric, max_length: 3), leaf}, max_length: 3), &Map.new/1)
        ])
      end
    )
  end

  # Arguments as a model writes them: a JSON object, sometimes not one.
  defp args(keys) do
    one_of([
      map(list_of({member_of(keys ++ ["extra"]), json_value()}, max_length: 4), &Map.new/1),
      json_value()
    ])
  end

  # Schemas in the declared subset.
  defp schema do
    gen all(
          props <-
            map(
              list_of(
                {string(:alphanumeric, min_length: 1, max_length: 3),
                 one_of([
                   map(member_of(@types), &%{"type" => &1}),
                   map(
                     list_of(one_of([string(:alphanumeric, max_length: 3), integer()]),
                       min_length: 1,
                       max_length: 3
                     ),
                     &%{"type" => "string", "enum" => &1}
                   ),
                   constant(%{"description" => "untyped"})
                 ])},
                max_length: 4
              ),
              &Map.new/1
            ),
          required <- list_of(member_of(Map.keys(props) ++ ["absent"]), max_length: 2)
        ) do
      %{"type" => "object", "properties" => props, "required" => Enum.uniq(required)}
    end
  end

  defp tool_schemas do
    for module <- Photon.Assistant.tools(nil) ++ [Photon.TestProfile.Wait],
        do: module.parameters()
  end

  property "validate never raises on the assistant's tool schemas" do
    check all(
            schema <- member_of(tool_schemas()),
            args <- args(Map.keys(schema["properties"])),
            max_runs: 400
          ) do
      result = Schema.validate(args, schema)
      assert result == :ok or match?({:error, message} when is_binary(message), result)
    end
  end

  # An independent reading of the subset.
  defp expected(args, _schema) when not is_map(args), do: :error

  defp expected(args, schema) do
    missing = Enum.any?(schema["required"], &(Map.get(args, &1) in [nil, ""]))
    wrong = Enum.any?(args, fn {key, value} -> wrong?(schema["properties"][key], value) end)
    if missing or wrong, do: :error, else: :ok
  end

  defp wrong?(nil = _spec, _value), do: false
  defp wrong?(_spec, nil = _value), do: false

  defp wrong?(spec, value),
    do: not type?(spec["type"], value) or (spec["enum"] != nil and value not in spec["enum"])

  defp type?("string", value), do: is_binary(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("number", value), do: is_integer(value) or is_float(value)
  defp type?("boolean", value), do: value in [true, false]
  defp type?("array", value), do: is_list(value)
  defp type?("object", value), do: is_map(value)
  defp type?(nil, _value), do: true

  property "the verdict matches the subset for generated schemas" do
    check all(
            schema <- schema(),
            args <- args(Map.keys(schema["properties"])),
            max_runs: 400
          ) do
      got = if Schema.validate(args, schema) == :ok, do: :ok, else: :error
      assert got == expected(args, schema)
    end
  end

  # Valid JSON Schema outside the subset: boolean subschemas, type arrays
  # and enums of objects or arrays. A tool may declare these; a model's
  # arguments must then be judged without crashing the call.
  property "validate never raises on valid JSON Schema beyond the subset" do
    subschema =
      one_of([
        boolean(),
        constant(%{"type" => ["string", "null"]}),
        map(
          list_of(one_of([json_value(), constant(%{"a" => 1}), constant([1])]),
            min_length: 1,
            max_length: 2
          ),
          &%{"enum" => &1}
        ),
        map(member_of(@types), &%{"type" => &1})
      ])

    check all(
            props <- map(list_of({member_of(["a", "b"]), subschema}, max_length: 2), &Map.new/1),
            args <- args(["a", "b"]),
            max_runs: 400
          ) do
      schema = %{"type" => "object", "properties" => props}
      result = Schema.validate(args, schema)
      assert result == :ok or match?({:error, message} when is_binary(message), result)
    end
  end
end
