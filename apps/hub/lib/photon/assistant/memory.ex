defmodule Photon.Assistant.Memory do
  @moduledoc """
  The assistant's memory: a text of lines kept in the global `"memory"` doc
  and shown in its system prompt. Pure; `update_memory` and the web page
  commit what these functions return.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @doc "An empty memory doc."
  @spec empty() :: map()
  def empty, do: %{"text" => ""}

  @doc """
  Edits a memory doc: `"add"` appends `text` as a `- ` line, `"remove"`
  drops every line containing `text`, `"rewrite"` replaces it all.
  """
  @spec edit(map(), String.t(), String.t()) :: map()
  def edit(%{"text" => current} = doc, action, text) do
    lines = String.split(current, "\n", trim: true)
    %{doc | "text" => Enum.join(edit_lines(lines, action, text), "\n")}
  end

  defp edit_lines(lines, "add", text),
    do: List.insert_at(lines, -1, "- " <> String.trim_leading(String.trim(text), "- "))

  defp edit_lines(lines, "remove", text), do: Enum.reject(lines, &String.contains?(&1, text))
  defp edit_lines(_lines, "rewrite", text), do: String.split(String.trim(text), "\n")

  @doc "The doc that replaces memory with `text`, as the web page saves it."
  @spec replace(String.t()) :: map()
  def replace(text), do: %{"text" => String.trim(text)}

  @doc "Memory as the model reads it: the text, or `(empty)`."
  @spec shown(String.t()) :: String.t()
  def shown(""), do: "(empty)"
  def shown(text), do: text
end
