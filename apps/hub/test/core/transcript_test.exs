defmodule Photon.TranscriptTest do
  @moduledoc "What a conversation page shows, from entries and live events."

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
               results: %{"c1" => Map.put(result.data, "entry_id", "e_2")},
               calls: %{"c1" => asked}
             }

      assert Transcript.call_id(result) == "c1"
      assert Transcript.add_result(%{}, user_entry("hi")) == %{}
      assert Transcript.add_calls(%{}, user_entry("hi")) == %{}
    end

    test "a later entry for the same call wins" do
      first = tool_result_entry("c1", "one", id: "e_1")
      second = tool_result_entry("c1", "two", id: "e_2", seq: 2)

      assert %{results: %{"c1" => data}} = Transcript.index([first, second])
      assert data == Map.put(second.data, "entry_id", "e_2")
    end

    test "results keep no image data; image/2 gives it back from the entry" do
      png = Base.encode64("png bytes")

      shot =
        tool_result_entry("c1", [Message.image("image/png", png), Message.text("1x1")], id: "e_7")

      assert %{"c1" => data} = Transcript.add_result(%{}, shot)
      assert data["entry_id"] == "e_7"

      assert [%{"type" => "image", "mime" => "image/png"} = part] =
               Message.images(data["message"])

      refute Map.has_key?(part, "data")
      assert Message.text_of(data["message"]) == "1x1"

      assert Transcript.image(shot, 0) == {:ok, "image/png", "png bytes"}
      assert Transcript.image(shot, 1) == :error
      assert Transcript.image(user_entry("hi"), 0) == :error
    end

    test "image/2 serves only images of the types view_image returns, and valid data" do
      html = tool_result_entry("c1", [Message.image("text/html", Base.encode64("<script>"))])
      bad = tool_result_entry("c1", [Message.image("image/png", "not base64!")])

      assert Transcript.image(html, 0) == :error
      assert Transcript.image(bad, 0) == :error
    end
  end

  describe "what the user typed" do
    @page %{"kind" => "thread", "label" => "Garden / Fix the pump"}

    test "a message sent with a page shows only its last text part" do
      message = Message.user([Message.text("[Looking at the thread...]"), Message.text("why?")])

      assert Transcript.typed(message, %{"kind" => "user", "page" => @page}) == "why?"
      assert Transcript.typed(message["content"], %{"page" => @page}) == "why?"
    end

    test "a message sent without a page shows all of its text" do
      message = Message.user([Message.text("one"), Message.text("two")])

      assert Transcript.typed(message, %{"kind" => "user"}) == "one\n\ntwo"
      assert Transcript.typed(message, %{"kind" => "user", "page" => nil}) == "one\n\ntwo"
      assert Transcript.typed(message, nil) == "one\n\ntwo"
      assert Transcript.typed("plain", %{"page" => @page}) == "plain"
    end

    test "a thread's signal is nothing the owner typed" do
      message =
        Message.user([
          Message.text(~s{[Thread update] Garden / "Fix the pump" (c_1) finished.}),
          Message.text(~s{[Thread update] Garden / "Plant list" (c_2) failed.})
        ])

      assert Transcript.typed(message, %{"kind" => "signal", "signals" => []}) == ""
      assert Transcript.typed("[Question q_1 from ...]", %{"kind" => "signal"}) == ""
    end

    test "the owner's answer to a question shows what they wrote, without the note" do
      message =
        Message.user([
          Message.text(
            ~s{[Your answer to q_1 from Garden / "Gate" (c_1) went straight to the thread.]}
          ),
          Message.text("green, like the shed")
        ])

      source = %{"kind" => "answer", "question_id" => "q_1", "title" => "Gate"}
      assert Transcript.typed(message, source) == "green, like the shed"
      assert Transcript.typed(message["content"], source) == "green, like the shed"
    end

    test "images and other parts aren't text, and no text part reads as empty" do
      image = Message.image("image/png", "cG5n")

      assert Transcript.typed([Message.text("note"), Message.text("hi"), image], %{
               "page" => @page
             }) == "hi"

      assert Transcript.typed([image], %{"page" => @page}) == ""
      assert Transcript.typed([], %{"page" => @page}) == ""
    end
  end

  describe "nothing to tell" do
    test "is [nothing to tell], trimmed, in any case, with or without a period" do
      for text <- [
            "[nothing to tell]",
            "[Nothing to tell].",
            "  [NOTHING TO TELL]  \n",
            "\n[nothing to tell]."
          ] do
        assert Transcript.nothing_to_tell?(text), inspect(text)
      end
    end

    test "anything else, or what isn't text, is something to tell" do
      for text <- [
            "",
            "Nothing to tell.",
            "[nothing to tell]..",
            "[nothing to tell] about the pump",
            "The pump: [nothing to tell]",
            nil,
            42,
            %{"text" => "[nothing to tell]"}
          ] do
        refute Transcript.nothing_to_tell?(text), inspect(text)
      end
    end
  end

  describe "an untold answer" do
    test "is an answer of [nothing to tell] that makes no call" do
      assert Transcript.untold?(assistant_entry("[Nothing to tell]."))
      refute Transcript.untold?(assistant_entry("The pump is fixed."))
      refute Transcript.untold?(assistant_entry("[nothing to tell]", [call("wait", %{}, "c1")]))
      refute Transcript.untold?(user_entry("[nothing to tell]"))
      refute Transcript.untold?(%{})
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

  describe "a tool call's status" do
    test "follows its result" do
      assert Transcript.action_status(nil, %{}) == :pending
      assert Transcript.action_status(%{"status" => "ok"}, %{"status" => "failed"}) == :error
      assert Transcript.action_status(%{"status" => "ok"}, %{}) == :done
      assert Transcript.action_status(%{"status" => "aborted"}, %{}) == :stopped
      assert Transcript.action_status(%{"status" => "interrupted"}, %{}) == :error
    end

    test "a machine operation that failed is an error, and one that was canceled is stopped" do
      ok = %{"status" => "ok"}
      assert Transcript.action_status(ok, %{"kind" => "shell", "status" => "completed"}) == :done
      assert Transcript.action_status(ok, %{"kind" => "shell", "status" => "failed"}) == :error

      assert Transcript.action_status(ok, %{"kind" => "shell", "status" => "canceled"}) ==
               :stopped
    end
  end

  describe "a machine call's line" do
    test "is in the present while the call runs, and in the past once it ends" do
      args = %{"machine" => "mm1", "command" => "make test"}

      assert Transcript.machine_action("shell", args, %{}, :pending) ==
               %{verb: "Running", subject: "make test", machine: "mm1"}

      for status <- [:done, :error] do
        assert %{verb: "Ran"} = Transcript.machine_action("shell", args, %{}, status)
      end

      image = %{"machine" => "mm1", "path" => "shot.png"}

      assert Transcript.machine_action("view_image", image, %{}, :pending) ==
               %{verb: "Looking at", subject: "shot.png", machine: "mm1"}

      assert %{verb: "Looked at"} = Transcript.machine_action("view_image", image, %{}, :done)
    end

    test "says so when the user stopped the call" do
      args = %{"machine" => "mm1", "command" => "make test"}

      assert Transcript.machine_action("shell", args, %{}, :stopped) ==
               %{verb: "Stopped", subject: "make test", machine: "mm1"}

      image = %{"machine" => "mm1", "path" => "shot.png"}

      assert %{verb: "Stopped looking at"} =
               Transcript.machine_action("view_image", image, %{}, :stopped)
    end

    test "always names the machine, the hub's own included" do
      local = %{"machine" => "local", "command" => "uname -a"}
      assert %{machine: "local"} = Transcript.machine_action("shell", local, %{}, :done)

      # From the result when the arguments don't say.
      details = %{"machine" => "local", "kind" => "shell"}

      assert %{machine: "local"} =
               Transcript.machine_action("shell", %{"command" => "uname -a"}, details, :done)

      assert %{machine: nil} =
               Transcript.machine_action("shell", %{"machine" => ""}, %{}, :pending)
    end
  end

  describe "a running call's output" do
    defp output(call_id, text, stream \\ "out"),
      do: %{"type" => "tool_output", "call_id" => call_id, "stream" => stream, "text" => text}

    test "is kept per call, both streams in the order they came" do
      outputs =
        [output("c1", "one\n"), output("c2", "other\n"), output("c1", "oops\n", "err")]
        |> Enum.reduce(%{}, &Transcript.tool_output(&2, &1))

      assert outputs == %{"c1" => "one\noops\n", "c2" => "other\n"}
    end

    test "keeps only the last 8,000 characters of a call" do
      outputs = Transcript.tool_output(%{}, output("c1", String.duplicate("a", 7_990)))
      outputs = Transcript.tool_output(outputs, output("c1", "0123456789abcdefghij"))

      assert String.length(outputs["c1"]) == 8_000
      assert String.ends_with?(outputs["c1"], "0123456789abcdefghij")

      # Counted in characters, not bytes: one chunk far over the limit.
      outputs = Transcript.tool_output(%{}, output("c1", String.duplicate("é", 70_000) <> "end"))
      assert String.length(outputs["c1"]) == 8_000
      assert String.ends_with?(outputs["c1"], "éend")

      # Short multibyte text over 8,000 bytes is kept whole.
      outputs = Transcript.tool_output(%{}, output("c1", String.duplicate("é", 5_000)))
      assert String.length(outputs["c1"]) == 5_000
    end

    test "takes a tool's own output, which names no stream, and ignores other events" do
      plain = %{"type" => "tool_output", "call_id" => "c1", "text" => "progress"}
      assert Transcript.tool_output(%{}, plain) == %{"c1" => "progress"}

      for event <- [
            %{"type" => "text", "delta" => "hi"},
            %{"type" => "tool_output", "text" => "x"}
          ],
          do: assert(Transcript.tool_output(%{"c1" => "a"}, event) == %{"c1" => "a"})
    end

    test "goes once the call has its result, unless the user stopped the call" do
      outputs = %{"c1" => "tick 1\n", "c2" => "other"}

      assert Transcript.settle_output(outputs, "c1", %{"status" => "ok", "details" => %{}}) ==
               %{"c2" => "other"}

      assert Transcript.settle_output(outputs, "c1", %{"status" => "error"}) == %{"c2" => "other"}
      assert Transcript.settle_output(outputs, "c1", nil) == %{"c2" => "other"}

      stopped = [
        %{"status" => "aborted", "details" => %{}},
        %{"status" => "ok", "details" => %{"status" => "canceled"}}
      ]

      for result <- stopped,
          do: assert(Transcript.settle_output(outputs, "c1", result) == outputs)
    end
  end

  describe "Blip's mood" do
    @quiet %{outcome: nil, live: nil, busy: false}
    @live %{text: "", reasoning: "", tools: %{}, retry: nil}

    test "is idle when nothing is happening" do
      assert Transcript.mood(@quiet) == :idle
    end

    test "is thinking while an answer is in flight or a run is between steps" do
      assert Transcript.mood(%{@quiet | live: @live}) == :thinking
      assert Transcript.mood(%{@quiet | busy: true}) == :thinking
    end

    test "shows an outcome it is holding over everything else" do
      busy = %{@quiet | live: @live, busy: true}
      assert Transcript.mood(%{busy | outcome: :done}) == :done
      assert Transcript.mood(%{busy | outcome: :error}) == :error
    end
  end

  describe "the outcome of new entries" do
    test "a run that finishes is done" do
      assert Transcript.outcome([assistant_entry("Checked.")], true, false) == :done
      assert Transcript.outcome([assistant_entry("Checking.")], true, true) == nil
      assert Transcript.outcome([user_entry("hi")], false, true) == nil
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

  describe "questions put to the owner, in Blip's panel" do
    @place %{"thread_id" => "c_1", "title" => "Gate", "slug" => "garden", "project" => "Garden"}

    defp ask_owner_result(call_id, question_id, overrides \\ []) do
      details =
        Map.merge(@place, %{"question_id" => question_id, "wording" => "What colour?"})

      result =
        tool_result_entry(call_id, "Asked the user.",
          details: details,
          status: Keyword.get(overrides, :status, "ok")
        )

      put_in(result.data["name"], "ask_owner")
    end

    defp notice_entry(kind, question_id, extra \\ %{}) do
      entry(
        "error",
        @place
        |> Map.merge(%{
          "message" => "A notice.",
          "notice" => true,
          "question_id" => question_id,
          "question_notice" => kind
        })
        |> Map.merge(extra)
      )
    end

    defp answer_parts(id, text),
      do: [
        Message.text(
          "[Your answer to #{id} from Garden / \"Gate\" (c_1) went straight to the thread.]"
        ),
        Message.text(text)
      ]

    defp answer_source(id), do: Map.merge(@place, %{"kind" => "answer", "question_id" => id})

    defp answer_entry(id, text),
      do:
        entry("user", %{
          "message" => Message.user(answer_parts(id, text)),
          "source" => answer_source(id)
        })

    @open %{status: :open, answer: nil, title: "Gate", thread_id: "c_1"}

    test "an ok ask_owner result opens one; a refused one doesn't" do
      assert Transcript.questions([ask_owner_result("c1", "q_1")], []) == %{"q_1" => @open}
      assert Transcript.questions([ask_owner_result("c1", "q_1", status: "error")], []) == %{}

      assert Transcript.question_card(ask_owner_result("c1", "q_1").data) == "q_1"
      assert Transcript.question_card(ask_owner_result("c1", "q_1", status: "error").data) == nil
      assert Transcript.question_card(tool_result_entry("c1", "x").data) == nil
      assert Transcript.question_card(nil) == nil
    end

    test "the hub's escalation notice opens one; other notices don't" do
      escalated = notice_entry("escalated", "q_2", %{"question" => "Is it locked?"})

      assert Transcript.questions([escalated], []) == %{"q_2" => %{@open | title: "Gate"}}
      assert Transcript.escalation(escalated) == "q_2"
      assert Transcript.escalation(notice_entry("withdrawn", "q_2")) == nil

      assert Transcript.escalation(entry("error", %{"message" => "Skipped.", "notice" => true})) ==
               nil

      assert Transcript.questions(
               [entry("error", %{"message" => "Skipped.", "notice" => true})],
               []
             ) == %{}
    end

    test "the owner's answer, Blip's answer_question, a withdraw notice and a queued answer close it" do
      asked = ask_owner_result("c1", "q_1")

      assert Transcript.questions([asked, answer_entry("q_1", "green\nlike the shed")], []) ==
               %{"q_1" => %{@open | status: :answered, answer: "green\nlike the shed"}}

      answered =
        put_in(
          tool_result_entry("c2", "Sent your answer.",
            details: %{"question_id" => "q_1", "title" => "Gate", "answer" => "blue"}
          ).data["name"],
          "answer_question"
        )

      assert Transcript.questions([asked, answered], []) ==
               %{"q_1" => %{@open | status: :answered, answer: "blue"}}

      assert Transcript.questions([asked, notice_entry("withdrawn", "q_1")], []) ==
               %{"q_1" => %{@open | status: :withdrawn}}

      queued =
        submission(
          content: %{"parts" => answer_parts("q_1", "red"), "source" => answer_source("q_1")}
        )

      assert Transcript.questions([asked], [queued]) ==
               %{"q_1" => %{@open | status: :answered, answer: "red"}}

      # Other queued messages close nothing.
      assert Transcript.questions([asked], [submission()]) == %{"q_1" => @open}
    end

    test "answered and withdrawn are final, and a later fold builds on an earlier one" do
      known = Transcript.questions([ask_owner_result("c1", "q_1")], [])
      answered = Transcript.questions([answer_entry("q_1", "green")], [], known)
      assert answered["q_1"].status == :answered

      # The queued answer's entry, once placed, and a stray withdraw notice change nothing.
      assert Transcript.questions(
               [answer_entry("q_1", "green, again"), notice_entry("withdrawn", "q_1")],
               [],
               answered
             ) == answered

      # Nor does an open after the end.
      assert Transcript.questions([ask_owner_result("c3", "q_1")], [], answered) == answered
    end

    test "the question rows close what the conversation shows as open" do
      known =
        Transcript.questions(
          [
            ask_owner_result("c1", "q_1"),
            ask_owner_result("c2", "q_2"),
            answer_entry("q_3", "x")
          ],
          []
        )

      rows = [
        %{id: "q_1", status: "answered", answer: "staging", thread_title: "Gate"},
        %{id: "q_2", status: "with_owner", answer: nil, thread_title: "Gate"},
        %{id: "q_3", status: "withdrawn", answer: nil, thread_title: "Gate"},
        %{id: "q_4", status: "withdrawn", answer: nil, thread_title: "Shed", thread_id: "c_4"}
      ]

      assert Transcript.close_from_rows(known, rows) == %{
               "q_1" => %{@open | status: :answered, answer: "staging"},
               "q_2" => @open,
               # Answered stays answered, and a row's answer may be blank.
               "q_3" => known["q_3"],
               "q_4" => %{status: :withdrawn, answer: nil, title: "Shed", thread_id: "c_4"}
             }

      assert Transcript.close_from_rows(known, []) == known
    end
  end

  describe "the threads a conversation names" do
    @signal_source %{
      "kind" => "signal",
      "signals" => [
        %{"kind" => "thread_update", "thread_id" => "c_1", "title" => "fail: pump"},
        %{"kind" => "question", "thread_id" => "c_2", "title" => "ask blip: gate?"},
        %{"kind" => "thread_update", "thread_id" => "c_1", "title" => "fail: pump"}
      ]
    }

    test "signals, answers, tool results' details, notices and queued messages name them" do
      signal = entry("user", %{"message" => Message.user("x"), "source" => @signal_source})
      assert Transcript.thread_ids(signal) == ["c_1", "c_2"]

      answer =
        entry("user", %{
          "message" => Message.user("x"),
          "source" => %{"kind" => "answer", "thread_id" => "c_3"}
        })

      assert Transcript.thread_ids(answer) == ["c_3"]

      started = tool_result_entry("call_1", "Started.", details: %{"thread_id" => "c_4"})
      assert Transcript.thread_ids(started) == ["c_4"]

      notice = entry("error", %{"message" => "x", "notice" => true, "thread_id" => "c_5"})
      assert Transcript.thread_ids(notice) == ["c_5"]

      queued = submission(content: %{"parts" => [], "source" => @signal_source})
      assert Transcript.thread_ids(queued) == ["c_1", "c_2"]

      assert Transcript.thread_ids(user_entry("hi")) == []
      assert Transcript.thread_ids(tool_result_entry("call_2", "ok")) == []
      assert Transcript.thread_ids(submission()) == []
    end

    test "a digest's and a daily review's items name their threads, a file's writer too" do
      digest = %{
        "kind" => "digest",
        "items" => [
          %{"kind" => "finished", "new" => true, "thread_id" => "c_1"},
          %{"kind" => "file_written", "new" => false, "name" => "a.md", "writer" => "c_2"},
          %{"kind" => "file_written", "new" => false, "name" => "b.md", "writer" => "user"},
          %{"kind" => "project_created", "new" => false, "project_id" => "p_1"},
          %{"kind" => "resolved", "new" => false, "thread_id" => "c_1"},
          "junk"
        ]
      }

      source = %{"kind" => "signal", "signals" => [digest]}
      signal = entry("user", %{"message" => Message.user("[Digest] ..."), "source" => source})
      assert Transcript.thread_ids(signal) == ["c_1", "c_2"]

      queued = submission(content: %{"parts" => [], "source" => source})
      assert Transcript.thread_ids(queued) == ["c_1", "c_2"]

      review = %{
        "kind" => "review",
        "items" => [%{"thread_id" => "c_3", "state" => "quiet"}, %{"thread_id" => "c_4"}]
      }

      signal =
        entry("user", %{
          "message" => Message.user("[Daily review] ..."),
          "source" => %{"kind" => "signal", "signals" => [review]}
        })

      assert Transcript.thread_ids(signal) == ["c_3", "c_4"]

      bad = %{"kind" => "signal", "signals" => [%{"kind" => "digest", "items" => "x"}]}
      assert Transcript.thread_ids(entry("user", %{"source" => bad})) == []
    end

    test "a thread shows under its current title, else the one the entry recorded" do
      titles = %{"c_1" => "Fix the pump", "c_2" => nil}

      assert Transcript.title(titles, "c_1", "fix the pump please") == "Fix the pump"
      # Gone, or not read: what the entry recorded.
      assert Transcript.title(titles, "c_2", "Gate") == "Gate"
      assert Transcript.title(titles, "c_3", "Shed") == "Shed"
      assert Transcript.title(titles, nil, "Shed") == "Shed"
      assert Transcript.title(titles, "c_3", nil) == nil
    end

    test "a notice names its thread by the current title" do
      data = %{
        "message" => ~s("ask blip: gate?" was stopped, so its question was withdrawn.),
        "thread_id" => "c_1",
        "title" => "ask blip: gate?"
      }

      assert Transcript.notice_text(data, %{"c_1" => "Gate colour"}) ==
               ~s("Gate colour" was stopped, so its question was withdrawn.)

      assert Transcript.notice_text(data, %{}) == data["message"]
      assert Transcript.notice_text(%{"message" => "Skipped."}, %{"c_1" => "x"}) == "Skipped."
      assert Transcript.notice_text(%{}, %{}) == ""
    end
  end

  describe "a signal message's lines" do
    test "a line per signal, a question with its text and without its header" do
      update = %{
        "kind" => "thread_update",
        "key" => "settle:s_1",
        "status" => "failed",
        "title" => "Pump"
      }

      question = %{
        "kind" => "question",
        "key" => "question:q_1",
        "question_id" => "q_1",
        "title" => "Gate"
      }

      data = %{
        "message" =>
          Message.user([
            Message.text(~s{[Thread update] Garden / "Pump" (c_1) failed: unplugged}),
            Message.text(~s{[Question q_1 from Garden / "Gate" (c_2)]\nWhat colour?\nAny.})
          ]),
        "source" => %{"kind" => "signal", "signals" => [update, question]}
      }

      assert Transcript.signal_lines(data) == [
               %{ref: update, question: nil},
               %{ref: question, question: "What colour?\nAny."}
             ]
    end

    test "any other message has none, and a missing part reads as no question" do
      assert Transcript.signal_lines(%{
               "message" => Message.user("hi"),
               "source" => %{"kind" => "user"}
             }) == []

      assert Transcript.signal_lines(%{}) == []

      question = %{"kind" => "question", "question_id" => "q_1"}

      assert Transcript.signal_lines(%{
               "message" => Message.user([]),
               "source" => %{"kind" => "signal", "signals" => [question, "junk"]}
             }) == [%{ref: question, question: nil}]
    end
  end

  describe "a digest or a daily review in Blip's panel" do
    @digest %{
      "kind" => "digest",
      "key" => "digest:t_1:1",
      "items" => [
        %{
          "kind" => "finished",
          "new" => true,
          "thread_id" => "c_1",
          "title" => "fix the pump please",
          "project_id" => "p_1",
          "slug" => "garden",
          "project" => "Garden",
          "note" => "Replaced the fuse."
        },
        %{
          "kind" => "schedule_stopped",
          "new" => true,
          "schedule_id" => "sc_9",
          "project_id" => "p_1",
          "slug" => "garden",
          "project" => "Garden",
          "prompt" => "check\nthe gutters",
          "reason" => "the thread's project no longer exists"
        },
        %{"kind" => "schedule_stopped", "new" => true, "schedule_id" => "sc_8", "prompt" => "hi"},
        %{
          "kind" => "finished",
          "new" => false,
          "thread_id" => "c_2",
          "title" => "Order seeds",
          "slug" => "garden",
          "project" => "Garden"
        },
        %{
          "kind" => "file_written",
          "new" => false,
          "slug" => "garden",
          "project" => "Garden",
          "name" => "notes.md",
          "writer" => "c_1",
          "writer_title" => "fix the pump please",
          "deleted" => false
        },
        %{
          "kind" => "file_written",
          "new" => false,
          "slug" => "house",
          "project" => "House",
          "name" => "old.md",
          "writer" => "user",
          "deleted" => true
        },
        %{"kind" => "project_created", "new" => false, "slug" => "shed", "project" => "Shed"},
        %{"kind" => "purpose_changed", "new" => false, "slug" => "garden", "project" => "Garden"},
        %{
          "kind" => "thread_started",
          "new" => false,
          "thread_id" => "c_3",
          "title" => "Gutters",
          "slug" => "house",
          "project" => "House"
        },
        %{
          "kind" => "resolved",
          "new" => false,
          "thread_id" => "c_4",
          "title" => "Old pump",
          "project" => "Garden"
        }
      ],
      "more" => 4,
      "more_smaller" => 3
    }

    test "a digest's lines: where, what, and the link, each thread by its current title" do
      titles = %{"c_1" => "Fix the pump", "c_3" => nil}

      assert [
               finished,
               schedule,
               own_schedule,
               seen,
               written,
               deleted,
               created,
               edited,
               started,
               resolved
             ] = Transcript.ambient_lines(@digest, titles)

      assert finished == %{
               kind: "finished",
               new?: true,
               project: "Garden",
               lead: nil,
               subject: "Fix the pump",
               link: {:thread, "garden", "c_1"},
               words: "finished"
             }

      assert %{lead: "schedule", subject: ~s("check the gutters"), new?: true} = schedule
      assert schedule.link == {:schedule, "garden", "sc_9"}
      assert schedule.words == "stopped after an error"

      assert %{project: nil, lead: "Blip's schedule", subject: ~s("hi"), link: nil} =
               own_schedule

      assert %{subject: "Order seeds", new?: false, words: "finished; you've seen it"} = seen

      assert %{lead: "context file", subject: "notes.md", link: {:file, "garden", "notes.md"}} =
               written

      assert written.words == ~s(written by "Fix the pump")
      assert %{subject: "old.md", link: nil, words: "deleted by you"} = deleted

      assert %{project: nil, lead: "project", subject: "Shed", link: {:project, "shed"}} =
               created

      assert created.words == "started"
      assert %{subject: "Garden", words: "name or Purpose edited"} = edited
      # A thread that is gone, or not read, keeps the title the digest wrote.
      assert %{subject: "Gutters", words: "started", link: {:thread, "house", "c_3"}} = started
      # No slug, no link.
      assert %{subject: "Old pump", words: "resolved", link: nil} = resolved
    end

    test "a digest's heading, chip and the rest it carried" do
      assert Transcript.ambient_heading(@digest) == "Digest: 7 new, 10 smaller"
      assert Transcript.ambient_chip(@digest) == "Digest: 7 new changes"
      assert Transcript.ambient_more(@digest) == "And 7 more."

      one = %{"kind" => "digest", "items" => [%{"kind" => "finished", "new" => true}]}
      assert Transcript.ambient_heading(one) == "Digest: 1 new"
      assert Transcript.ambient_chip(one) == "Digest: 1 new change"
      assert Transcript.ambient_more(one) == nil

      smaller = %{"kind" => "digest", "items" => [%{"new" => false}], "more_smaller" => 1}
      assert Transcript.ambient_heading(smaller) == "Digest: 2 smaller"
      assert Transcript.ambient_chip(smaller) == "Digest: 2 smaller changes"

      assert Transcript.ambient_heading(%{"kind" => "digest"}) == "Digest"
      assert Transcript.ambient_chip(%{"kind" => "digest", "more" => "x"}) == "Digest"
    end

    test "a review's lines say how long each thread had sat when it was posted" do
      at = ~U[2026-10-07 09:00:00Z]

      review = %{
        "kind" => "review",
        "items" => [
          %{
            "thread_id" => "c_1",
            "title" => "Fix the pump",
            "slug" => "garden",
            "project" => "Garden",
            "state" => "quiet",
            "since" => "2026-10-03T08:00:00Z"
          },
          %{
            "thread_id" => "c_2",
            "title" => "Gutters",
            "slug" => "house",
            "project" => "House",
            "state" => "failed",
            "since" => "2026-10-07T04:00:00Z"
          },
          %{
            "thread_id" => "c_3",
            "title" => "Paint",
            "project" => "House",
            "state" => "waiting",
            "since" => "2026-10-07T08:59:30Z"
          }
        ],
        "more" => 2
      }

      assert [quiet, failed, waiting] =
               Transcript.ambient_lines(review, %{"c_1" => "Pump repair"}, at)

      assert quiet == %{
               kind: "quiet",
               new?: true,
               project: "Garden",
               lead: nil,
               subject: "Pump repair",
               link: {:thread, "garden", "c_1"},
               words: "stopped 4 days ago"
             }

      assert %{kind: "failed", words: "failed 5 hours ago"} = failed
      assert %{kind: "waiting", words: "waiting on you for 1 minute", link: nil} = waiting

      # Without the time, or with a bad one, just the state.
      assert ["stopped", "failed", "waiting on you"] ==
               Enum.map(Transcript.ambient_lines(review, %{}), & &1.words)

      bad = %{"kind" => "review", "items" => [%{"state" => "failed", "since" => "soon"}]}
      assert [%{words: "failed", subject: "A thread"}] = Transcript.ambient_lines(bad, %{}, at)

      assert Transcript.ambient_heading(review) == "Daily review: 5 threads"
      assert Transcript.ambient_chip(review) == "Daily review: 5 threads"
      assert Transcript.ambient_more(review) == "And 2 more."

      assert Transcript.ambient_heading(%{"kind" => "review", "items" => [%{}]}) ==
               "Daily review: 1 thread"
    end

    test "the ref a signal message carries, and garbage" do
      assert Transcript.ambient_ref(%{"kind" => "signal", "signals" => [@digest]}) == @digest

      for source <- [
            %{"kind" => "signal", "signals" => [%{"kind" => "thread_update"}]},
            %{"kind" => "user"},
            %{"kind" => "signal", "signals" => "x"},
            nil
          ],
          do: assert(Transcript.ambient_ref(source) == nil)

      for ref <- [
            %{"kind" => "thread_update", "items" => [%{}]},
            %{"kind" => "digest", "items" => "x"},
            %{"kind" => "digest"},
            nil
          ],
          do: assert(Transcript.ambient_lines(ref, %{}) == [])

      assert [%{subject: "A thread", words: "changed"}] =
               Transcript.ambient_lines(%{"kind" => "digest", "items" => [%{}, 1]}, %{})
    end
  end
end
