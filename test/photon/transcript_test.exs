defmodule Photon.TranscriptTest do
  use ExUnit.Case, async: true

  alias Photon.Transcript

  # Three runner invocations resuming one session against the mock model:
  # "sleep 2", "view dot.png", and a command that writes stderr and exits 3.
  @events "test/fixtures/mock_session.jsonl"
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

  test "folds a real runner session into a conversation" do
    t = Transcript.build(@events)
    entries = Transcript.entries(t)

    assert [
             %{type: :user, text: "sleep 2"},
             %{type: :user, text: "view dot.png"},
             %{type: :user, text: "$ echo hi; echo oops >&2; exit 3"}
           ] = Enum.filter(entries, &(&1.type == :user))

    assert t.turns == 6
    assert t.responses == 6
    assert t.usage.input > 0
  end

  test "updates a tool entry in place as its operation finishes" do
    [sleep, image, failing] =
      Transcript.build(@events) |> Transcript.entries() |> Enum.filter(&(&1.type == :tool))

    assert %{name: "Bash", status: :completed, exit_code: 0} = sleep
    assert sleep.stdout =~ "tick 2"

    assert %{name: "ViewImage", status: :completed, image: %{mime: "image/png"}} = image

    assert %{name: "Bash", status: :completed, exit_code: 3, stdout: "hi\n", stderr: "oops\n"} =
             failing
  end

  test "shows a running tool before its result arrives" do
    running = Enum.take_while(@events, &(&1["Sequence"] < 7))
    [tool] = Transcript.build(running) |> Transcript.entries() |> Enum.filter(&(&1.type == :tool))
    assert tool.status == :running
  end

  test "marks in-flight tools as interrupted when the runner exits" do
    running =
      Enum.take_while(@events, &(&1["Sequence"] < 7)) ++ [%{"type" => "exit", "status" => 130}]

    [tool] = Transcript.build(running) |> Transcript.entries() |> Enum.filter(&(&1.type == :tool))
    assert tool.status == :interrupted
  end

  test "surfaces runner errors, stderr and exits" do
    t =
      Transcript.build([
        %{"type" => "stderr", "message" => "skill error> bad"},
        %{"type" => "error", "message" => "OPENAI_API_KEY must be set"},
        %{"type" => "exit", "status" => 1}
      ])

    assert [
             %{type: :stderr},
             %{type: :error, text: "OPENAI_API_KEY must be set"},
             %{type: :exit, status: 1}
           ] =
             Transcript.entries(t)
  end

  test "reports validation errors that produced no operation" do
    call = %{"CallID" => "c1", "Name" => "Bash", "Arguments" => "{}"}

    t =
      Transcript.build([
        %{
          "Kind" => "model_response",
          "Data" => %{"Response" => %{"Output" => [%{"Type" => "tool_call", "Data" => call}]}}
        },
        %{
          "Kind" => "tool_call_status",
          "Data" => %{"CallID" => "c1", "Status" => %{"Error" => "command is required"}}
        }
      ])

    assert [%{type: :tool, status: :error, error: "command is required"}] = Transcript.entries(t)
  end
end
