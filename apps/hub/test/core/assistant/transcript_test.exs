defmodule Photon.Assistant.TranscriptTest do
  @moduledoc "What the assistant page shows, from entries and live events."

  use Photon.Case, async: true

  describe "entries" do
    test "user, assistant, error and reset entries show; tool results show inside their call" do
      assert Transcript.shown?(user_entry("hi"))
      assert Transcript.shown?(entry("reset", %{"handoff" => nil}))
      refute Transcript.shown?(tool_result_entry("c1", "x"))
    end

    test "a conversation with only tool results is still empty" do
      assert Transcript.empty?([])
      assert Transcript.empty?([tool_result_entry("c1", "x")])
      refute Transcript.empty?([user_entry("hi")])
    end

    test "results are indexed by call, and calls by the entry that made them" do
      asked = assistant_entry("", [call("wait", %{}, "c1")], id: "e_1")
      result = tool_result_entry("c1", "went", id: "e_2", seq: 2)

      assert Transcript.index([asked, result]) == %{
               results: %{"c1" => result.data},
               calls: %{"c1" => asked},
               settled: %{}
             }

      assert Transcript.call_id(result) == "c1"
      assert Transcript.add_result(%{}, user_entry("hi")) == %{}
      assert Transcript.add_calls(%{}, user_entry("hi")) == %{}
    end

    test "a later entry for the same call wins" do
      first = tool_result_entry("c1", "one", id: "e_1")
      second = tool_result_entry("c1", "two", id: "e_2", seq: 2)

      assert %{results: %{"c1" => data}} = Transcript.index([first, second])
      assert data == second.data
    end
  end

  describe "the in-flight answer" do
    test "collects text, reasoning and the tools being prepared" do
      live =
        nil
        |> Transcript.live(%{"type" => "start"})
        |> Transcript.live(%{"type" => "reasoning", "delta" => "hm"})
        |> Transcript.live(%{"type" => "text", "delta" => "He"})
        |> Transcript.live(%{"type" => "text", "delta" => "llo"})
        |> Transcript.live(%{"type" => "tool_call", "index" => 0, "name" => "wait"})
        |> Transcript.live(%{"type" => "tool_call", "index" => 0, "name" => nil})
        |> Transcript.live(%{"type" => "tool_output", "text" => "ignored"})

      assert live == %{
               text: "Hello",
               reasoning: "hm",
               searches: [],
               tools: %{0 => "wait"},
               retry: nil
             }
    end

    test "lists web searches as they start, and fills in what each did, in place" do
      query = %{"type" => "search", "query" => "elixir release"}

      live =
        nil
        |> Transcript.live(%{"type" => "web_search", "id" => "ws_1", "action" => nil})
        |> Transcript.live(%{"type" => "web_search", "id" => "ws_2", "action" => nil})
        |> Transcript.live(%{"type" => "web_search", "id" => "ws_1", "action" => query})

      # Newest first.
      assert live.searches == [%{id: "ws_2", action: nil}, %{id: "ws_1", action: query}]
    end

    test "starts without a start event" do
      assert %{text: "x"} = Transcript.live(nil, %{"type" => "text", "delta" => "x"})
    end

    test "a retry clears it and says when the model is asked again; text clears the notice" do
      retry =
        Transcript.live(%{text: "He", reasoning: "", searches: [], tools: %{}, retry: nil}, %{
          "type" => "retry",
          "delay_ms" => 1500,
          "message" => "HTTP 503"
        })

      assert retry == %{
               text: "",
               reasoning: "",
               searches: [],
               tools: %{},
               retry: "The model didn't answer (HTTP 503). Trying again in 1.5s."
             }

      assert %{retry: nil, text: "a"} =
               Transcript.live(retry, %{"type" => "text", "delta" => "a"})
    end
  end

  describe "node work a call left running" do
    defp left_running(call_id, session_id, seq) do
      tool_result_entry(call_id, "still running",
        id: "e_#{seq}",
        seq: seq,
        details: %{"status" => "running", "session_id" => session_id}
      )
    end

    defp report(session_id, failed, seq) do
      entry(
        "user",
        %{
          "message" => PhotonCore.Message.user("[Report from box]"),
          "source" => %{"kind" => "node_report", "session_id" => session_id, "failed" => failed}
        },
        id: "e_#{seq}",
        seq: seq
      )
    end

    test "is settled by the next report for its session, the way the report says" do
      results = %{
        "c1" => left_running("c1", "ns_1", 1).data,
        "c2" => left_running("c2", "ns_2", 2).data,
        "c3" => tool_result_entry("c3", "finished", details: %{"session_id" => "ns_1"}).data
      }

      assert Transcript.settle(%{}, results, report("ns_1", false, 3)) ==
               {%{"c1" => :done}, ["c1"]}

      assert Transcript.settle(%{}, results, report("ns_2", true, 3)) ==
               {%{"c2" => :error}, ["c2"]}

      assert Transcript.settle(%{}, results, user_entry("hi")) == {%{}, []}
    end

    test "a follow-up to the same session waits for the next report" do
      first = left_running("c1", "ns_1", 1)
      follow_up = left_running("c2", "ns_1", 3)

      index = Transcript.index([first, report("ns_1", false, 2), follow_up])
      assert index.settled == %{"c1" => :done}

      results = Map.put(index.results, "c2", follow_up.data)

      assert {settled, ["c2"]} =
               Transcript.settle(index.settled, results, report("ns_1", true, 4))

      assert settled == %{"c1" => :done, "c2" => :error}
    end

    test "shows as running until settled, then as the report says" do
      result = left_running("c1", "ns_1", 1).data
      assert Transcript.action_status(result, result["details"]) == :running
      assert Transcript.action_status(result, result["details"], :done) == :done
      assert Transcript.action_status(result, result["details"], :error) == :error
    end
  end

  describe "a tool call's status" do
    test "follows its result and the node work's details" do
      assert Transcript.action_status(nil, %{}) == :pending
      assert Transcript.action_status(%{"status" => "ok"}, %{"status" => "running"}) == :running
      assert Transcript.action_status(%{"status" => "ok"}, %{"status" => "failed"}) == :error
      assert Transcript.action_status(%{"status" => "ok"}, %{}) == :done
      assert Transcript.action_status(%{"status" => "aborted"}, %{}) == :stopped
      assert Transcript.action_status(%{"status" => "interrupted"}, %{}) == :error
    end
  end

  describe "Blip's mood" do
    @quiet %{outcome: nil, live: nil, working: 0, busy: false}
    @live %{text: "", reasoning: "", tools: %{}, retry: nil}

    test "is idle when nothing is happening" do
      assert Transcript.mood(@quiet) == :idle
    end

    test "is thinking while an answer is in flight or a run is between steps" do
      assert Transcript.mood(%{@quiet | live: @live}) == :thinking
      assert Transcript.mood(%{@quiet | busy: true}) == :thinking
    end

    test "is working while node work it started runs, unless it's answering" do
      assert Transcript.mood(%{@quiet | working: 1}) == :working
      assert Transcript.mood(%{@quiet | working: 1, busy: true}) == :working
      assert Transcript.mood(%{@quiet | working: 1, live: @live}) == :thinking
    end

    test "shows an outcome it is holding over everything else" do
      busy = %{@quiet | live: @live, working: 2, busy: true}
      assert Transcript.mood(%{busy | outcome: :done}) == :done
      assert Transcript.mood(%{busy | outcome: :error}) == :error
    end
  end

  describe "the outcome of new entries" do
    defp report(failed) do
      entry("user", %{
        "message" => PhotonCore.Message.user("[Report from box]"),
        "source" => %{"kind" => "node_report", "node" => "box", "failed" => failed}
      })
    end

    test "a run that finishes is done" do
      assert Transcript.outcome([assistant_entry("Checked.")], true, false) == :done
      assert Transcript.outcome([assistant_entry("Checking.")], true, true) == nil
      assert Transcript.outcome([user_entry("hi")], false, true) == nil
    end

    test "a report is done if the node work went fine, an error if it failed" do
      assert Transcript.outcome([report(false)], false, true) == :done
      assert Transcript.outcome([report(true)], false, true) == :error
    end

    test "a failed run or tool call is an error, even as the run ends" do
      failed = entry("error", %{"message" => "HTTP 401"})
      assert Transcript.outcome([failed], true, false) == :error

      tool = tool_result_entry("c1", "x", details: %{"status" => "failed"})
      assert Transcript.outcome([tool], false, true) == :error
      assert Transcript.outcome([tool_result_entry("c1", "x")], false, true) == nil
    end

    test "a run the user stopped is nothing" do
      stopped = entry("error", %{"message" => "Stopped.", "stopped" => true})
      assert Transcript.outcome([stopped], true, false) == nil
    end
  end

  describe "web searches" do
    test "an answer's searches are the ones kept with its reasoning, in order" do
      search = %{"type" => "web_search_call", "id" => "ws_1", "action" => %{"type" => "search"}}

      message =
        Map.put(Message.assistant("hi"), "reasoning_items", [%{"type" => "reasoning"}, search])

      assert Transcript.searches(message) == [%{id: "ws_1", action: %{"type" => "search"}}]
      assert Transcript.searches(Message.assistant("hi")) == []
    end

    test "read as what was looked for, or the page that was read" do
      assert Transcript.search_label(%{"type" => "search", "query" => "elixir"}) ==
               "Searched the web for \u201celixir\u201d"

      assert Transcript.search_label(%{
               "type" => "open_page",
               "url" => "https://www.github.com/elixir-lang/elixir/?tab=readme"
             }) == "Read github.com/elixir-lang/elixir"

      assert Transcript.search_label(%{
               "type" => "find_in_page",
               "url" => "https://hexdocs.pm/elixir",
               "pattern" => "OTP"
             }) == "Looked in hexdocs.pm/elixir for \u201cOTP\u201d"

      long = "https://example.com/" <> String.duplicate("a", 80)
      # "Read " and the address, cut to 60 characters.
      assert String.length(Transcript.search_label(%{"type" => "open_page", "url" => long})) == 65

      assert Transcript.search_label(nil) == "Searching the web"
      assert Transcript.search_label(%{"type" => "search"}) == "Searched the web"
    end
  end
end
