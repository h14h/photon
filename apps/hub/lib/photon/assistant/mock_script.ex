defmodule Photon.Assistant.MockScript do
  @moduledoc """
  The assistant's mock model, so the hub works end to end without an API
  key. It understands a few fixed phrasings:

    * `nodes` lists nodes
    * `on <node>: <task>` hands a task to a node (the node runs it with its
      own mock model unless a real one is configured)
    * `check <session id>` looks at a node session
    * `remember <fact>` adds to memory
    * `in <n> minutes: <prompt>` and `every <n> minutes: <prompt>` schedule
    * `schedules` lists schedules

  After a tool result it relays the result, minus what's meant only for a
  model (session IDs, "don't poll"). A node report gets a line saying how
  the work went; the report itself is already on the page.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]

  @behaviour PhotonCore.LLM.Mock

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @help """
  I'm Blip, on the mock model. There's no API key, so I only follow a few fixed phrasings:

  - `nodes` lists your machines
  - `on <node>: <task>` hands a task to a machine, like `on mp1: $ uptime`
  - `check <session id>` looks in on a piece of node work
  - `remember <fact>` saves something to memory
  - `in 2 minutes: <prompt>` or `every 30 minutes: <prompt>` schedules a prompt
  - `schedules` lists what's scheduled

  Add a model API key in Settings and I can do the rest.
  """

  @impl true
  def respond(request) do
    messages = request[:messages] || []

    case List.last(messages) do
      %{"role" => "tool"} = result ->
        result |> Message.text_of() |> relay() |> Message.assistant()

      %{"role" => "user"} = message ->
        message |> Message.text_of() |> String.trim() |> plan()

      _ ->
        Message.assistant(@help)
    end
  end

  defp plan("[Report from " <> _ = report), do: Message.assistant(report_line(report))

  defp plan("[Scheduled] " <> prompt), do: plan(prompt)

  defp plan(text) do
    Enum.find_value(phrasings(), Message.assistant(@help), fn {pattern, reply} ->
      case Regex.run(pattern, text, capture: :all_but_first) do
        nil -> nil
        captures -> reply.(captures)
      end
    end)
  end

  # The phrasings it understands, in the order it tries them, each with the
  # reply its captures make.
  defp phrasings do
    [
      {~r/\A(?:nodes|list nodes|machines)\z/, &list_nodes/1},
      {~r/\Aon\s+([\w.-]+)\s*:\s*(.+)\z/s, &run_on_node/1},
      {~r/\Acheck\s+(\S+)/, &check_session/1},
      {~r/\Aremember\s+(.+)\z/s, &remember/1},
      {~r/\Ain\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("in_minutes", &1)},
      {~r/\Aevery\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("every_minutes", &1)},
      {~r/\A(?:schedules|list schedules)\z/, &list_schedules/1}
    ]
  end

  defp list_nodes([]), do: call("list_nodes", %{}, "Checking your machines.")

  defp run_on_node([node, task]) do
    call(
      "run_on_node",
      %{"node" => node, "task" => task, "wait_seconds" => 5},
      "Handing that to #{node}."
    )
  end

  defp check_session([session_id]),
    do: call("check_node_session", %{"session_id" => session_id}, "Looking.")

  defp remember([fact]), do: call("update_memory", %{"action" => "add", "text" => fact}, "Noted.")

  defp schedule(key, [minutes, prompt]),
    do:
      call("schedule", %{"prompt" => prompt, key => String.to_integer(minutes)}, "Scheduling it.")

  defp list_schedules([]), do: call("list_schedules", %{}, "Here's what's scheduled.")

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])

  # The report's header says which node and how it ended; see
  # Photon.Assistant.Report.
  defp report_line(report) do
    case Regex.run(~r/\A\[Report from ([^\]]+)\][^\n]*? (finished|didn't finish)/, report) do
      [_, node, "finished"] -> "#{node} finished. Its report is above."
      [_, node, "didn't finish"] -> "#{node} didn't finish. The report above says why."
      nil -> "A report came in. It's above."
    end
  end

  defp relay("Error: " <> error), do: "That didn't work: " <> error

  defp relay(text) do
    case Regex.run(~r/\AStarted on (\S+) as session \S+ and still running/, text) do
      [_, node] -> "#{node} is on it. I'll pass on its report when it's done."
      nil -> String.replace(text, ~r/ \(session [^)\s]+\)/, "", global: false)
    end
  end
end
