defmodule Photon.MockModelTest do
  use ExUnit.Case, async: true

  alias Photon.MockModel

  defp user(text),
    do: %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }

  defp types(response), do: Enum.map(response["output"], & &1["type"])

  test "runs a shell command, then reports its output" do
    first = MockModel.respond(%{"input" => [user("$ echo hi")]})
    assert types(first) == ["message", "function_call"]
    call = Enum.find(first["output"], &(&1["type"] == "function_call"))
    assert call["name"] == "Bash"
    assert Jason.decode!(call["arguments"]) == %{"command" => "echo hi"}

    output = %{
      "type" => "function_call_output",
      "call_id" => call["call_id"],
      "output" => [%{"type" => "input_text", "text" => "hi"}]
    }

    second = MockModel.respond(%{"input" => [user("$ echo hi"), call, output]})
    assert [%{"type" => "message", "content" => [%{"text" => text}]}] = second["output"]
    assert text =~ "hi"
  end

  test "waits while the harness says the call is still running" do
    call = MockModel.respond(%{"input" => [user("sleep 1")]})["output"] |> List.last()

    running = %{
      "type" => "function_call_output",
      "call_id" => call["call_id"],
      "output" => "Tool call is still running. Its result arrives later."
    }

    [%{"content" => [%{"text" => text}]}] =
      MockModel.respond(%{"input" => [user("sleep 1"), call, running]})["output"]

    assert text =~ "Still waiting"
  end

  test "opens images and answers help without tools" do
    assert %{"name" => "ViewImage"} =
             MockModel.respond(%{"input" => [user("view a.png")]})["output"] |> List.last()

    assert types(MockModel.respond(%{"input" => [user("help")]})) == ["message"]
  end

  test "looks at an attached image, but takes commands from the user's own words" do
    note = Photon.Attachments.with_note("", [".attachments/20260923-000000-0-cat.png"])
    call = MockModel.respond(%{"input" => [user(note)]})["output"] |> List.last()
    assert call["name"] == "ViewImage"

    assert Jason.decode!(call["arguments"]) == %{
             "path" => ".attachments/20260923-000000-0-cat.png"
           }

    with_command =
      Photon.Attachments.with_note("$ echo hi", [".attachments/20260923-000000-0-cat.png"])

    call = MockModel.respond(%{"input" => [user(with_command)]})["output"] |> List.last()
    assert Jason.decode!(call["arguments"]) == %{"command" => "echo hi"}
  end
end
