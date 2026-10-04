defmodule Photon.Durable.Schema do
  @moduledoc """
  Checks tool arguments against the JSON Schema subset tools declare: an
  object with typed properties (`string`, `integer`, `number`, `boolean`,
  `array`, `object`, `null`, or a list of these), `required` and `enum`.
  Boolean subschemas mean "anything" (`true`) and "nothing" (`false`);
  anything else outside the subset is accepted rather than raised on.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Jason]

  @spec validate(term(), term()) :: :ok | {:error, String.t()}
  def validate(args, schema)

  def validate(args, %{"type" => "object"} = schema) when is_map(args) do
    properties = if is_map(schema["properties"]), do: schema["properties"], else: %{}
    required = if is_list(schema["required"]), do: schema["required"], else: []

    verdict(missing(args, required), errors(args, properties))
  end

  def validate(_args, %{"type" => "object"}), do: {:error, "arguments must be an object"}
  def validate(_args, _schema), do: :ok

  defp missing(args, required), do: for(key <- required, args[key] in [nil, ""], do: key)

  defp errors(args, properties) do
    for {key, value} <- args,
        Map.has_key?(properties, key),
        error = check(key, value, properties[key]),
        do: error
  end

  defp verdict([], []), do: :ok

  defp verdict([_ | _] = missing, _errors),
    do: {:error, "missing required argument(s): #{Enum.map_join(missing, ", ", &show/1)}"}

  defp verdict([], errors), do: {:error, Enum.join(errors, "; ")}

  defp check(_key, nil, _spec), do: nil
  defp check(_key, _value, true), do: nil
  defp check(key, _value, false), do: "#{key} is not allowed"

  defp check(key, value, %{} = spec) do
    cond do
      not type?(value, spec["type"]) ->
        "#{key} must be #{article(spec["type"])}"

      is_list(spec["enum"]) and value not in spec["enum"] ->
        "#{key} must be one of #{Enum.map_join(spec["enum"], ", ", &show/1)}"

      true ->
        nil
    end
  end

  defp check(_key, _value, _spec), do: nil

  defp type?(value, types) when is_list(types), do: Enum.any?(types, &type?(value, &1))
  defp type?(value, "string"), do: is_binary(value)
  defp type?(value, "integer"), do: is_integer(value)
  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "boolean"), do: is_boolean(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "object"), do: is_map(value)
  defp type?(value, "null"), do: is_nil(value)
  defp type?(_value, _), do: true

  defp article(types) when is_list(types), do: Enum.map_join(types, " or ", &article/1)
  defp article("integer"), do: "an integer"
  defp article("array"), do: "an array"
  defp article("object"), do: "an object"
  defp article(type) when is_binary(type), do: "a #{type}"
  defp article(type), do: "a #{show(type)}"

  defp show(value) when is_binary(value), do: value
  defp show(value), do: Jason.encode!(value)
end
