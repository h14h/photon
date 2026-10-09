defmodule Photon.Threads.MockScript do
  @moduledoc """
  A thread's scripted model, for tests and for working on the hub without a
  ChatGPT sign-in (`PHOTON_MOCK_MODEL=1` in development). It understands a
  few fixed phrasings:

    * `machines`, `on <machine>: $ <command>` and
      `on <machine>: look at <path>`, the same as Blip's
      (`Photon.MachineTools.MockPhrases`)
    * `files` or `list files` lists the context files
      (`list_context_files`)
    * `read <name>` reads one (`read_context_file`)
    * `write <name>: <text>` writes `<text>`, which may run over several
      lines, as the whole file (`write_context_file`)
    * `edit <name>: <old> => <new>` changes one passage
      (`edit_context_file`)
    * `skills` says which skills the prompt lists, and `load skill <name>`
      loads one (`load_skill`), the same as Blip's
      (`Photon.Skills.MockPhrases`)
    * `ask blip: <question>` asks Blip the question (`ask_blip`), and the
      call waits for the answer, which it then relays
    * `ask me: <question>` answers with the question, ending in `?`, so
      the run ends asking the user and the thread waits on them
    * `fail: <reason>` fails the model request with `<reason>`, so the
      run fails (the scripted model's errors aren't retried)

  After a tool result it relays the result, as Blip's does (Blip's answer
  to `ask_blip` as prose). Anything else
  gets a help text. It reads the last text part of the last user message,
  without a leading `"[Scheduled] "`, as Blip's does, so a project
  schedule's prompt such as `on local: $ uptime` runs on it too.
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
  This thread is on the scripted model, so it only follows a few fixed phrasings:

  - `machines` lists your machines
  - `on <machine>: $ <command>` runs a command in the project's folder there, like `on mp1: $ ls`
  - `on <machine>: look at <path>` looks at an image file there
  - `files` lists the project's context files
  - `read <name>` reads one, like `read notes.md`
  - `write <name>: <text>` writes a whole file
  - `edit <name>: <old text> => <new text>` changes one passage
  - `skills` lists the skills turned on for this project, and for each machine
  - `load skill <name>` loads one, like `load skill pdf-forms`
  - `ask blip: <question>` asks Blip, like `ask blip: which deploy branch?`
  - `ask me: <question>` ends the run asking you, like `ask me: which zone first?`
  - `fail: <reason>` makes the run fail, like `fail: the pump is unplugged`

  Sign in with ChatGPT and it can do the rest.
  """

  @impl true
  def respond(request) do
    messages = request[:messages] || []

    case List.last(messages) do
      %{"role" => "tool"} = result ->
        result |> relay() |> Message.assistant()

      %{"role" => "user"} = message ->
        message |> last_text() |> String.trim() |> plan(request)

      _ ->
        Message.assistant(@help)
    end
  end

  # Blip's answer to `ask_blip` reads as prose, a paragraph a line ("Blip
  # asked the user: ...", "They answered: ..."), not as printed output.
  defp relay(result) do
    text = Message.text_of(result)

    if String.starts_with?(text, ["Blip answered: ", "Blip asked the user: "]),
      do: String.replace(text, ~r/\n+/, "\n\n"),
      else: MockPhrases.relay_result(result)
  end

  # The last text part: what the user typed, after any note put before it.
  defp last_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> List.last(%{"text" => ""})
    |> Map.fetch!("text")
  end

  defp last_text(message), do: Message.text_of(message)

  defp plan("[Scheduled] " <> text, request), do: plan(text, request)

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
        {~r/\A(?:list )?files\z/, &list_files/1},
        {~r/\Aread\s+([^\s:]+)\z/, &read/1},
        {~r/\Awrite\s+([^\s:]+)\s*:\s*(.*)\z/s, &write/1},
        {~r/\Aedit\s+([^\s:]+)\s*:\s*(.+?)\s*=>\s*(.*)\z/s, &edit/1}
      ] ++ asking_phrasings()
  end

  # Asking Blip, ending the run asking the user, and failing it.
  defp asking_phrasings do
    [
      {~r/\Aask blip\s*:\s*(\S.*)\z/s, &ask_blip/1},
      {~r/\Aask me\s*:\s*(\S.*)\z/s, &ask_me/1},
      {~r/\Afail\s*:\s*(\S.*)\z/s, &fail/1}
    ]
  end

  defp list_files([]), do: call("list_context_files", %{}, "Checking the context files.")

  defp read([name]), do: call("read_context_file", %{"name" => name}, "Reading #{name}.")

  defp write([name, content]),
    do:
      call(
        "write_context_file",
        %{"name" => name, "content" => content},
        "Writing #{name}."
      )

  defp edit([name, old_text, new_text]),
    do:
      call(
        "edit_context_file",
        %{"name" => name, "old_text" => old_text, "new_text" => new_text},
        "Editing #{name}."
      )

  defp ask_blip([question]),
    do: call("ask_blip", %{"question" => String.trim(question)}, "Asking Blip.")

  # The question as the answer, so the run ends asking.
  defp ask_me([question]) do
    question
    |> String.trim()
    |> String.trim_trailing("?")
    |> Kernel.<>("?")
    |> Message.assistant()
  end

  defp fail([reason]), do: {:error, String.trim(reason)}

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])
end
