defmodule PhotonCore.LLM.Responses.Request do
  @moduledoc """
  The request half of the OpenAI Responses API, as pure functions: a
  `PhotonCore.LLM` request becomes a request body.

  The body is stateless (`"store": false`), so every request carries the
  whole conversation. The model's encrypted reasoning comes back with each
  answer and is stored on the assistant message (`"reasoning_items"`), so
  later requests hand it back and the model keeps its train of thought
  across tool calls.

  Each message becomes input items:

    * a user message: one `"message"` with `input_text` and `input_image`
      parts
    * an assistant message: its reasoning items, a `"message"` with its
      text, and a `"function_call"` per tool call. Arguments that aren't a
      JSON object (the model wrote bad JSON) go back as
      `{"invalid_arguments": "<what it wrote>"}`, so the API accepts the
      model's own malformed call when it's replayed.
    * a tool result: a `"function_call_output"` with its text. Images can't
      go there, so the round's images follow in one user message, each
      after a caption naming its call.

  Tools go in one namespace (`"functions"`), as Sign in with ChatGPT asks.
  Tools the API runs itself (`config[:hosted_tools]`) go beside it; what
  they did comes back as output items (a `"web_search_call"`), kept with
  the reasoning items and handed back the same way, in order. `:cache_key`
  becomes the `prompt_cache_key`, so a conversation's growing history is
  cached between turns. Sign in with ChatGPT accepts no output cap or
  sampling settings, so `:max_tokens` isn't sent.
  """

  use Boundary, type: :strict, deps: [PhotonCore, Jason]

  alias PhotonCore.Message

  @caption "Image from tool call "

  @doc "The request body for `request`; `config`'s `:extra_body` is merged in last."
  @spec encode(map(), map()) :: map()
  def encode(request, config) do
    %{
      "model" => request[:model],
      "instructions" => request[:system],
      "input" => encode_messages(request[:messages] || []),
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "reasoning" => reasoning(request[:reasoning]),
      "prompt_cache_key" => request[:cache_key]
    }
    |> with_tools(request[:tools] || [], config[:hosted_tools] || [])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(config[:extra_body] || %{})
  end

  # A summary of the model's reasoning streams back for the live view; the
  # effort is the model's default unless one is set.
  defp reasoning(effort) when effort in [nil, ""], do: %{"summary" => "auto"}
  defp reasoning(effort), do: %{"effort" => effort, "summary" => "auto"}

  defp with_tools(body, [], []), do: body

  defp with_tools(body, tools, hosted) do
    namespace = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "",
      "tools" => Enum.map(tools, &function_tool/1)
    }

    Map.merge(body, %{
      "tools" => if(tools == [], do: hosted, else: [namespace | hosted]),
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    })
  end

  defp function_tool(tool) do
    %{
      "type" => "function",
      "name" => tool["name"],
      "description" => tool["description"],
      "parameters" => tool["parameters"] || %{"type" => "object", "properties" => %{}},
      "strict" => false
    }
  end

  @doc "A conversation as Responses input items. See the moduledoc."
  @spec encode_messages([Message.t()]) :: [map()]
  def encode_messages(messages) do
    messages
    |> Enum.chunk_by(&(&1["role"] == "tool"))
    |> Enum.flat_map(&encode_run/1)
  end

  # Tool results come in runs (one per round of calls); their images go in
  # one user message after the run.
  defp encode_run([%{"role" => "tool"} | _] = results),
    do: Enum.map(results, &tool_output/1) ++ images_message(results)

  defp encode_run(messages), do: Enum.flat_map(messages, &encode_message/1)

  defp encode_message(%{"role" => "user"} = message), do: [user_message(message["content"])]

  defp encode_message(%{"role" => "assistant"} = message) do
    reasoning_items(message) ++
      assistant_text(Message.text_of(message)) ++ function_calls(message)
  end

  defp encode_message(_other), do: []

  defp user_message(content) do
    parts = content |> Message.parts() |> Enum.flat_map(&input_part/1)
    %{"role" => "user", "content" => if(parts == [], do: [input_text("")], else: parts)}
  end

  defp input_part(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [input_text(text)]

  defp input_part(%{"type" => "image", "mime" => mime, "data" => data}),
    do: [%{"type" => "input_image", "image_url" => "data:#{mime};base64,#{data}"}]

  defp input_part(_part), do: []

  defp input_text(text), do: %{"type" => "input_text", "text" => text}

  # Items the model returned for its reasoning, and the searches it ran
  # between them, handed back as they came.
  defp reasoning_items(%{"reasoning_items" => items}) when is_list(items),
    do: Enum.filter(items, &(&1["type"] in ["reasoning", "web_search_call"]))

  defp reasoning_items(_message), do: []

  defp assistant_text(""), do: []

  defp assistant_text(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp function_calls(message) do
    for call <- Message.tool_calls(message) do
      %{
        "type" => "function_call",
        "call_id" => call["id"],
        "name" => call["name"],
        "arguments" => arguments_text(call["arguments"])
      }
      |> with_namespace(call["namespace"])
    end
  end

  # A call made in a namespace goes back in it.
  defp with_namespace(item, namespace) when is_binary(namespace),
    do: Map.put(item, "namespace", namespace)

  defp with_namespace(item, _namespace), do: item

  defp arguments_text(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{}} -> args
      _not_an_object -> Jason.encode!(%{"invalid_arguments" => args})
    end
  end

  defp arguments_text(args) when is_map(args), do: Jason.encode!(args)
  defp arguments_text(_none), do: "{}"

  defp tool_output(result) do
    %{
      "type" => "function_call_output",
      "call_id" => result["tool_call_id"],
      "output" => Message.text_of(result)
    }
  end

  defp images_message(results) do
    parts =
      Enum.flat_map(results, fn result ->
        Enum.flat_map(Message.images(result), fn image ->
          [Message.text(@caption <> "#{result["tool_call_id"]}:"), image]
        end)
      end)

    if parts == [], do: [], else: [user_message(parts)]
  end
end
