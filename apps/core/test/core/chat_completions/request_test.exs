defmodule PhotonCore.LLM.ChatCompletions.RequestTest do
  use PhotonCore.Case, async: true

  defp tool_round(id, content),
    do: [Message.assistant("", [call(id)]), Message.tool_result(id, content)]

  defp call(id), do: %{"id" => id, "name" => "x", "arguments" => "{}"}

  describe "encode/2" do
    test "puts the system prompt first and asks for usage in the stream" do
      body = Request.encode(request(), %{})

      assert %{
               "model" => "m",
               "messages" => [
                 %{"role" => "system", "content" => "Be brief."},
                 %{"role" => "user", "content" => "hi"}
               ],
               "stream" => true,
               "stream_options" => %{"include_usage" => true}
             } = body

      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "max_tokens")
    end

    test "sends tools and max_tokens when given, and merges extra_body last" do
      tool = %{"name" => "Bash", "description" => "Run", "parameters" => %{"type" => "object"}}
      body = Request.encode(request(tools: [tool], max_tokens: 9), %{extra_body: %{"top_p" => 1}})

      assert [%{"type" => "function", "function" => %{"name" => "Bash"}}] = body["tools"]
      assert body["max_tokens"] == 9
      assert body["top_p"] == 1
    end

    test "sends reasoning_effort only when the config allows it" do
      refute Map.has_key?(Request.encode(request(reasoning: "high"), %{}), "reasoning_effort")

      assert Request.encode(request(reasoning: "high"), %{send_reasoning_effort: true})[
               "reasoning_effort"
             ] ==
               "high"
    end

    test "leaves out an empty system prompt" do
      assert [%{"role" => "user"}] = Request.encode(request(system: ""), %{})["messages"]
    end
  end

  describe "encode_messages/1" do
    test "images from tool results follow the round in a user message" do
      messages = [
        Message.user("look"),
        Message.assistant("", [%{"id" => "a", "name" => "ViewImage", "arguments" => "{}"}]),
        Message.tool_result("a", [Message.text("an image"), Message.image("image/png", "QUJD")])
      ]

      assert [
               %{"role" => "user", "content" => "look"},
               %{"role" => "assistant", "tool_calls" => [_]},
               %{"role" => "tool", "tool_call_id" => "a", "content" => "an image"},
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "Image from tool call a:"},
                   %{
                     "type" => "image_url",
                     "image_url" => %{"url" => "data:image/png;base64,QUJD"}
                   }
                 ]
               }
             ] = Request.encode_messages(messages)
    end

    test "a call without arguments is sent with an empty object, and text-only content as text" do
      assistant = Message.assistant("ok", [%{"id" => "c", "name" => "x", "arguments" => nil}])

      assert [
               %{"content" => "a\n\nb"},
               %{"tool_calls" => [%{"function" => %{"arguments" => "{}"}}]}
             ] =
               Request.encode_messages([
                 Message.user([Message.text("a"), Message.text("b")]),
                 assistant
               ])
    end
  end

  describe "decode_messages/1" do
    # core-decode-messages-raises
    test "decode_messages skips content and calls of an unexpected shape" do
      assert Request.decode_messages([%{"role" => "user", "content" => %{}}]) == [
               Message.user([])
             ]

      assert [%{"tool_calls" => []}] =
               Request.decode_messages([%{"role" => "assistant", "tool_calls" => 3}])

      assert [%{"tool_calls" => [%{"arguments" => ~s({"a":1})}]}] =
               Request.decode_messages([
                 %{
                   "role" => "assistant",
                   "tool_calls" => [
                     %{"id" => "c", "function" => %{"name" => "x", "arguments" => %{"a" => 1}}}
                   ]
                 }
               ])

      assert Request.decode_messages([1, "x", nil]) == []
      assert Request.decode_messages(%{}) == []
    end

    test "drops system messages and image URLs that aren't base64 data" do
      wire = [
        %{"role" => "system", "content" => "rules"},
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "see"},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png,raw"}}
          ]
        }
      ]

      assert Request.decode_messages(wire) == [Message.user([Message.text("see")])]
    end

    # core-mockagent-proxy-divergence: the hub's mock proxy decodes what the
    # node encoded, and a tool image used to come back as a new user prompt.
    test "the mock agent answers the same directly and through the hub's proxy" do
      call1 = %{"id" => "c1", "name" => "Bash", "arguments" => ~s({"command":"echo hi"})}
      call2 = %{"id" => "c2", "name" => "Bash", "arguments" => ~s({"command":"echo hi"})}

      messages = [
        Message.user("$ echo hi"),
        Message.assistant("Running `echo hi`.", [call1]),
        Message.tool_result("c1", "output 0"),
        Message.user("$ echo hi"),
        Message.assistant("Running `echo hi`.", [call2]),
        Message.tool_result("c2", [Message.text("an image"), Message.image("image/png", "QUJD")])
      ]

      proxied = messages |> Request.encode_messages() |> Request.decode_messages()
      assert proxied == messages

      direct = MockAgent.respond(%{messages: messages})
      assert MockAgent.respond(%{messages: proxied}) == direct
      assert Message.text_of(direct) =~ "1 image(s). an image"
    end

    test "a user message that only looks like tool images stays a user message" do
      messages =
        tool_round("c1", "done") ++
          [
            Message.user([
              Message.text("Image from tool call other:"),
              Message.image("image/png", "QQ")
            ])
          ]

      wire = Request.encode_messages(messages)
      assert List.last(Request.decode_messages(wire))["role"] == "user"
    end

    test "the codec functions are reachable through ChatCompletions too" do
      messages = tool_round("c1", [Message.text("t"), Message.image("image/png", "QQ")])
      wire = ChatCompletions.encode_messages(messages)
      assert ChatCompletions.decode_messages(wire) == messages
    end
  end
end
