defmodule Photon.Threads.MockTitle do
  @moduledoc """
  The scripted model's answer to a thread's title request
  (`Photon.Threads.Rules.title_request/2`), for tests and for working on
  the hub without a ChatGPT sign-in (`PHOTON_MOCK_MODEL=1`). It names the
  work in the first message the way the scripted thread
  (`Photon.Threads.MockScript`) understands it:

    * `on mm1: $ df -h /` is "Run df on mm1" (the first program the
      command runs, past shell keywords and loops)
    * `on mm1: look at shots/pump.png` is "Look at pump.png on mm1"
    * `machines` is "Check your machines", `files` "Check the context
      files"
    * `read notes.md`, `write notes.md: ...` and `edit notes.md: ...` are
      "Read notes.md", "Write notes.md" and "Edit notes.md"
    * `ask me: which zone first?` is "Ask you about which zone first" (the
      question's first five words), and `fail: ...` is "Fail on purpose"

  A schedule's `"[Scheduled] "` in front is dropped first, as the scripted
  thread drops it. Anything else is its first line's first five words,
  capitalized. A request that isn't a title request fails, as a model
  error.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM, Photon.Threads.Rules]

  @behaviour PhotonCore.LLM.Mock

  alias Photon.Threads.Rules
  alias PhotonCore.Message

  # Words that start a shell command without naming a program.
  @keywords ~w(for while until if then else elif do done fi case esac in sudo time env exec ! { })

  @impl true
  def respond(request) do
    with %{"role" => "user"} = message <- List.last(request[:messages] || []),
         text when is_binary(text) <- Rules.requested_message(Message.text_of(message)) do
      text
      |> String.trim()
      |> String.replace_prefix("[Scheduled] ", "")
      |> title()
      |> Message.assistant()
    else
      _other -> {:error, "The scripted title model only answers title requests."}
    end
  end

  defp title(text) do
    Enum.find_value(phrasings(), fn {pattern, title} ->
      case Regex.run(pattern, text, capture: :all_but_first) do
        nil -> nil
        captures -> title.(captures)
      end
    end) || first_words(text)
  end

  defp phrasings do
    [
      {~r/\A(?:list )?machines\z/, fn [] -> "Check your machines" end},
      {~r/\Aon\s+([\w.-]+)\s*:\s*\$(.+)\z/s, &run/1},
      {~r/\Aon\s+([\w.-]+)\s*:\s*look at\s+(\S+)/,
       fn [m, path] -> "Look at #{Path.basename(path)} on #{m}" end},
      {~r/\A(?:list )?files\z/, fn [] -> "Check the context files" end},
      {~r/\Aread\s+([^\s:]+)\z/, fn [name] -> "Read #{name}" end},
      {~r/\Awrite\s+([^\s:]+)\s*:/, fn [name] -> "Write #{name}" end},
      {~r/\Aedit\s+([^\s:]+)\s*:/, fn [name] -> "Edit #{name}" end},
      {~r/\Aask me\s*:\s*(\S.*)\z/s, fn [question] -> about("Ask you about", question) end},
      {~r/\Afail\s*:\s*\S/, fn [] -> "Fail on purpose" end}
    ]
  end

  # `prefix` and the first five words of `text`'s first line, without the
  # punctuation they end on.
  defp about(prefix, text) do
    words =
      text
      |> Rules.title()
      |> String.trim_trailing("...")
      |> String.split()
      |> Enum.take(5)
      |> Enum.join(" ")
      |> String.replace(~r/[?!.,;:]+\z/u, "")

    "#{prefix} #{words}"
  end

  defp run([machine, command]) do
    case program(command) do
      nil -> "Run a command on #{machine}"
      program -> "Run #{program} on #{machine}"
    end
  end

  # The first program a command runs: the first word of the first part
  # (split at `;`, `&&`, `||`, `|` and new lines) that isn't a loop or a
  # condition, past keywords and variable settings.
  defp program(command) do
    command
    |> String.split(~r/;|&&|\|\||\||\n/)
    |> Enum.map(&String.split/1)
    |> Enum.reject(&match?([word | _] when word in ~w(for while until if case select), &1))
    |> Enum.find_value(fn words ->
      words
      |> Enum.drop_while(&(&1 in @keywords or String.contains?(&1, "=")))
      |> List.first()
      |> program_name()
    end)
  end

  defp program_name(nil), do: nil

  defp program_name(word),
    do: word |> String.replace(~r/\A["'($]+|["')]+\z/, "") |> Path.basename() |> blank_nil()

  defp blank_nil(""), do: nil
  defp blank_nil(word), do: word

  defp upcase_first(word) do
    {head, rest} = String.split_at(word, 1)
    String.upcase(head) <> rest
  end

  defp first_words(text) do
    case text |> Rules.title() |> String.trim_trailing("...") |> String.split() |> Enum.take(5) do
      [] -> "Untitled thread"
      [first | rest] -> Enum.join([upcase_first(first) | rest], " ")
    end
  end
end
