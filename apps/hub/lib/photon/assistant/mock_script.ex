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
    * `here` says the first line of the page note the message came with
      (`Photon.Assistant.Page.note/2`), or that it doesn't know the page
    * `skills` says which skills the prompt lists, and `load skill <name>`
      loads one (`load_skill`)

  It reads the last text part of the user's message, which is what the
  user typed: a message sent from a page has the page's note in front of
  it, as a part of its own.

  After a tool result it relays the result. An image result gets "Here it
  is." and its dimensions line.

  The three machine phrasings and the relay are
  `Photon.MachineTools.MockPhrases`, and the skill phrasings
  `Photon.Skills.MockPhrases`; a thread's scripted model uses both too.
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [PhotonCore, PhotonCore.LLM, Photon.MachineTools, Photon.Skills]

  @behaviour PhotonCore.LLM.Mock

  alias Photon.MachineTools.MockPhrases
  alias Photon.Skills.MockPhrases, as: SkillPhrases
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
  - `here` tells you which page you're on, as I see it
  - `skills` lists the skills turned on for me
  - `load skill <name>` loads one, like `load skill pdf-forms`

  Sign in with ChatGPT and I can do the rest.
  """

  @impl true
  def respond(request) do
    messages = request[:messages] || []

    case List.last(messages) do
      %{"role" => "tool"} = result ->
        result |> MockPhrases.relay_result() |> Message.assistant()

      %{"role" => "user", "content" => content} ->
        {note, typed} = split(content)
        typed |> String.trim() |> plan(note, request)

      _ ->
        Message.assistant(@help)
    end
  end

  # The note of the page (nil without one) and what the user typed: the
  # last text part.
  defp split(content) when is_list(content) do
    case for(%{"type" => "text", "text" => text} <- content, do: text) do
      [] -> {nil, ""}
      [typed] -> {nil, typed}
      ["[Looking at" <> _ = note | _] = texts -> {note, List.last(texts)}
      texts -> {nil, List.last(texts)}
    end
  end

  defp split(content), do: {nil, Message.text_of(content)}

  defp plan("[Scheduled] " <> prompt, note, request), do: plan(prompt, note, request)

  defp plan(text, note, request) do
    if Regex.match?(~r/\Ahere\??\z/i, text), do: here(note), else: plan(text, request)
  end

  defp plan(text, request) do
    Enum.find_value(phrasings(request), Message.assistant(@help), fn {pattern, reply} ->
      case Regex.run(pattern, text, capture: :all_but_first) do
        nil -> nil
        captures -> reply.(captures)
      end
    end)
  end

  # The phrasings it understands, in the order it tries them, each with the
  # reply its captures make: the shared machine and skill ones first.
  defp phrasings(request) do
    MockPhrases.phrasings() ++
      SkillPhrases.phrasings(request) ++
      [
        {~r/\Aremember\s+(.+)\z/s, &remember/1},
        {~r/\Ain\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("in_minutes", &1)},
        {~r/\Aevery\s+(\d+)\s+minutes?\s*:\s*(.+)\z/s, &schedule("every_minutes", &1)},
        {~r/\A(?:schedules|list schedules)\z/, &list_schedules/1}
      ]
  end

  defp here(nil), do: Message.assistant("I don't know which page you're on.")
  defp here(note), do: note |> String.split("\n", parts: 2) |> hd() |> Message.assistant()

  defp remember([fact]), do: call("update_memory", %{"action" => "add", "text" => fact}, "Noted.")

  defp schedule(key, [minutes, prompt]),
    do:
      call("schedule", %{"prompt" => prompt, key => String.to_integer(minutes)}, "Scheduling it.")

  defp list_schedules([]), do: call("list_schedules", %{}, "Here's what's scheduled.")

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])
end
