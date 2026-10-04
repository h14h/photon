defmodule Photon.Assistant.Tools.CheckNodeSession do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.NodeWork
  alias Photon.NodeSessions
  alias PhotonCore.Message

  @impl true
  def name, do: "check_node_session"

  @impl true
  def description,
    do:
      "Look at a node session: its status, latest answer, and recent commands. Only when the user asks; reports arrive on their own."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "The node session's ID."}
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"session_id" => id}, _api) do
    with {:ok, session} <- NodeWork.known_session(id) do
      text = session |> summary_lines(recent_commands(id)) |> Enum.join("\n\n")

      {:ok, Message.parts(text),
       %{"session_id" => id, "node" => session.node_id, "title" => session.title}}
    end
  end

  # The last six finished shell commands, each with the start of its output.
  defp recent_commands(id) do
    commands =
      for %{
            "kind" => "tool_call_status",
            "data" => %{"operations" => [%{"type" => "shell"} = op]}
          } <- NodeSessions.events(id),
          op["status"] in ["completed", "failed", "canceled"],
          do: command_text(op)

    Enum.take(commands, -6)
  end

  defp command_text(op) do
    result = op["state"]["result"] || %{}
    out = String.slice(result["out"] || op["state"]["terminal_error"] || "", 0, 300)
    "$ #{op["state"]["input"]["command"]}\n#{out}"
  end

  defp summary_lines(session, commands) do
    Enum.filter(
      [
        NodeWork.session_line(session),
        session.last_failure && "Last error: #{session.last_failure}",
        session.last_answer && "Latest answer:\n#{session.last_answer}",
        commands != [] && "Recent commands:\n" <> Enum.join(commands, "\n\n")
      ],
      &is_binary/1
    )
  end
end
