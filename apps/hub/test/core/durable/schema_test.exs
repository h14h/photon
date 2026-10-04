defmodule Photon.Durable.SchemaTest do
  @moduledoc "Argument checks against the JSON Schema subset tools declare."

  use Photon.Case, async: true

  defp object(properties), do: %{"type" => "object", "properties" => properties}

  # hub-schema-raises-beyond-subset
  test "boolean subschemas allow anything or nothing" do
    assert :ok = Schema.validate(%{"a" => false}, object(%{"a" => true}))
    assert {:error, "a is not allowed"} = Schema.validate(%{"a" => 1}, object(%{"a" => false}))
  end

  test "an enum of objects reports a mismatch instead of raising" do
    assert {:error, message} =
             Schema.validate(%{"a" => 2}, object(%{"a" => %{"enum" => [%{"k" => 1}]}}))

    assert message =~ ~s({"k":1})

    assert :ok =
             Schema.validate(%{"a" => %{"k" => 1}}, object(%{"a" => %{"enum" => [%{"k" => 1}]}}))
  end

  test "a list of types accepts any of them and rejects the rest" do
    schema = object(%{"a" => %{"type" => ["string", "null"]}})
    assert :ok = Schema.validate(%{"a" => "x"}, schema)
    assert :ok = Schema.validate(%{"a" => nil}, schema)
    assert {:error, "a must be a string or a null"} = Schema.validate(%{"a" => 1}, schema)
  end
end
