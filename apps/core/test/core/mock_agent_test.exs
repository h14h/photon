defmodule PhotonCore.LLM.MockAgentTest do
  use PhotonCore.Case, async: true

  defp respond(messages), do: MockAgent.respond(%{messages: messages})

  defp first_call(prompt) do
    %{"tool_calls" => [call]} = reply = respond([Message.user(prompt)])
    {Message.text_of(reply), call["name"], Jason.decode!(call["arguments"])}
  end

  # A prompt, the agent's call for it, and the call's result.
  defp ran(prompt, result_text) do
    %{"tool_calls" => [call]} = reply = respond([Message.user(prompt)])
    {[Message.user(prompt), reply, Message.tool_result(call["id"], result_text)], call}
  end

  describe "a new prompt" do
    test "`$ <command>` runs the command with Bash" do
      assert {"Running `echo hi`.", "Bash", %{"command" => "echo hi"}} = first_call("$ echo hi")
    end

    test "`view <path>` opens the image with ViewImage" do
      assert {"Opening `a.png`.", "ViewImage", %{"path" => "a.png"}} = first_call("view a.png")
    end

    test "`sleep <n>` runs a slow command, capped at 600 seconds" do
      assert {intro, "Bash", %{"command" => command}} = first_call("sleep 2")
      assert intro =~ "2s command"
      assert command =~ "seq 2"
      assert {_intro, "Bash", %{"command" => long}} = first_call("sleep 9999")
      assert long =~ "seq 600"
    end

    test "help answers without a tool" do
      assert %{"tool_calls" => []} = reply = respond([Message.user("help")])
      assert Message.text_of(reply) =~ "mock model"
    end

    test "anything else lists the workspace" do
      assert {_intro, "Bash", %{"command" => "pwd && ls -la"}} = first_call("hello")
    end
  end

  describe "after the call" do
    test "reports a finished result and ends the turn" do
      {messages, _call} = ran("$ echo hi", "hi\n")
      assert %{"tool_calls" => []} = reply = respond(messages)
      assert Message.text_of(reply) =~ "`echo hi` finished:"
      assert Message.text_of(reply) =~ "hi"
    end

    test "says it's still waiting while the call runs" do
      {messages, _call} = ran("$ sleep 5", "Tool call is still running.")
      assert Message.text_of(respond(messages)) =~ "Still waiting on `sleep 5`"
    end

    test "reads a late result that arrived as a user message, past heartbeats" do
      {messages, call} = ran("$ make", "Tool call is still running.")

      late =
        Message.user(
          "Result of the earlier Bash tool call #{call["id"]}, which has now finished:\n\nbuilt"
        )

      reply = respond(messages ++ [Message.user("Heartbeat: still here"), late])
      assert Message.text_of(reply) =~ "`make` finished:"
      assert Message.text_of(reply) =~ "built"
    end

    test "describes a call that isn't Bash by name and arguments" do
      {messages, _call} =
        ran("view a.png", [Message.text("an image"), Message.image("image/png", "QQ")])

      text = Message.text_of(respond(messages))
      assert text =~ ~s(ViewImage {"path":"a.png"} finished:)
      assert text =~ "1 image(s). an image"
    end
  end
end
