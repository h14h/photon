defmodule Photon.Assistant.Tools.ReadThread do
  @moduledoc """
  Blip's `read_thread` tool: a thread's state, who started it, its open
  questions, and its latest messages, answers and a line per tool call
  (`Photon.Assistant.Readout.thread/3`), never a tool's output. The details
  name the thread, for the line in Blip's panel. Reading a thread doesn't
  mark it seen: seen is the owner's. It changes nothing, so a rerun after a
  restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.Readout

  # How many items it shows when `last` isn't given, and the most it shows.
  @default_last 20
  @max_last 50

  @impl true
  def name, do: "read_thread"

  @impl true
  def description,
    do:
      "Read a thread: its state, who started it, its open questions, and its latest " <>
        "messages, answers and tool calls (without their output)."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "thread" => %{
          "type" => "string",
          "description" => "The thread's ID, like c_123 (list_threads shows them)."
        },
        "last" => %{
          "type" => "integer",
          "description" =>
            "How many of its latest items to show, 1 to #{@max_last} (default #{@default_last})."
        }
      },
      "required" => ["thread"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"thread" => id} = args, _api) do
    with {:ok, thread} <- Assistant.find_thread(id),
         %{} = entry <- Threads.state(thread.id) do
      last = last(args["last"])
      # Each item is at most one entry, and answers that only call tools
      # make none, so four entries an item is room enough.
      entries = Threads.recent_entries(thread.id, last * 4)
      text = Readout.thread(entry, entries, %{last: last, now: DateTime.utc_now()})

      {:ok, text,
       %{"thread_id" => thread.id, "project_id" => thread.project_id, "title" => thread.title}}
    else
      {:error, message} -> {:error, message}
      nil -> {:error, Readout.unknown_thread(id)}
    end
  end

  defp last(n) when is_integer(n), do: n |> max(1) |> min(@max_last)
  defp last(_none), do: @default_last
end
