defmodule Photon.Signals.RulesTest do
  @moduledoc "Which settles reach Blip, and how signals join a queued message."

  use Photon.Case, async: true

  alias Photon.Signals.Rules

  @blip %{"kind" => "blip"}
  @owner %{"kind" => "user"}
  @blip_schedule %{"kind" => "routine", "schedule_id" => "sc_1", "created_by" => "blip"}
  @owner_schedule %{"kind" => "routine", "schedule_id" => "sc_2", "created_by" => "owner"}
  @old_schedule %{"kind" => "routine", "schedule_id" => "sc_3"}

  @place %{
    thread_id: "c_123",
    title: "Fix the pump",
    project_id: "p_1",
    slug: "garden",
    project: "Garden"
  }

  defp update(outcome, sources, overrides \\ [], mode \\ :quiet) do
    %{outcome: outcome, asked?: false, ended?: true, sources: sources}
    |> Map.merge(Map.new(overrides))
    |> Rules.thread_update(mode)
  end

  defp ambient(outcome, sources, overrides \\ []),
    do: update(outcome, sources, overrides, :ambient)

  describe "thread_update/2 in quiet mode" do
    test "Blip's work: finished, asking and failed reach Blip; a stop doesn't" do
      for sources <- [[@blip], [@blip_schedule], [@owner, @blip]] do
        assert update("done", sources) == :finished
        assert update("done", sources, asked?: true) == :asking
        assert update("failed", sources) == :failed
        assert update("stopped", sources) == nil
      end
    end

    test "the owner's work: only asking (when the run ended) and failed reach Blip" do
      for sources <- [[@owner], [@owner_schedule], [@old_schedule], [nil], []] do
        assert update("done", sources) == nil
        assert update("done", sources, asked?: true) == :asking
        assert update("done", sources, asked?: true, ended?: false) == nil
        assert update("failed", sources) == :failed
        assert update("failed", sources, ended?: false) == :failed
        assert update("stopped", sources) == nil
      end
    end

    test "Blip's run that asks with more input queued reads as finished" do
      assert update("done", [@blip], asked?: true, ended?: false) == :finished
      assert update("done", [@blip], ended?: false) == :finished
    end

    test "is total over anything else" do
      assert Rules.thread_update(%{outcome: "done"}, :quiet) == nil
      assert Rules.thread_update(%{outcome: "failed", sources: "nope"}, :quiet) == :failed
      assert Rules.thread_update(%{outcome: 5, sources: [@blip]}, :quiet) == nil
      assert Rules.thread_update(nil, :quiet) == nil
      assert Rules.thread_update("garbage", :quiet) == nil
      assert Rules.thread_update(%{outcome: "failed", sources: []}, :loud) == nil
      assert Rules.thread_update(%{outcome: "done"}, :ambient) == nil
      assert Rules.thread_update(nil, :ambient) == nil
    end
  end

  describe "thread_update/2 in ambient mode" do
    test "the owner's run that finishes without asking is a digest item" do
      for sources <- [[@owner], [@owner_schedule], [@old_schedule], [nil], []] do
        assert ambient("done", sources) == :digest
      end
    end

    test "a run that goes on from the settle is nothing yet, so queued inputs make one item" do
      for sources <- [[@owner], [@owner_schedule], []] do
        assert ambient("done", sources, ended?: false) == nil
        assert ambient("done", sources, asked?: true, ended?: false) == nil
      end
    end

    test "every other cell is quiet mode's" do
      for sources <- [[@owner], [@owner_schedule], [@old_schedule], [nil], []] do
        assert ambient("done", sources, asked?: true) == :asking
        assert ambient("failed", sources) == :failed
        assert ambient("failed", sources, ended?: false) == :failed
        assert ambient("stopped", sources) == nil
        assert ambient("stopped", sources, ended?: false) == nil
      end

      for sources <- [[@blip], [@blip_schedule], [@owner, @blip]] do
        assert ambient("done", sources) == :finished
        assert ambient("done", sources, ended?: false) == :finished
        assert ambient("done", sources, asked?: true) == :asking
        assert ambient("failed", sources) == :failed
        assert ambient("stopped", sources) == nil
      end
    end
  end

  test "ambient_kind/1 names a digest or review message, and nothing else" do
    digest = %{"kind" => "signal", "signals" => [%{"kind" => "digest", "key" => "digest:t:0"}]}
    review = %{"kind" => "signal", "signals" => [%{"kind" => "review", "key" => "review:t:0"}]}
    update = %{"kind" => "signal", "signals" => [%{"kind" => "thread_update", "key" => "k"}]}

    assert Rules.ambient_kind(digest) == "digest"
    assert Rules.ambient_kind(review) == "review"
    assert Rules.ambient_kind(update) == nil
    assert Rules.ambient_kind(%{"kind" => "signal", "signals" => []}) == nil
    assert Rules.ambient_kind(%{"kind" => "user", "signals" => [%{"kind" => "digest"}]}) == nil
    assert Rules.ambient_kind(%{"kind" => "blip"}) == nil
    assert Rules.ambient_kind(nil) == nil
    assert Rules.ambient_kind("digest") == nil
  end

  test "blip_source?/1: Blip's messages and the schedules Blip made" do
    assert Rules.blip_source?(@blip)
    assert Rules.blip_source?(@blip_schedule)
    refute Rules.blip_source?(@owner_schedule)
    refute Rules.blip_source?(@old_schedule)
    refute Rules.blip_source?(@owner)
    refute Rules.blip_source?(%{"kind" => "signal"})
    refute Rules.blip_source?(nil)
    refute Rules.blip_source?("blip")
  end

  test "key/1 names the first settled submission, the task when none, or the question" do
    assert Rules.key({:settle, ["s_1", "s_2"], "t_1"}) == "settle:s_1"
    assert Rules.key({:settle, [], "t_1"}) == "settle:t_1:end"
    assert Rules.key({:question, "q_456"}) == "question:q_456"
  end

  test "update_ref/3 and question_ref/3 carry the thread and its project" do
    assert Rules.update_ref(:failed, "settle:s_1", @place) == %{
             "kind" => "thread_update",
             "key" => "settle:s_1",
             "status" => "failed",
             "thread_id" => "c_123",
             "title" => "Fix the pump",
             "project_id" => "p_1",
             "slug" => "garden",
             "project" => "Garden"
           }

    assert %{"kind" => "question", "question_id" => "q_456", "key" => "question:q_456"} =
             ref = Rules.question_ref("q_456", "question:q_456", @place)

    refute Map.has_key?(ref, "status")
  end

  describe "merging" do
    setup do
      update = Rules.update_ref(:finished, "settle:s_1", @place)
      other_update = Rules.update_ref(:failed, "settle:s_2", @place)
      question = Rules.question_ref("q_1", "question:q_1", @place)
      %{update: update, other_update: other_update, question: question}
    end

    defp carrier(refs), do: %{"kind" => "signal", "signals" => refs}

    test "merges?/2: a carrier takes refs of its own kind only", ctx do
      assert Rules.merges?(carrier([ctx.update]), ctx.other_update)
      refute Rules.merges?(carrier([ctx.update]), ctx.question)
      refute Rules.merges?(carrier([ctx.question]), ctx.update)
      assert Rules.merges?(carrier([ctx.question]), Rules.question_ref("q_2", "k", @place))
      refute Rules.merges?(carrier([ctx.update, ctx.question]), ctx.update)
      refute Rules.merges?(carrier([]), ctx.update)
      refute Rules.merges?(%{"kind" => "user"}, ctx.update)
      refute Rules.merges?(nil, ctx.update)
    end

    test "carries?/2 finds a key among a message's signals", ctx do
      assert Rules.carries?(carrier([ctx.update, ctx.other_update]), "settle:s_2")
      refute Rules.carries?(carrier([ctx.update]), "settle:s_2")
      refute Rules.carries?(%{"kind" => "routine"}, "settle:s_1")
      refute Rules.carries?(nil, "settle:s_1")
    end

    test "merge/3 adds a part and a ref at the end; without/2 takes one back", ctx do
      first = %{"type" => "text", "text" => "first"}
      second = %{"type" => "text", "text" => "second"}
      content = %{"parts" => [first], "source" => carrier([ctx.update])}

      merged = Rules.merge(content, second, ctx.other_update)
      assert merged["parts"] == [first, second]
      assert merged["source"] == carrier([ctx.update, ctx.other_update])

      assert Rules.without(merged, "settle:s_1") ==
               {:keep, %{"parts" => [second], "source" => carrier([ctx.other_update])}}

      assert Rules.without(content, "settle:s_1") == :withdraw
      assert Rules.without(content, "settle:s_9") == :absent
      assert Rules.without(%{}, "settle:s_1") == :absent
    end
  end
end
