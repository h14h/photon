defmodule PhotonNode.Harness.ContextTest do
  use PhotonNode.Case, async: true

  test "a placeholder that was never sent is replaced in place" do
    ctx =
      "sys"
      |> Context.new()
      |> Context.add_user("go")
      |> Context.commit()
      |> Context.add_response(Message.assistant("", [call("a")]))
      |> Context.add_tool_result("a", "Bash", [], true)
      |> Context.add_tool_result("a", "Bash", [Message.text("done")], false)

    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "tool", "content" => [%{"text" => "done"}]}
           ] =
             Context.build(ctx)
  end

  test "a result for a call whose placeholder was sent arrives as a user message" do
    ctx =
      "sys"
      |> Context.new()
      |> Context.add_user("go")
      |> Context.commit()
      |> Context.add_response(Message.assistant("", [call("a")]))
      |> Context.add_tool_result("a", "Bash", [], true)
      |> Context.add_user("meanwhile")
      |> Context.commit()
      |> Context.add_response(Message.assistant("ok"))
      |> Context.add_tool_result("a", "Bash", [Message.text("done")], false)

    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "tool", "content" => [%{"text" => placeholder}]},
             %{"role" => "user", "content" => [%{"text" => "meanwhile"}]},
             %{"role" => "assistant"},
             %{"role" => "user", "content" => [%{"text" => late}, %{"text" => "done"}]}
           ] = Context.build(ctx)

    assert placeholder == Context.placeholder()
    assert late =~ "call a"
  end

  test "responses go ahead of input staged while the request ran" do
    ctx =
      "sys"
      |> Context.new()
      |> Context.add_user("first")
      |> Context.commit()
      |> Context.add_user("second")
      |> Context.add_response(Message.assistant("answer"))

    assert ["first", "answer", "second"] = Enum.map(Context.build(ctx), &Message.text_of/1)
  end
end
