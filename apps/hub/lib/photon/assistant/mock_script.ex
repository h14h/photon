defmodule Photon.Assistant.MockScript do
  @moduledoc """
  The assistant's scripted model, for tests and for working on the hub
  without a ChatGPT sign-in (`PHOTON_MOCK_MODEL=1` in development). It
  understands a few fixed phrasings:

    * `machines` lists machines (`list_machines`), and `nodes` lists
      nodes (`list_nodes`)
    * `on <machine>: $ <command>` runs a command (`shell`)
    * `on <machine>: look at <path>` looks at an image (`view_image`)
    * `on <node>: <task>` (anything else) hands a task to a node's agent
      (the node runs it with its own mock model unless a real one is
      configured)
    * `check <session id>` looks at a node session
    * `remember <fact>` adds to memory
    * `in <n> minutes: <prompt>` and `every <n> minutes: <prompt>` schedule
    * `schedules` lists schedules

  After a tool result it relays the result, minus what's meant only for a
  model (session IDs, "don't poll"). An image result gets "Here it is."
  and its dimensions line. A node report gets a line saying how the work
  went; the report itself is already on the page.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM, Photon.Assistant.Page]

  @behaviour PhotonCore.LLM.Mock

  alias Photon.Assistant.Page
  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @help """
  I'm Blip, on the scripted model, so I only follow a few fixed phrasings:

  - `machines` lists your machines
  - `on <machine>: $ <command>` runs a command there, like `on mp1: $ uptime`
  - `on <machine>: look at <path>` shows me an image file there
  - `on <machine>: <task>` hands a longer task to that machine's own agent
  - `check <session id>` looks in on a piece of node work
  - `remember <fact>` saves something to memory
  - `in 2 minutes: <prompt>` or `every 30 minutes: <prompt>` schedules a prompt
  - `schedules` lists what's scheduled

  Sign in with ChatGPT and I can do the rest.
  """

  @impl true
  def respond(request) do
    messages = request[:messages] || []

    case List.last(messages) do
      %{"role" => "tool"} = result ->
        result |> relay_result() |> Message.assistant()

      %{"role" => "user"} = message ->
        message |> Message.text_of() |> String.trim() |> plan()

      _ ->
        Message.assistant(@help)
    end
  end

  defp plan("[Report from " <> _ = report), do: Message.assistant(report_line(report))

  defp plan("[Scheduled] " <> prompt), do: plan(prompt)

  # A message sent from a page reads as the user typed it.
  defp plan("[Looking at " <> _ = text), do: text |> Page.strip() |> String.trim() |> plan()

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
      {~r/\A(?:list )?(machines|nodes)\z/, &list/1},
      {~r/\Aon\s+([\w.-]+)\s*:\s*(.+)\z/s, &on_machine/1},
      {~r/\Acheck\s+(\S+)/, &check_session/1},
      {~r/\Aremember\s+(.+)\z/s, &remember/1},
      {~r/\Ain\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("in_minutes", &1)},
      {~r/\Aevery\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("every_minutes", &1)},
      {~r/\A(?:schedules|list schedules)\z/, &list_schedules/1}
    ]
  end

  # `nodes` keeps calling list_nodes until node sessions go.
  defp list(["machines"]), do: call("list_machines", %{}, "Checking your machines.")
  defp list(["nodes"]), do: call("list_nodes", %{}, "Checking your machines.")

  # `$ <command>` runs a command, `look at <path>` looks at an image, and
  # anything else goes to the node's agent.
  defp on_machine([machine, "$" <> command]),
    do:
      call(
        "shell",
        %{"machine" => machine, "command" => String.trim(command)},
        "Running that on #{machine}."
      )

  defp on_machine([machine, "look at " <> path]),
    do:
      call(
        "view_image",
        %{"machine" => machine, "path" => String.trim(path)},
        "Looking at it on #{machine}."
      )

  defp on_machine(captures), do: run_on_node(captures)

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

  # An image result has the image and a line with its size and path.
  defp relay_result(result) do
    case Message.images(result) do
      [] -> result |> Message.text_of() |> relay()
      _images -> "Here it is.\n\n" <> Message.text_of(result)
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
