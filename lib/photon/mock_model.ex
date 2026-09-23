defmodule Photon.MockModel do
  @moduledoc """
  A deterministic stand-in for an OpenAI Responses API model, so the harness
  can be exercised end to end without an API key.

  It looks only at the conversation since the latest user message:

    * `$ <command>` runs the command with Bash
    * `view <path>` opens an image with ViewImage
    * `sleep <n>` runs a slow command, to watch async tool results arrive
    * `help` lists these
    * anything else lists the workspace with Bash

  Once the tool result is back it reports it and ends the turn.
  """

  # The harness sends this placeholder while an operation is still running.
  @running_prefix "Tool call is still running."

  @help """
  I'm the built-in mock model. I don't think, but I do drive the harness's real tools:

  - `$ <command>` runs a shell command with **Bash**
  - `view <path>` opens an image with **ViewImage**, as does attaching one
  - `sleep <seconds>` runs a slow command so you can watch the async result land in a later turn
  - anything else lists the workspace

  Switch the provider in Settings to talk to a real model.
  """

  def respond(request) do
    input = request["input"] || []

    since_user =
      input |> Enum.reverse() |> Enum.take_while(&(!user_message?(&1))) |> Enum.reverse()

    user_text = input |> Enum.filter(&user_message?/1) |> List.last() |> message_text()

    calls = Enum.filter(since_user, &(&1["type"] == "function_call"))

    outputs =
      for %{"type" => "function_call_output"} = item <- since_user,
          text = output_text(item["output"]),
          not String.starts_with?(text, @running_prefix),
          into: %{},
          do: {item["call_id"], text}

    output =
      case {plan(user_text), calls} do
        {:help, _} ->
          [message(@help)]

        {{tool, args, intro}, []} ->
          [message(intro), function_call(tool, args)]

        {_, [call | _]} ->
          case Map.fetch(outputs, call["call_id"]) do
            {:ok, output} ->
              [message(report(call, output))]

            :error ->
              [
                message(
                  "Still waiting on #{describe(call)}. I'll pick it up when the result lands."
                )
              ]
          end
      end

    response(input, output)
  end

  defp plan(text) do
    # Commands come from the user's own words, not the attachment note.
    {text, images} = Photon.Attachments.split(String.trim(text || ""))

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
        seconds = match |> Enum.at(1, "3") |> String.to_integer() |> min(120)
        command = "for i in $(seq #{seconds}); do echo tick $i; sleep 1; done; echo done"

        {"Bash", %{"command" => command},
         "Starting a #{seconds}s command. It runs asynchronously, so this turn ends while it works."}

      images != [] ->
        path = hd(images)
        {"ViewImage", %{"path" => path}, "Taking a look at the image you attached (`#{path}`)."}

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
  end

  defp describe(%{"name" => "Bash", "arguments" => args}) do
    "`#{Jason.decode!(args)["command"]}`"
  end

  defp describe(%{"name" => name, "arguments" => args}), do: "#{name} #{args}"

  defp user_message?(item), do: item["role"] == "user" and item["type"] in [nil, "message"]

  defp message_text(nil), do: ""
  defp message_text(%{"content" => content}), do: output_text(content)

  defp output_text(text) when is_binary(text), do: text

  defp output_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} -> text
      %{"type" => "input_image"} -> "[image]"
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp output_text(_), do: ""

  defp message(text) do
    %{
      "id" => "msg_" <> random_id(),
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }
  end

  defp function_call(name, args) do
    id = random_id()

    %{
      "id" => "fc_" <> id,
      "type" => "function_call",
      "call_id" => "call_" <> id,
      "name" => name,
      "status" => "completed",
      "arguments" => Jason.encode!(args)
    }
  end

  defp response(input, output) do
    input_tokens = div(byte_size(Jason.encode!(input)), 4)
    output_tokens = div(byte_size(Jason.encode!(output)), 4)

    %{
      "id" => "resp_" <> random_id(),
      "object" => "response",
      "status" => "completed",
      "model" => "mock-model",
      "output" => output,
      "usage" => %{
        "input_tokens" => input_tokens,
        "input_tokens_details" => %{"cached_tokens" => 0},
        "output_tokens" => output_tokens,
        "output_tokens_details" => %{"reasoning_tokens" => 0},
        "total_tokens" => input_tokens + output_tokens
      }
    }
  end

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
