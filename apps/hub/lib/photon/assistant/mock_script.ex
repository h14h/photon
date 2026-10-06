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

  The three machine phrasings and the relay are
  `Photon.MachineTools.MockPhrases`, which a thread's scripted model uses
  too.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM, Photon.MachineTools]

  @behaviour PhotonCore.LLM.Mock

  alias Photon.MachineTools.MockPhrases
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
        result |> MockPhrases.relay_result() |> Message.assistant()

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
  # reply its captures make: the shared machine ones first.
  defp phrasings do
    MockPhrases.phrasings() ++
      [
        {~r/\Aremember\s+(.+)\z/s, &remember/1},
        {~r/\Ain\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("in_minutes", &1)},
        {~r/\Aevery\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("every_minutes", &1)},
        {~r/\A(?:schedules|list schedules)\z/, &list_schedules/1}
      ]
  end

  defp remember([fact]), do: call("update_memory", %{"action" => "add", "text" => fact}, "Noted.")

  defp schedule(key, [minutes, prompt]),
    do:
      call("schedule", %{"prompt" => prompt, key => String.to_integer(minutes)}, "Scheduling it.")

  defp list_schedules([]), do: call("list_schedules", %{}, "Here's what's scheduled.")

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])
end
