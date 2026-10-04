defmodule PhotonCore.MessageTest do
  use PhotonCore.Case, async: true

  describe "constructors" do
    test "build string-keyed messages whose content is a list of parts" do
      assert Message.user("hi") == %{"role" => "user", "content" => [Message.text("hi")]}

      assert Message.assistant("ok") == %{
               "role" => "assistant",
               "content" => [Message.text("ok")],
               "reasoning" => nil,
               "tool_calls" => []
             }

      assert Message.tool_result("c1", nil) ==
               %{"role" => "tool", "tool_call_id" => "c1", "content" => []}
    end

    test "parts keep a list as is and drop empty text" do
      image = Message.image("image/png", "QUJD")
      assert Message.parts([image]) == [image]
      assert Message.parts("") == []
    end
  end

  describe "readers" do
    test "text_of joins text parts with blank lines and skips images" do
      message =
        Message.user([Message.text("a"), Message.image("image/png", "QQ"), Message.text("b")])

      assert Message.text_of(message) == "a\n\nb"
      assert Message.text_of("plain") == "plain"
      assert Message.text_of(42) == ""
    end

    test "images and tool_calls read anything without raising" do
      image = Message.image("image/png", "QQ")
      assert Message.images(Message.user([Message.text("a"), image])) == [image]
      assert Message.images(nil) == []
      assert Message.tool_calls(%{"tool_calls" => "nope"}) == []
      assert Message.tool_calls(Message.assistant("", [%{"id" => "c"}])) == [%{"id" => "c"}]
    end
  end

  describe "arguments/1" do
    # core-message-arguments-raises
    test "arguments never raises for a call without text arguments" do
      assert Message.arguments(%{"id" => "c"}) == {:ok, %{}}
      assert Message.arguments(%{"arguments" => %{"a" => 1}}) == {:ok, %{"a" => 1}}
      assert {:error, _} = Message.arguments(%{"arguments" => 3})
      assert {:error, _} = Message.arguments(%{"arguments" => [1]})
      assert {:error, _} = Message.arguments(nil)
    end

    test "arguments still decodes JSON text" do
      assert Message.arguments(%{"arguments" => ~s({"x":1})}) == {:ok, %{"x" => 1}}
      assert Message.arguments(%{"arguments" => ""}) == {:ok, %{}}
      assert Message.arguments(%{"arguments" => nil}) == {:ok, %{}}
      assert {:error, "arguments are not valid JSON"} = Message.arguments(%{"arguments" => "{"})

      assert {:error, "arguments must be a JSON object"} =
               Message.arguments(%{"arguments" => "[]"})
    end
  end
end
