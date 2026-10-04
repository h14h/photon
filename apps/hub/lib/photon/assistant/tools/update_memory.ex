defmodule Photon.Assistant.Tools.UpdateMemory do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.Memory
  alias Photon.Durable

  @impl true
  def name, do: "update_memory"

  @impl true
  def description do
    "Change your long-term memory, which is part of your instructions in every conversation. " <>
      "add appends a line; remove deletes lines containing text; rewrite replaces it all."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["add", "remove", "rewrite"]},
        "text" => %{
          "type" => "string",
          "description" => "The line to add, text to match for removal, or the whole new memory."
        }
      },
      "required" => ["action", "text"]
    }
  end

  @impl true
  def execute(%{"action" => action, "text" => text}, _api) do
    memory =
      Durable.update_doc("global", "memory", Memory.empty(), &Memory.edit(&1, action, text))

    {:ok, "Memory is now:\n\n" <> Memory.shown(memory["text"])}
  end
end
