defmodule Photon.Assistant.MockScript do
  @moduledoc """
  The assistant's scripted model, for tests and for working on the hub
  without a ChatGPT sign-in (`PHOTON_MOCK_MODEL=1` in development). It
  understands a few fixed phrasings:

    * `machines` lists machines (`list_machines`)
    * `on <machine>: $ <command>` runs a command (`shell`)
    * `on <machine>: look at <path>` looks at an image (`view_image`)
    * `remember <fact>` adds to memory
    * `in <n> minutes: <prompt>` and `every <n> minutes: <prompt>` schedule
    * `schedules` lists schedules

  After a tool result it relays the result. An image result gets "Here it
  is." and its dimensions line.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]

  @behaviour PhotonCore.LLM.Mock

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @help """
  I'm Blip, on the scripted model, so I only follow a few fixed phrasings:

  - `machines` lists your machines
  - `on <machine>: $ <command>` runs a command there, like `on mp1: $ uptime`
  - `on <machine>: look at <path>` shows me an image file there
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
      {~r/\A(?:list )?machines\z/, &list_machines/1},
      {~r/\Aon\s+([\w.-]+)\s*:\s*\$(.+)\z/s, &shell/1},
      {~r/\Aon\s+([\w.-]+)\s*:\s*look at (.+)\z/s, &view_image/1},
      {~r/\Aremember\s+(.+)\z/s, &remember/1},
      {~r/\Ain\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("in_minutes", &1)},
      {~r/\Aevery\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("every_minutes", &1)},
      {~r/\A(?:schedules|list schedules)\z/, &list_schedules/1}
    ]
  end

  defp list_machines([]), do: call("list_machines", %{}, "Checking your machines.")

  defp shell([machine, command]),
    do:
      call(
        "shell",
        %{"machine" => machine, "command" => String.trim(command)},
        "Running that on #{machine}."
      )

  defp view_image([machine, path]),
    do:
      call(
        "view_image",
        %{"machine" => machine, "path" => String.trim(path)},
        "Looking at it on #{machine}."
      )

  defp remember([fact]), do: call("update_memory", %{"action" => "add", "text" => fact}, "Noted.")

  defp schedule(key, [minutes, prompt]),
    do:
      call("schedule", %{"prompt" => prompt, key => String.to_integer(minutes)}, "Scheduling it.")

  defp list_schedules([]), do: call("list_schedules", %{}, "Here's what's scheduled.")

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])

  # An image result has the image and a line with its size and path.
  defp relay_result(result) do
    case Message.images(result) do
      [] -> result |> Message.text_of() |> relay()
      _images -> "Here it is.\n\n" <> Message.text_of(result)
    end
  end

  defp relay("Error: " <> error), do: "That didn't work: " <> error
  defp relay(text), do: text
end
