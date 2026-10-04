defmodule PhotonCore.Responses.RequestTest do
  @moduledoc "The Responses request body, from a request and a conversation."

  use PhotonCore.Case, async: true

  describe "the body" do
    test "is stateless and streamed, with the instructions and the model" do
      body = Request.encode(request(), %{})

      assert %{
               "model" => "m",
               "instructions" => "Be brief.",
               "store" => false,
               "stream" => true,
               "include" => ["reasoning.encrypted_content"],
               "reasoning" => %{"summary" => "auto"}
             } = body

      refute Map.has_key?(body, "tools")
    end

    test "asks for the reasoning effort when one is set, and never sends an output cap" do
      body = Request.encode(request(reasoning: "high", max_tokens: 100), %{})
      assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
      refute Map.has_key?(body, "max_output_tokens")
    end

    test "offers tools as functions in one namespace" do
      tool = %{"name" => "Bash", "description" => "Run it", "parameters" => %{"type" => "object"}}
      body = Request.encode(request(tools: [tool]), %{})

      assert [%{"type" => "namespace", "name" => "functions", "tools" => [function]}] =
               body["tools"]

      assert %{"type" => "function", "name" => "Bash", "strict" => false} = function
      assert body["tool_choice"] == "auto"
    end

    test "names the history it continues, for the prompt cache" do
      assert Request.encode(request(cache_key: "c_1"), %{})["prompt_cache_key"] == "c_1"
      refute Map.has_key?(Request.encode(request(), %{}), "prompt_cache_key")
    end

    test "takes extra fields from the config last" do
      assert Request.encode(request(), %{extra_body: %{"store" => true}})["store"] == true
    end
  end

  describe "a conversation" do
    test "user messages become input text and images" do
      message = Message.user([Message.text("look"), Message.image("image/png", "AAA")])

      assert [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "input_text", "text" => "look"},
                   %{"type" => "input_image", "image_url" => "data:image/png;base64,AAA"}
                 ]
               }
             ] = Request.encode_messages([message])
    end

    test "an assistant message hands back its reasoning, then its text, then its calls" do
      reasoning = %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "x"}

      message =
        "Checking."
        |> Message.assistant([
          %{"id" => "c1", "name" => "Bash", "arguments" => "{}", "namespace" => "functions"}
        ])
        |> Map.put("reasoning_items", [reasoning])

      assert [
               ^reasoning,
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"text" => "Checking."}]
               },
               %{
                 "type" => "function_call",
                 "call_id" => "c1",
                 "name" => "Bash",
                 "arguments" => "{}",
                 "namespace" => "functions"
               }
             ] = Request.encode_messages([message])
    end

    test "a call whose arguments aren't a JSON object goes back wrapped, so it's accepted" do
      calls = [
        %{"id" => "c1", "name" => "Bash", "arguments" => ~s({"command":"ls")},
        %{"id" => "c2", "name" => "Bash", "arguments" => "[1]"},
        %{"id" => "c3", "name" => "Bash", "arguments" => nil}
      ]

      assert [first, second, third] = Request.encode_messages([Message.assistant("", calls)])
      assert Jason.decode!(first["arguments"]) == %{"invalid_arguments" => ~s({"command":"ls")}
      assert Jason.decode!(second["arguments"]) == %{"invalid_arguments" => "[1]"}
      assert third["arguments"] == "{}"
    end

    test "tool results become call outputs, and their images follow in one message" do
      results = [
        Message.tool_result("c1", [Message.text("shot"), Message.image("image/png", "AAA")]),
        Message.tool_result("c2", "done")
      ]

      assert [
               %{"type" => "function_call_output", "call_id" => "c1", "output" => "shot"},
               %{"type" => "function_call_output", "call_id" => "c2", "output" => "done"},
               %{"role" => "user", "content" => [caption, %{"type" => "input_image"}]}
             ] = Request.encode_messages(results)

      assert caption["text"] == "Image from tool call c1:"
    end

    test "parts and roles it has no item for are left out, and object arguments are encoded" do
      user = Message.user([Message.text("hi"), %{"type" => "audio", "data" => "x"}])
      system = %{"role" => "system", "content" => [Message.text("ignored")]}
      call = %{"id" => "c1", "name" => "Bash", "arguments" => %{"command" => "ls"}}

      assert [%{"content" => [%{"type" => "input_text"}]}, %{"arguments" => args}] =
               Request.encode_messages([user, system, Message.assistant("", [call])])

      assert Jason.decode!(args) == %{"command" => "ls"}
    end

    test "an empty user message still has a part" do
      assert [%{"content" => [%{"type" => "input_text", "text" => ""}]}] =
               Request.encode_messages([Message.user("")])
    end
  end
end
