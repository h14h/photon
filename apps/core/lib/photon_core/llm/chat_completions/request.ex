defmodule PhotonCore.LLM.ChatCompletions.Request do
  @moduledoc """
  The request half of the Chat Completions wire format, as pure functions:
  `encode/2` builds the JSON body for a `PhotonCore.LLM` request, and
  `encode_messages/1` and `decode_messages/1` convert `PhotonCore.Message`
  conversations to the wire form and back.

  Tool results can't carry images in this format, so images from a round of
  tool results follow it in one user message, each captioned with its call
  ID. Decoding puts them back into their results.
  """

  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM.ChatCompletions.Wire]

  alias PhotonCore.LLM
  alias PhotonCore.LLM.ChatCompletions.Wire
  alias PhotonCore.Message

  @caption "Image from tool call "

  @typedoc ~s{A message in Chat Completions form (`"role"`, `"content"`, ...).}
  @type wire_message :: %{optional(String.t()) => term()}

  @doc """
  The JSON body for `request`. `reasoning_effort` is sent only when the
  config's `:send_reasoning_effort` is set, and the config's `:extra_body`
  is merged in last.
  """
  @spec encode(LLM.request(), LLM.config()) :: map()
  def encode(request, config) do
    %{
      "model" => request[:model],
      "messages" =>
        system_messages(request[:system]) ++ encode_messages(request[:messages] || []),
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }
    |> put_present("tools", encode_tools(request[:tools] || []))
    |> put_present("max_tokens", request[:max_tokens])
    |> put_present("reasoning_effort", reasoning_effort(request, config))
    |> Map.merge(config[:extra_body] || %{})
  end

  defp system_messages(text) when text in [nil, ""], do: []
  defp system_messages(text), do: [%{"role" => "system", "content" => text}]

  defp reasoning_effort(request, config),
    do: if(config[:send_reasoning_effort], do: request[:reasoning])

  defp encode_tools(tools), do: Enum.map(tools, &encode_tool/1)

  defp encode_tool(tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool["name"],
        "description" => tool["description"],
        "parameters" => tool["parameters"]
      }
    }
  end

  ## Encoding messages

  @doc "A conversation in Chat Completions form, without the system message."
  @spec encode_messages([Message.t()]) :: [wire_message()]
  def encode_messages(messages) do
    messages
    |> Enum.chunk_by(&tool_result?/1)
    |> Enum.flat_map(&encode_run/1)
  end

  defp tool_result?(message), do: message["role"] == "tool"

  defp encode_run([%{"role" => "tool"} | _] = results), do: encode_tool_round(results)
  defp encode_run(messages), do: Enum.map(messages, &encode_message/1)

  defp encode_message(%{"role" => "user"} = message) do
    %{"role" => "user", "content" => encode_content(message["content"])}
  end

  defp encode_message(%{"role" => "assistant"} = message) do
    %{"role" => "assistant", "content" => Message.text_of(message)}
    |> put_present("tool_calls", Enum.map(Message.tool_calls(message), &encode_tool_call/1))
  end

  defp encode_tool_call(call) do
    %{
      "id" => call["id"],
      "type" => "function",
      "function" => %{"name" => call["name"], "arguments" => call["arguments"] || "{}"}
    }
  end

  defp encode_tool_round(results) do
    Enum.map(results, &encode_tool_result/1) ++ images_message(results)
  end

  defp encode_tool_result(result) do
    %{
      "role" => "tool",
      "tool_call_id" => result["tool_call_id"],
      "content" => Message.text_of(result)
    }
  end

  # The round's images, each after a caption naming its call, in one user
  # message; no message when the round has none.
  defp images_message(results),
    do: results |> Enum.flat_map(&captioned_images/1) |> user_message()

  defp user_message([] = _no_parts), do: []
  defp user_message(parts), do: [%{"role" => "user", "content" => parts}]

  defp captioned_images(result) do
    Enum.flat_map(Message.images(result), fn image ->
      [%{"type" => "text", "text" => @caption <> "#{result["tool_call_id"]}:"}, image_part(image)]
    end)
  end

  defp encode_content(parts) when is_list(parts) do
    if Enum.all?(parts, &match?(%{"type" => "text"}, &1)),
      do: Message.text_of(parts),
      else: Enum.flat_map(parts, &encode_part/1)
  end

  defp encode_content(text) when is_binary(text), do: text

  defp encode_part(%{"type" => "text", "text" => text}), do: [%{"type" => "text", "text" => text}]
  defp encode_part(%{"type" => "image"} = image), do: [image_part(image)]
  defp encode_part(_part), do: []

  defp image_part(%{"mime" => mime, "data" => data}) do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{mime};base64,#{data}"}}
  end

  ## Decoding messages

  @doc """
  The reverse of `encode_messages/1`: reads Chat Completions messages back
  into `PhotonCore.Message` form (system messages are dropped). Images that
  `encode_messages/1` moved out of a round of tool results into the user
  message after it go back into those results. Shapes it doesn't know are
  skipped rather than raised on.
  """
  @spec decode_messages(term()) :: [Message.t()]
  def decode_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&decode_message/1)
    |> restore_tool_images([])
  end

  def decode_messages(_messages), do: []

  defp decode_message(%{"role" => "user", "content" => content}),
    do: [Message.user(decode_content(content))]

  defp decode_message(%{"role" => "assistant"} = message) do
    calls =
      for %{"id" => id, "function" => %{} = f} <- Wire.list(message["tool_calls"]),
          do: decode_tool_call(id, f)

    [Message.assistant(decode_content(message["content"]), calls)]
  end

  defp decode_message(%{"role" => "tool", "tool_call_id" => id} = message),
    do: [Message.tool_result(id, decode_content(message["content"]))]

  defp decode_message(_message), do: []

  defp decode_tool_call(id, function) do
    %{
      "id" => id,
      "name" => Wire.text_or_nil(function["name"]),
      "arguments" => Wire.arguments_text(function["arguments"])
    }
  end

  defp decode_content(text) when is_binary(text), do: Message.parts(text)
  defp decode_content(parts) when is_list(parts), do: Enum.flat_map(parts, &decode_part/1)
  defp decode_content(_content), do: []

  defp decode_part(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [Message.text(text)]

  defp decode_part(%{"type" => "image_url", "image_url" => %{"url" => "data:" <> data_url}}),
    do: data_url |> String.split(";base64,", parts: 2) |> decode_image()

  defp decode_part(_part), do: []

  defp decode_image([mime, data]), do: [Message.image(mime, data)]
  defp decode_image(_not_base64), do: []

  # Walks the conversation; at each round of tool results, a following user
  # message made only of the round's captioned images is folded back into
  # the results.
  defp restore_tool_images([], acc), do: Enum.reverse(acc)

  defp restore_tool_images([%{"role" => "tool"} | _] = messages, acc) do
    {results, rest} = Enum.split_while(messages, &tool_result?/1)
    {results, rest} = take_round_images(results, rest)
    restore_tool_images(rest, Enum.reverse(results, acc))
  end

  defp restore_tool_images([message | rest], acc), do: restore_tool_images(rest, [message | acc])

  defp take_round_images(results, [%{"role" => "user", "content" => parts} | after_images] = rest) do
    case round_images(parts, Enum.map(results, & &1["tool_call_id"]), 0, %{}) do
      {:ok, images} -> {add_images(results, images), after_images}
      :error -> {results, rest}
    end
  end

  defp take_round_images(results, rest), do: {results, rest}

  defp add_images(results, images) do
    results
    |> Enum.with_index()
    |> Enum.map(fn {result, index} ->
      %{result | "content" => result["content"] ++ Enum.reverse(Map.get(images, index, []))}
    end)
  end

  # Images by result index, or :error when the parts aren't the round's
  # images. Each caption names the next result (from the one before) with
  # that call ID.
  defp round_images([], _ids, _from, images) when map_size(images) > 0, do: {:ok, images}

  defp round_images(
         [
           %{"type" => "text", "text" => @caption <> caption},
           %{"type" => "image"} = image | rest
         ],
         ids,
         from,
         images
       ) do
    with {:ok, index} <- captioned_result(caption, ids, from) do
      round_images(rest, ids, index, Map.update(images, index, [image], &[image | &1]))
    end
  end

  defp round_images(_parts, _ids, _from, _images), do: :error

  defp captioned_result(caption, ids, from) do
    with true <- String.ends_with?(caption, ":"),
         id = String.trim_trailing(caption, ":"),
         index when is_integer(index) <- ids |> Enum.drop(from) |> Enum.find_index(&(&1 == id)) do
      {:ok, index + from}
    else
      _ -> :error
    end
  end

  defp put_present(map, _key, value) when value in [nil, [], ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
