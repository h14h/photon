defmodule Photon.Durable.ToolCallTest do
  @moduledoc "Whether a tool call runs, and how its result is recorded."

  use Photon.Case, async: true

  @schema %{
    "type" => "object",
    "properties" => %{"machine" => %{"type" => "string"}},
    "required" => ["machine"]
  }

  describe "a call" do
    test "to a tool that's gone ends with an error" do
      assert ToolCall.plan(call("ghost"), 1, nil) ==
               {:finish, {:error, ~s(There is no tool named "ghost".)}}
    end

    test "with valid arguments runs" do
      assert ToolCall.plan(call("run", %{"machine" => "box"}), 1, {:unsafe, @schema}) ==
               {:execute, %{"machine" => "box"}}
    end

    test "with arguments that don't fit the schema ends with an error" do
      assert ToolCall.plan(call("run", %{}), 1, {:safe, @schema}) ==
               {:finish, {:error, "Invalid arguments: missing required argument(s): machine"}}

      bad_json = %{"id" => "c1", "name" => "run", "arguments" => "{nope"}

      assert {:finish, {:error, "Invalid arguments: " <> _}} =
               ToolCall.plan(bad_json, 1, {:safe, @schema})
    end

    test "rerun after a hub restart runs only if its tool is safe to repeat" do
      args = call("run", %{"machine" => "box"})

      assert {:finish, {:interrupted, "The hub restarted while this call was running" <> _}} =
               ToolCall.plan(args, 2, {:unsafe, @schema})

      assert ToolCall.plan(args, 2, {:safe, @schema}) == {:execute, %{"machine" => "box"}}
    end

    test "finds its tool by name among the profile's tools" do
      assert ToolCall.find_tool([Photon.TestProfile.Wait], "wait") == Photon.TestProfile.Wait
      assert ToolCall.find_tool([Photon.TestProfile.Wait], "nope") == nil
    end

    test "parks until its wait holds, and resumes with its state" do
      assert ToolCall.park(%{"signal" => "go"}, %{"x" => 1}) ==
               {:wait, %{"signal" => "go"}, "resume", %{"state" => %{"x" => 1}}}
    end
  end

  describe "the result" do
    test "is a tool_result entry with the status the model and the page read" do
      assert {"ok", %{"message" => message, "name" => "run", "status" => "ok", "details" => %{}}} =
               ToolCall.result_entry(call("run"), {:ok, "done"})

      assert message == Message.tool_result("call_1", "done")

      assert {"ok", %{"details" => %{"session_id" => "ns_1"}}} =
               ToolCall.result_entry(call("run"), {:ok, "done", %{"session_id" => "ns_1"}})
    end

    test "of an error, an interruption or a stop says so" do
      assert {"error", %{"message" => error}} = ToolCall.result_entry(call("run"), {:error, "no"})
      assert Message.text_of(error) == "Error: no"

      assert {"interrupted", _} = ToolCall.result_entry(call("run"), {:interrupted, "unknown"})

      assert {"aborted", %{"message" => stopped}} =
               ToolCall.result_entry(call("run"), ToolCall.stopped())

      assert Message.text_of(stopped) == "Stopped by the user before it finished."
      assert ToolCall.tool_gone() == {:error, "This tool is no longer available."}
    end

    test "of anything else raises, which fails the call" do
      # Called dynamically: the type checker rightly rejects a direct call with :what.
      args = [call("run"), :what]
      assert_raise CaseClauseError, fn -> apply(ToolCall, :result_entry, args) end
    end

    test "finishes the call with its status" do
      assert ToolCall.done("ok") == {:done, %{"result" => "ok"}}
    end
  end
end
