defmodule Photon.Durable.InboxTest do
  @moduledoc "The rules for input to a conversation, idle or busy."

  use Photon.Case, async: true

  describe "a submission" do
    test "with a request ID seen before returns the earlier one" do
      earlier = submission(request_id: "r1")
      assert Inbox.submit_action(earlier, true, "reject") == {:existing, earlier}
    end

    test "on an idle conversation starts a run" do
      assert Inbox.submit_action(nil, false, "reject") == :start_run
      assert Inbox.submit_action(nil, false, "steer") == :start_run
    end

    test "on a busy conversation waits, unless it asked to be rejected" do
      assert Inbox.submit_action(nil, true, "follow_up") == :queue
      assert Inbox.submit_action(nil, true, "steer") == :queue
      assert Inbox.submit_action(nil, true, "reject") == :reject
    end

    test "is stored queued, as a follow-up unless it says otherwise" do
      assert %{
               conversation_id: "c_1",
               request_id: nil,
               mode: "follow_up",
               status: "queued",
               content: %{"parts" => [%{"type" => "text", "text" => "hi"}], "source" => nil}
             } = Inbox.submission("c_1", "hi", [])

      assert %{mode: "steer", request_id: "r1", content: %{"source" => %{"kind" => "user"}}} =
               Inbox.submission("c_1", "hi",
                 when_busy: "steer",
                 request_id: "r1",
                 source: %{"kind" => "user"}
               )
    end

    test "is placed as a user entry that points back at it" do
      s = submission(id: "s_9")

      assert Inbox.user_entry(s) == %{
               "message" => Message.user(s.content["parts"]),
               "submission_id" => "s_9",
               "source" => %{"kind" => "user"}
             }
    end

    test "starts a run as a generation in its request phase" do
      assert Inbox.run("c_1", ["s_1"]) == %{
               kind: "generation",
               conversation_id: "c_1",
               phase: "request",
               checkpoint: %{"submissions" => ["s_1"]}
             }
    end

    test "can be withdrawn only while it is queued" do
      assert Inbox.withdrawable?(submission(status: "queued"))
      refute Inbox.withdrawable?(submission(status: "placed"))
      refute Inbox.withdrawable?(nil)
    end
  end

  describe "the next input" do
    test "is every queued steer, in order" do
      steers = [submission(id: "a", mode: "steer"), submission(id: "c", mode: "steer")]
      queued = [hd(steers), submission(id: "b"), List.last(steers)]

      assert Inbox.next_input(queued) == steers
    end

    test "is the oldest follow-up when nothing steers" do
      assert [%{id: "a"}] = Inbox.next_input([submission(id: "a"), submission(id: "b")])
      assert Inbox.next_input([]) == []
    end
  end
end
