defmodule PhotonCore.Message do
  @moduledoc """
  The conversation format the hub's harness stores. Messages are
  string-keyed maps, so they persist as JSON unchanged and read back
  identically:

    * user: `%{"role" => "user", "content" => [part]}`
    * assistant: `%{"role" => "assistant", "content" => [part],
      "reasoning" => text | nil, "tool_calls" => [call]}`, where a call is
      `%{"id" => id, "name" => name, "arguments" => json_text}`. Arguments
      stay the raw text the model wrote, since it may not be valid JSON.
    * tool result: `%{"role" => "tool", "tool_call_id" => id, "content" => [part]}`

  A part is `%{"type" => "text", "text" => text}` or
  `%{"type" => "image", "mime" => mime, "data" => base64}`.

  Pure. The readers (`text_of/1`, `images/1`, `tool_calls/1`,
  `arguments/1`) accept anything and never raise, since they also read
  messages that came over the wire.
  """

  @typedoc "A message: user, assistant or tool result (see the moduledoc)."
  @type t :: %{optional(String.t()) => term()}

  @typedoc "A text or image part of a message's content."
  @type part :: %{optional(String.t()) => String.t()}

  @typedoc ~s{A tool call: `"id"`, `"name"` and `"arguments"` (JSON text).}
  @type tool_call :: %{optional(String.t()) => term()}

  @typedoc "Content as constructors take it: text (`nil` and `\"\"` are none) or parts."
  @type content :: String.t() | nil | [part()]

  @spec user(content()) :: t()
  def user(content), do: %{"role" => "user", "content" => parts(content)}

  @spec assistant(content(), [tool_call()]) :: t()
  def assistant(text, tool_calls \\ []) do
    %{
      "role" => "assistant",
      "content" => parts(text),
      "reasoning" => nil,
      "tool_calls" => tool_calls
    }
  end

  @spec tool_result(String.t(), content()) :: t()
  def tool_result(call_id, content) do
    %{"role" => "tool", "tool_call_id" => call_id, "content" => parts(content)}
  end

  @spec text(String.t()) :: part()
  def text(text), do: %{"type" => "text", "text" => text}

  @spec image(String.t(), String.t()) :: part()
  def image(mime, base64), do: %{"type" => "image", "mime" => mime, "data" => base64}

  @doc "Content as a list of parts; a string becomes one text part, `\"\"` none."
  @spec parts(content()) :: [part()]
  def parts(""), do: []
  def parts(nil), do: []
  def parts(text) when is_binary(text), do: [text(text)]
  def parts(parts) when is_list(parts), do: parts

  @doc "The text of a message or a list of parts, joined with blank lines."
  @spec text_of(t() | [part()] | String.t() | term()) :: String.t()
  def text_of(%{"content" => content}), do: text_of(content)

  def text_of(parts) when is_list(parts),
    do: parts |> Enum.flat_map(&part_text/1) |> Enum.join("\n\n")

  def text_of(text) when is_binary(text), do: text
  def text_of(_), do: ""

  defp part_text(%{"type" => "text", "text" => text}), do: [text]
  defp part_text(_part), do: []

  @doc "Image parts of a message or list of parts."
  @spec images(t() | [part()] | term()) :: [part()]
  def images(%{"content" => content}), do: images(content)
  def images(parts) when is_list(parts), do: Enum.filter(parts, &match?(%{"type" => "image"}, &1))
  def images(_), do: []

  @spec tool_calls(t() | term()) :: [tool_call()]
  def tool_calls(%{"tool_calls" => calls}) when is_list(calls), do: calls
  def tool_calls(_), do: []

  @doc """
  Decodes a tool call's arguments: `{:ok, map}` or `{:error, reason}`.
  Missing, `nil` or empty arguments are `{}`; an already decoded object is
  taken as is.
  """
  @spec arguments(tool_call() | term()) :: {:ok, map()} | {:error, String.t()}
  def arguments(%{"arguments" => args}) when args in [nil, ""], do: {:ok, %{}}

  def arguments(%{"arguments" => args}) when is_binary(args),
    do: args |> Jason.decode() |> object()

  def arguments(%{"arguments" => args}) when is_map(args), do: {:ok, args}
  def arguments(%{"arguments" => _args}), do: {:error, "arguments must be a JSON object"}
  def arguments(call) when is_map(call), do: {:ok, %{}}
  def arguments(_call), do: {:error, "a tool call must be an object"}

  defp object({:ok, map}) when is_map(map), do: {:ok, map}
  defp object({:ok, _other}), do: {:error, "arguments must be a JSON object"}
  defp object({:error, _reason}), do: {:error, "arguments are not valid JSON"}
end
