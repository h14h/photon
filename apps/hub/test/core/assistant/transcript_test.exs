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

      for status <- [:done, :error, :stopped] do
        assert %{verb: "Ran"} = Transcript.machine_action("shell", args, %{}, status)
      end

      image = %{"machine" => "mm1", "path" => "shot.png"}

      assert Transcript.machine_action("view_image", image, %{}, :pending) ==
               %{verb: "Looking at", subject: "shot.png", machine: "mm1"}

      assert %{verb: "Looked at"} = Transcript.machine_action("view_image", image, %{}, :done)
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
end
