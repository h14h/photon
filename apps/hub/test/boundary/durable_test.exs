defmodule Photon.DurableTest do
  @moduledoc """
  The durable harness through its API (`Photon.Durable`), with
  `Photon.TestProfile`'s scripted model and its `wait` tool, which parks
  until the signal `"go"` fires.
  """

  use Photon.DataCase, async: false

  alias Photon.Durable.Tx

  @moduletag :durable

  ## Named setups

  defp conversation(_context) do
    conversation = Durable.create_conversation("test")
    Durable.subscribe(conversation.id)
    %{conversation: conversation.id}
  end

  defp waiting_on_a_tool(%{conversation: c}) do
    {:ok, first} = Durable.submit(c, "wait")
    await_tool_waiting(c)
    %{first: first}
  end

  defp await_tool_waiting(c) do
    await_change(c, &Enum.any?(&1.tasks, fn t -> t.kind == "tool" and t.status == "waiting" end))
  end

  describe "an idle conversation" do
    setup :conversation

    test "answers an input", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "hello")
      assert %{status: "done"} = await_settled(c, s.id)
      assert entry_kinds(c) == ["user", "assistant"]
      assert texts(c, "assistant") == ["echo: hello"]
      refute Durable.busy?(c)
    end

    test "a retried submission with the same request ID isn't submitted twice", %{
      conversation: c
    } do
      {:ok, s1} = Durable.submit(c, "hello", request_id: "r1")
      {:ok, s2} = Durable.submit(c, "hello", request_id: "r1")
      assert s1.id == s2.id
      await_settled(c, s1.id)
      assert length(texts(c, "user")) == 1
    end
  end

  describe "a run waiting on a tool" do
    setup [:conversation, :waiting_on_a_tool]

    test "runs a tool that waits durably, then answers", %{conversation: c, first: s} do
      assert Durable.busy?(c)

      Durable.signal("go")
      assert %{status: "done"} = await_settled(c, s.id)
      assert entry_kinds(c) == ["user", "assistant", "tool_result", "assistant"]
      assert texts(c, "tool_result") == ["went"]
    end

    test "input that arrives while busy waits, then starts the next run", %{
      conversation: c,
      first: first
    } do
      {:ok, second} = Durable.submit(c, "later")
      assert second.status == "queued"
      assert [%{id: id}] = Durable.queued(c)
      assert id == second.id

      Durable.signal("go")
      await_settled(c, first.id)
      assert %{status: "done"} = await_settled(c, second.id)
      assert Enum.reject(texts(c, "assistant"), &(&1 == "")) == ["waited", "echo: later"]
    end

    test "a steer joins the run after the current tool round", %{conversation: c, first: first} do
      {:ok, steer} = Durable.submit(c, "also this", when_busy: "steer")

      Durable.signal("go")
      await_settled(c, first.id)
      assert Repo.get(Durable.Submission, steer.id).status == "done"
      assert entry_kinds(c) == ["user", "assistant", "tool_result", "user", "assistant"]
    end

    test "input that asked to be rejected is, while the conversation is busy", %{
      conversation: c
    } do
      assert Durable.submit(c, "now", when_busy: "reject") == {:error, :busy}
      assert Durable.queued(c) == []
    end

    test "abort stops the run and its tools", %{conversation: c, first: s} do
      Durable.abort(c)
      assert %{status: "unanswered", reason: "stopped"} = await_settled(c, s.id)
      assert "error" in entry_kinds(c)

      assert [%{data: %{"status" => "aborted"}}] =
               for(%{kind: "tool_result"} = e <- Durable.entries(c), do: e)

      refute Durable.busy?(c)
    end

    test "work waiting across a restart picks up where it stopped", %{
      conversation: c,
      first: s
    } do
      stop_supervised!(Photon.Durable.Scheduler)
      stop_supervised!(Photon.Durable.Store)
      start_supervised!(Photon.Durable.Store)
      start_supervised!(Photon.Durable.Scheduler)

      Durable.signal("go")
      assert %{status: "done"} = await_settled(c, s.id)
    end
  end

  describe "a tool that raises" do
    setup :conversation

    # The raise is logged with its stack trace.
    @tag :capture_log
    test "ends its call with an error, and its on_interrupt runs in the same commit", %{
      conversation: c
    } do
      {:ok, s} = Durable.submit(c, "raise")

      ended =
        await_change(c, &Enum.any?(&1.entries, fn e -> e.kind == "tool_result" end))

      assert [%{kind: "notice"}, %{kind: "tool_result", data: result}] = ended.entries
      assert result["status"] == "error"
      assert PhotonCore.Message.text_of(result["message"]) == "Error: boom"

      assert %{status: "done"} = await_settled(c, s.id)
      assert texts(c, "notice") == ["handed off"]
    end
  end

  describe "a step interrupted mid-run" do
    setup :conversation

    test "starts again on boot", %{conversation: c} do
      # A generation whose process died while running: the next scheduler finds it.
      stop_supervised!(Photon.Durable.Scheduler)

      Durable.commit(fn tx ->
        submission =
          Tx.insert_submission(tx, %{
            conversation_id: c,
            mode: "follow_up",
            content: %{"parts" => [PhotonCore.Message.text("again")]},
            status: "queued"
          })

        submission = Durable.place(tx, submission)

        task =
          Tx.create_task(tx, %{
            kind: "generation",
            conversation_id: c,
            phase: "request",
            checkpoint: %{"submissions" => [submission.id]}
          })

        Tx.update_task(tx, task, status: "running", runs: 1)
      end)

      start_supervised!(Photon.Durable.Scheduler)
      await_change(c, &Enum.any?(&1.entries, fn e -> e.kind == "assistant" end))
      assert texts(c, "assistant") == ["echo: again"]
    end
  end

  describe "commits" do
    setup :conversation

    test "a Tx write outside its commit raises, and writes nothing", %{conversation: c} do
      stale = Durable.commit(fn tx -> tx end)

      assert_raise ArgumentError, ~r/outside its commit/, fn ->
        Tx.append(stale, c, "user", %{"message" => PhotonCore.Message.user("x")})
      end

      assert Durable.entries(c) == []
    end

    test "reads don't need a commit", %{conversation: c} do
      refute Durable.busy?(c)
      assert Durable.queued(c) == []
    end

    test "a commit that raises stores nothing and raises in the caller", %{conversation: c} do
      assert_raise RuntimeError, "boom", fn ->
        Durable.commit(fn tx ->
          Tx.append(tx, c, "user", %{"message" => PhotonCore.Message.user("x")})
          raise "boom"
        end)
      end

      assert Durable.entries(c) == []
    end
  end

  describe "announcements" do
    setup :conversation

    test "reach a subscriber only once the commit is stored, in order", %{conversation: c} do
      Photon.Events.subscribe("test:announce")
      test = self()

      # What the test process had been sent by the time the commit's
      # function finished: the announcements aren't out yet.
      during =
        Durable.commit(fn tx ->
          :ok = Tx.announce(tx, "test:announce", {:first, c})
          _entry = Tx.append(tx, c, "user", %{"message" => PhotonCore.Message.user("x")})
          :ok = Tx.announce(tx, "test:announce", {:second, c})
          {:messages, messages} = Process.info(test, :messages)
          messages
        end)

      refute Enum.any?(during, &match?({:first, _}, &1))
      assert_receive {:first, ^c}
      assert_receive {:second, ^c}
      assert [%{kind: "user"}] = Durable.entries(c)
    end

    test "a commit that rolls back or raises announces nothing", %{conversation: c} do
      Photon.Events.subscribe("test:announce")

      assert {:rolled_back, :no} =
               Durable.commit(fn tx ->
                 :ok = Tx.announce(tx, "test:announce", :rolled_back)
                 Tx.rollback(:no)
               end)

      assert_raise RuntimeError, "boom", fn ->
        Durable.commit(fn tx ->
          :ok = Tx.announce(tx, "test:announce", :raised)
          raise "boom"
        end)
      end

      # A later commit's announcement arrives, and nothing before it did.
      Durable.commit(&Tx.announce(&1, "test:announce", {:later, c}))
      assert_receive {:later, ^c}
      refute_received :rolled_back
      refute_received :raised
    end

    test "can't be made outside a commit" do
      stale = Durable.commit(fn tx -> tx end)
      assert_raise ArgumentError, ~r/outside its commit/, fn -> Tx.announce(stale, "t", :x) end
    end
  end

  describe "busy conversations and last entries" do
    setup :conversation

    test "busy/1 and busy_in_profile/1 name the conversations with a run", %{conversation: c} do
      idle = Durable.create_conversation("test").id
      other = Durable.create_conversation("test_workdir").id
      Durable.subscribe(other)

      [s, _] =
        for id <- [c, other] do
          {:ok, submission} = Durable.submit(id, "wait")
          await_change(id, &Enum.any?(&1.tasks, fn t -> t.kind == "tool" end))
          submission
        end

      assert Durable.busy([c, idle, other]) == MapSet.new([c, other])
      assert Durable.busy([idle]) == MapSet.new()
      assert Durable.busy([]) == MapSet.new()
      assert Durable.busy_in_profile("test") == MapSet.new([c])
      assert Durable.busy_in_profile("test_workdir") == MapSet.new([other])
      assert Durable.busy_in_profile("assistant") == MapSet.new()

      Durable.abort(c)
      await_settled(c, s.id)
      assert Durable.busy([c, idle, other]) == MapSet.new([other])
    end

    test "last_entries/3 are the newest entries of a kind, newest first", %{conversation: c} do
      assert Durable.last_entries(c, "assistant", 5) == []

      {:ok, s} = Durable.submit(c, "wait")

      await_change(
        c,
        &Enum.any?(&1.tasks, fn t -> t.kind == "tool" and t.status == "waiting" end)
      )

      Durable.signal("go")
      await_settled(c, s.id)

      # The first answer asked for the tool; the newest one is the reply.
      assert [%Durable.Entry{kind: "assistant", data: data}] =
               Durable.last_entries(c, "assistant", 1)

      assert PhotonCore.Message.text_of(data["message"]) == "waited"
      assert [newest, first] = Durable.last_entries(c, "assistant", 5)
      assert newest.seq > first.seq
      assert PhotonCore.Message.tool_calls(first.data["message"]) != []
      assert Durable.last_entries(c, "error", 5) == []
    end
  end

  describe "abort_tx/3" do
    setup :conversation

    test "stops a conversation inside a commit, with the commit's other writes", %{
      conversation: c
    } do
      {:ok, first} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      {:ok, queued} = Durable.submit(c, "later")

      run =
        Durable.commit(fn tx ->
          _note = Tx.append(tx, c, "error", %{"message" => "stopping", "notice" => true})
          Durable.abort_tx(tx, c, [])
        end)

      assert %Durable.TaskRecord{kind: "generation", abort_requested: true} = run
      assert %{status: "unanswered", reason: "stopped"} = await_settled(c, first.id)
      assert Repo.get(Durable.Submission, queued.id).status == "withdrawn"
      assert "stopping" in texts(c, "error")
      refute Durable.busy?(c)
    end

    test "keeps what :withdraw leaves, and is :idle with no run", %{conversation: c} do
      {:ok, kept} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      {:ok, mine} = Durable.submit(c, "mine")

      {:ok, other} = Durable.submit(c, "other")

      Durable.commit(&Durable.abort_tx(&1, c, withdraw: fn s -> s.id == mine.id end))
      await_settled(c, kept.id)

      # The kept input starts the next run once the stopped one has ended.
      assert %{status: "done"} = await_settled(c, other.id)
      assert Repo.get(Durable.Submission, mine.id).status == "withdrawn"
      assert Durable.commit(&Durable.abort_tx(&1, c, [])) == :idle
    end
  end

  describe "Tx.count_tool_results_since/5" do
    setup :conversation

    test "counts flagged ok results of the named tools after the last user entry of the given kinds",
         %{conversation: c} do
      user = fn kind ->
        %{"message" => PhotonCore.Message.user("hi"), "source" => %{"kind" => kind}}
      end

      result = fn name, status, flag? ->
        details = if flag?, do: %{"counted" => true}, else: %{}
        %{"name" => name, "status" => status, "details" => details}
      end

      count = fn ->
        Durable.commit(&Tx.count_tool_results_since(&1, c, ~w(a b), ~w(user), "counted"))
      end

      # With no owner entry yet, it counts from the start.
      Durable.commit(fn tx ->
        _a = Tx.append(tx, c, "tool_result", result.("a", "ok", true))
        Tx.append(tx, c, "tool_result", result.("b", "ok", true))
      end)

      assert count.() == 2

      Durable.commit(fn tx ->
        _user = Tx.append(tx, c, "user", user.("user"))
        _a = Tx.append(tx, c, "tool_result", result.("a", "ok", true))
        _error = Tx.append(tx, c, "tool_result", result.("a", "error", true))
        _other = Tx.append(tx, c, "tool_result", result.("other", "ok", true))
        # A result without the flag isn't counted.
        _unflagged = Tx.append(tx, c, "tool_result", result.("a", "ok", false))
        _no_details = Tx.append(tx, c, "tool_result", %{"name" => "a", "status" => "ok"})
        # A message from anyone else doesn't start the count again.
        _signal = Tx.append(tx, c, "user", user.("signal"))
        Tx.append(tx, c, "tool_result", result.("b", "ok", true))
      end)

      assert count.() == 2

      _user = Durable.commit(&Tx.append(&1, c, "user", user.("user")))
      assert count.() == 0
    end
  end

  describe "recent_entries/2" do
    setup :conversation

    test "are the newest user, assistant and tool result entries, oldest first", %{
      conversation: c
    } do
      assert Durable.recent_entries(c, 5) == []

      {:ok, s} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      Durable.signal("go")
      await_settled(c, s.id)
      {:ok, failing} = Durable.submit(c, "fail")
      await_settled(c, failing.id)

      # The transcript: user, assistant (the call), tool_result, assistant,
      # user ("fail") and the error, which isn't part of the exchange.
      assert entry_kinds(c) == ~w(user assistant tool_result assistant user error)

      recent = Durable.recent_entries(c, 3)
      assert Enum.map(recent, & &1.kind) == ~w(tool_result assistant user)
      assert [%Durable.Entry{} | _] = recent
      assert Enum.map(recent, & &1.seq) == Enum.sort(Enum.map(recent, & &1.seq))
      assert length(Durable.recent_entries(c, 50)) == 5
    end
  end
end
