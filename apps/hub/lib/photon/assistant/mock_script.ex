defmodule Photon.Assistant.MockScript do
  @moduledoc """
  The assistant's scripted model, for tests and for working on the hub
  without a ChatGPT sign-in (`PHOTON_MOCK_MODEL=1` in development). It
  understands the fixed phrasings its help reply lists, tried in order:
  `Photon.MachineTools.MockPhrases` and `Photon.Skills.MockPhrases`
  (shared with a thread's scripted model), then
  `Photon.Assistant.MockCoordinator`'s, then its own.

  It reads the last text part of the user's message, which is what the
  user typed: a message sent from a page has the page's note in front of
  it, as a part of its own. A message the user didn't type (a thread's
  question or update, a digest or review, or the user's answer to a
  question going by) is `Photon.Assistant.MockCoordinator.unasked/2`'s.

  After a tool result it relays the result; a result of its tools over
  threads is said for the owner, by title and without IDs
  (`Photon.Assistant.MockCoordinator.relay/3`).
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [
      PhotonCore,
      PhotonCore.LLM.Mock,
      Photon.Assistant.MockAmbient,
      Photon.Assistant.MockCoordinator,
      Photon.MachineTools.MockPhrases,
      Photon.Skills.MockPhrases
    ]

  @behaviour PhotonCore.LLM.Mock

  alias Photon.Assistant.{MockAmbient, MockCoordinator}
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
  - `skills` lists the skills turned on for me, and for each machine
  - `load skill <name>` loads one, like `load skill pdf-forms`
  #{MockCoordinator.help()}#{MockAmbient.help()}
  Sign in with ChatGPT and I can do the rest.
  """

  @impl true
  def respond(request) do
    messages = request[:messages] || []

    case List.last(messages) do
      %{"role" => "tool"} = result ->
        name = called(messages, result["tool_call_id"])
        relayed = MockPhrases.relay_result(result)
        Message.assistant(MockCoordinator.relay(name, Message.text_of(result), relayed))

      %{"role" => "user", "content" => content} ->
        MockCoordinator.unasked(texts(content), request) || typed(content, request)

      _ ->
        Message.assistant(@help)
    end
  end

  defp called(messages, id) do
    Enum.find_value(messages, fn message ->
      Enum.find_value(Message.tool_calls(message), &(&1["id"] == id and &1["name"]))
    end)
  end

  defp typed(content, request) do
    {note, typed} = split(content)
    typed |> String.trim() |> plan(note, request)
  end

  defp texts(content) when is_list(content),
    do: for(%{"type" => "text", "text" => text} when is_binary(text) <- content, do: text)

  defp texts(content), do: [Message.text_of(content)]

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

  # In the order it tries them, each with the reply its captures make.
  defp phrasings(request) do
    MockPhrases.phrasings() ++
      SkillPhrases.phrasings(request) ++
      MockCoordinator.phrasings(request) ++
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
