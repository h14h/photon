defmodule PhotonCore.LLM.MockAgent do
  @moduledoc """
  The built-in mock model for node sessions: it doesn't think, but it drives
  the harness's real tools, so everything else can be tried without an API
  key. It reads only the latest prompt:

    * `$ <command>` runs the command with Bash
    * `view <path>` opens an image with ViewImage
    * `sleep <n>` runs a slow command, to watch an asynchronous result arrive
    * `help` lists these
    * anything else lists the workspace

  Once the result is back it reports it and ends the turn. While the call is
  still running it says so and ends the turn, so the harness wakes it when the
  result lands.

  A pure function of the request, except that a new call gets a fresh ID
  (`PhotonCore.LLM.Mock.call/2`).
  """

  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM.Mock, Jason]

  @behaviour PhotonCore.LLM.Mock

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @help """
  I'm the built-in mock model. I don't think, but I do drive the harness's real tools:

  - `$ <command>` runs a shell command with **Bash**
  - `view <path>` opens an image with **ViewImage**
  - `sleep <seconds>` runs a slow command, so you can watch its result land in a later turn
  - anything else lists the workspace

  Pick a real model in the hub's settings to get an actual agent.
  """

  @running "Tool call is still running."
  @late "Result of the earlier"

  @impl true
  def respond(request) do
    {prompt, since} = latest_prompt(request[:messages] || [])
    calls = for %{"role" => "assistant"} = m <- since, call <- Message.tool_calls(m), do: call
    answer(plan(prompt), calls, results(since))
  end

  # Help needs no tool; otherwise the first answer to a prompt makes the
  # call, and later ones report its result or say it's still running.
  defp answer(:help, _calls, _results), do: Message.assistant(@help)

  defp answer({tool, args, intro}, [] = _no_calls_yet, _results),
    do: Message.assistant(intro, [Mock.call(tool, args)])

  defp answer(_plan, [call | _], results), do: follow_up(call, Map.fetch(results, call["id"]))

  defp follow_up(call, {:ok, output}), do: Message.assistant(report(call, output))

  defp follow_up(call, :error),
    do:
      Message.assistant(
        "Still waiting on #{describe(call)}; I'll pick it up when the result lands."
      )

  # The prompt is the latest user message that isn't a late result or a
  # heartbeat; `since` is everything after it.
  defp latest_prompt(messages) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {message, _index} -> prompt?(message) end)
    |> List.last()
    |> split_at_prompt(messages)
  end

  defp prompt?(message),
    do: message["role"] == "user" and not machine_note?(Message.text_of(message))

  defp machine_note?(text),
    do: String.starts_with?(text, @late) or String.starts_with?(text, "Heartbeat:")

  defp split_at_prompt(nil, messages), do: {"", messages}

  defp split_at_prompt({prompt, index}, messages),
    do: {Message.text_of(prompt), Enum.drop(messages, index + 1)}

  # Final results by call ID: tool messages that aren't placeholders, and
  # late results that arrived as user messages.
  defp results(messages), do: Enum.reduce(messages, %{}, &add_result/2)

  defp add_result(%{"role" => "tool", "tool_call_id" => id} = message, results) do
    add_final(results, id, message, String.starts_with?(Message.text_of(message), @running))
  end

  defp add_result(%{"role" => "user"} = message, results) do
    case Regex.run(late_result(), Message.text_of(message)) do
      [_, id] -> Map.put(results, id, late_output(message))
      nil -> results
    end
  end

  defp add_result(_message, results), do: results

  defp add_final(results, _id, _message, true = _placeholder), do: results
  defp add_final(results, id, message, false), do: Map.put(results, id, output(message))

  defp late_result, do: ~r/\A#{@late} \S+ tool call (\S+), which has now finished:/

  # A late result's first line says which call it was; the output follows.
  defp late_output(message), do: message |> output() |> String.replace(~r/\A[^\n]*:\n*/, "")

  defp output(message), do: describe_images(Message.images(message)) <> Message.text_of(message)

  defp describe_images([]), do: ""
  defp describe_images(images), do: "#{length(images)} image(s). "

  defp plan(text) do
    text = String.trim(text)

    cond do
      text in ["help", "?", "/help"] ->
        :help

      String.starts_with?(text, "$") ->
        command = text |> String.trim_leading("$") |> String.trim()
        {"Bash", %{"command" => command}, "Running `#{command}`."}

      match = Regex.run(~r/\A(?:view|image|show)\s+(\S+)/i, text) ->
        path = List.last(match)
        {"ViewImage", %{"path" => path}, "Opening `#{path}`."}

      match = Regex.run(~r/\Asleep\s*(\d+)?/i, text) ->
        seconds = match |> Enum.at(1, "3") |> String.to_integer() |> min(600)
        command = "for i in $(seq #{seconds}); do echo tick $i; sleep 1; done; echo done"

        {"Bash", %{"command" => command},
         "Starting a #{seconds}s command. It runs asynchronously, so I'll end my turn while it works."}

      true ->
        {"Bash", %{"command" => "pwd && ls -la"},
         "I'm the mock model (type `help` for what I can do). Here's the workspace:"}
    end
  end

  defp report(call, output) do
    """
    #{describe(call)} finished:

    ```
    #{String.slice(output, 0, 4000)}
    ```
    """
    |> String.trim()
  end

  defp describe(%{"name" => "Bash", "arguments" => args}) do
    case Jason.decode(args) do
      {:ok, %{"command" => command}} -> "`#{command}`"
      _ -> "Bash"
    end
  end

  defp describe(%{"name" => name, "arguments" => args}), do: "#{name} #{args}"
end
