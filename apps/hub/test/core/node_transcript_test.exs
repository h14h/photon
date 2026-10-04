defmodule Photon.NodeTranscriptTest do
  @moduledoc "Folding a node session's records into display items."

  use Photon.Case, async: true

  alias Photon.NodeTranscript

  defp fold(records), do: NodeTranscript.build(records)

  defp only_item(records), do: records |> fold() |> NodeTranscript.items() |> List.last()

  describe "inputs" do
    test "a message becomes a user item that counts its images" do
      content = [Message.text("look"), %{"type" => "image", "mime" => "image/png", "data" => "x"}]

      assert %{type: :user, text: "look", images: 1, id: "i0"} =
               only_item([input_record("in_1", content)])
    end

    test "heartbeats, stops and settings changes become notices" do
      control = fn payload -> record("input", %{"kind" => "control", "payload" => payload}) end

      assert %{kind: :heartbeat} = only_item([control.(%{"mode" => "heartbeat"})])
      assert %{kind: :stop, text: "Stop requested"} = only_item([control.(%{"mode" => "hard"})])

      assert %{kind: :settings, text: "Model settings: deepseek, reasoning high"} =
               only_item([
                 control.(%{
                   "mode" => "settings",
                   "parameters" => %{"model" => "accounts/x/deepseek", "reasoning" => "high"}
                 })
               ])

      assert %{text: "Model settings: default"} =
               only_item([control.(%{"mode" => "settings", "parameters" => %{}})])

      assert NodeTranscript.items(fold([control.(%{"mode" => "other"})])) == []
    end
  end

  describe "model responses" do
    test "text and reasoning make an assistant item, and each call a pending tool item" do
      message =
        Map.put(
          Message.assistant("Running it.", [call("Bash", %{"command" => "ls"}, "c1")]),
          "reasoning",
          "hm"
        )

      response =
        record("model_response", %{
          "response" => %{"message" => message, "usage" => %{"input" => 3, "output" => 2}}
        })

      {t, changed} = NodeTranscript.fold(NodeTranscript.new(), response)

      assert [%{type: :assistant, text: "Running it.", reasoning: "hm"}, tool] = changed

      assert %{
               type: :tool,
               call_id: "c1",
               name: "Bash",
               args: %{"command" => "ls"},
               status: :pending
             } = tool

      assert t.calls == %{"c1" => tool.id}
      assert t.usage == %{"input" => 3, "output" => 2}
    end

    test "a response with only calls makes no assistant item" do
      message = Message.assistant("", [call("Bash", %{}, "c1")])

      {_t, changed} =
        NodeTranscript.fold(
          NodeTranscript.new(),
          record("model_response", %{"response" => %{"message" => message}})
        )

      assert [%{type: :tool}] = changed
    end

    test "a failed request becomes a failure notice" do
      failed =
        record("model_response", %{"response" => %{"failure" => %{"message" => "HTTP 500"}}})

      assert %{kind: :failure, text: "Couldn't reach the model: HTTP 500"} = only_item([failed])

      assert %{text: "Couldn't reach the model: the model request failed"} =
               only_item([record("model_response", %{"response" => %{}})])
    end
  end

  describe "tool calls" do
    setup do
      message = Message.assistant("", [call("Bash", %{"command" => "ls"}, "c1")])
      %{asked: record("model_response", %{"response" => %{"message" => message}})}
    end

    defp status(op), do: record("tool_call_status", %{"call_id" => "c1", "operations" => [op]})

    test "update in place as their operation runs and finishes", %{asked: asked} do
      running = status(%{"id" => "op", "type" => "shell", "status" => "awaiting"})
      assert %{status: :running, op: "op"} = only_item([asked, running])

      done =
        status(%{
          "id" => "op",
          "type" => "shell",
          "status" => "completed",
          "state" => %{"result" => %{"out" => "a.txt", "err" => "", "exit_code" => 0}}
        })

      t = fold([asked, running, done])

      assert [%{status: :done, output: "a.txt", exit_code: 0, error: nil}] =
               NodeTranscript.items(t)
    end

    test "show an image, a loaded skill, or an error", %{asked: asked} do
      image = %{"result" => %{"content" => "AAA", "mime" => "image/png", "path" => "/a.png"}}

      assert %{image: %{mime: "image/png", data: "AAA"}, output: "/a.png"} =
               only_item([
                 asked,
                 status(%{"type" => "view_image", "status" => "completed", "state" => image})
               ])

      assert %{status: :error, error: "no such file"} =
               only_item([
                 asked,
                 status(%{
                   "type" => "view_image",
                   "status" => "failed",
                   "state" => %{"result" => %{"error" => "no such file"}}
                 })
               ])

      assert %{output: "Loaded the skill's instructions."} =
               only_item([
                 asked,
                 status(%{"type" => "skill_use", "status" => "completed", "state" => %{}})
               ])

      assert %{status: :canceled} =
               only_item([asked, status(%{"type" => "other", "status" => "canceled"})])

      errored =
        record("tool_call_status", %{"call_id" => "c1", "status" => %{"error" => "denied"}})

      assert %{status: :error, output: "denied"} = only_item([asked, errored])
    end

    test "for an unknown call are ignored", %{asked: asked} do
      stray = record("tool_call_status", %{"call_id" => "nope", "operations" => []})
      assert fold([asked, stray]) == fold([asked])
    end
  end

  test "a stop record becomes a notice, and records it doesn't know change nothing" do
    assert %{kind: :stop, text: "Stopped"} = only_item([state_record("stopped")])
    assert NodeTranscript.items(fold([record("turn"), state_record("idle")])) == []
  end
end
