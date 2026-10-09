defmodule Photon.Durable.ToolSchemaTest do
  @moduledoc "The JSON Schema objects tools' `parameters/0` build."

  use Photon.Case, async: true

  alias Photon.Durable.ToolSchema

  test "an object with required properties lists them as strings" do
    assert ToolSchema.object(
             [path: {:string, "The file."}, size: {:integer, "Bytes."}],
             [:path]
           ) == %{
             "type" => "object",
             "properties" => %{
               "path" => %{"type" => "string", "description" => "The file."},
               "size" => %{"type" => "integer", "description" => "Bytes."}
             },
             "required" => ["path"]
           }
  end

  test "an object with nothing required has no required key" do
    schema = ToolSchema.object(on: {:boolean, "Whether it's on."})

    assert schema == %{
             "type" => "object",
             "properties" => %{
               "on" => %{"type" => "boolean", "description" => "Whether it's on."}
             }
           }

    refute Map.has_key?(schema, "required")
  end

  test "an empty object has no properties and no required key" do
    assert ToolSchema.object([]) == %{"type" => "object", "properties" => %{}}
  end

  test "an enum property keeps its allowed values" do
    assert ToolSchema.object([mode: {:string, "How.", enum: ["fast", "slow"]}], [:mode]) == %{
             "type" => "object",
             "properties" => %{
               "mode" => %{
                 "type" => "string",
                 "description" => "How.",
                 "enum" => ["fast", "slow"]
               }
             },
             "required" => ["mode"]
           }
  end

  test "a property may be a type alone, or a type and its allowed values" do
    assert ToolSchema.object([id: :string, mode: {:string, enum: ["a", "b"]}], [:id]) == %{
             "type" => "object",
             "properties" => %{
               "id" => %{"type" => "string"},
               "mode" => %{"type" => "string", "enum" => ["a", "b"]}
             },
             "required" => ["id"]
           }
  end
end
