defmodule Photon.Threads.MockTitle do
  @moduledoc """
  The scripted model's answer to a thread's title request
  (`Photon.Threads.Rules.title_request/2`), for tests and for working on
  the hub without a ChatGPT sign-in (`PHOTON_MOCK_MODEL=1`). It names the
  work in the first message the way the scripted thread
  (`Photon.Threads.MockScript`) understands it:

    * `on mm1: $ df -h /` is "Run df on mm1": what the command runs, in
      order, past `sudo`, `env` and variable settings: each program by
      name, and a loop or a condition as a whole ("a for loop", "an if
      statement"), not the programs inside it. Two read "Run ps and grep
      on mm1", more "Run df, ls and more on mm1", and a program named
      twice is named once
    * `on mm1: look at shots/pump.png` is "Look at pump.png on mm1"
    * `machines` is "Check your machines", `files` "Check the context
      files"
    * `read notes.md`, `write notes.md: ...` and `edit notes.md: ...` are
      "Read notes.md", "Write notes.md" and "Edit notes.md"
    * `ask blip: which deploy branch?` is "Ask Blip about which deploy
      branch" and `ask me: which zone first?` "Ask you about which zone
      first" (the question's first five words), and `fail: ...` is "Fail
      on purpose"

  A schedule's `"[Scheduled] "` in front is dropped first, as the scripted
  thread drops it. Anything else is its first line's first five words,
  capitalized. A request that isn't a title request fails, as a model
  error.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM.Mock, Photon.Threads.Rules]

  @behaviour PhotonCore.LLM.Mock

  alias Photon.Threads.Rules
  alias PhotonCore.Message

  # Words that start a part of a command without naming a program.
  @keywords ~w(then else elif do sudo time env exec ! { })

  # The words that open a loop or a condition, what each is called in a
  # title, and the words that close them.
  @openers %{
    "for" => "a for loop",
    "while" => "a while loop",
    "until" => "an until loop",
    "select" => "a select loop",
    "if" => "an if statement",
    "case" => "a case statement"
  }
  @closers ~w(done fi esac)

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
      {~r/\Aedit\s+([^\s:]+)\s*:/, fn [name] -> "Edit #{name}" end}
    ] ++ asking_phrasings()
  end

  # Asking Blip, ending the run asking the user, and failing it.
  defp asking_phrasings do
    [
      {~r/\Aask blip\s*:\s*(\S.*)\z/s, fn [question] -> about("Ask Blip about", question) end},
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
    case runs(command) do
      [] -> "Run a command on #{machine}"
      [one] -> "Run #{one} on #{machine}"
      [one, two] -> "Run #{one} and #{two} on #{machine}"
      [one, two | _more] -> "Run #{one}, #{two} and more on #{machine}"
    end
  end

  # What a command runs, in order, each once: the parts it splits into at
  # `;`, `&&`, `||`, `|` and new lines, each named by its first word past
  # keywords and variable settings. A part that opens a loop or a
  # condition names it, and the parts up to its close are inside it.
  defp runs(command) do
    command
    |> String.split(~r/;|&&|\|\||\||\n/)
    |> Enum.map(
      &(&1
        |> String.split()
        |> Enum.drop_while(fn word -> word in @keywords or String.contains?(word, "=") end))
    )
    |> Enum.reject(&(&1 == []))
    |> Enum.reduce({[], 0}, &part/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  # A part at the top level names what it runs; inside a loop or a
  # condition it only opens or closes one.
  defp part([word | _rest], {names, 0}) when is_map_key(@openers, word),
    do: {[Map.fetch!(@openers, word) | names], 1}

  defp part([word | _rest], {names, 0}) do
    case program_name(word) do
      nil -> {names, 0}
      name -> {[name | names], 0}
    end
  end

  defp part([word | _rest], {names, depth}) when is_map_key(@openers, word),
    do: {names, depth + 1}

  defp part([word | _rest], {names, depth}) when word in @closers, do: {names, depth - 1}
  defp part(_words, acc), do: acc

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
