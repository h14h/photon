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
    await_change(c, &Enum.any?(&1.tasks, fn t -> t.kind == "tool" and t.status == "waiting" end))
    %{first: first}
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

  describe "commits (H5)" do
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
end
