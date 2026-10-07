defmodule Photon.Signals.TextTest do
  @moduledoc "What Blip reads of a signal, and the notices for the owner (sections 3.4, 4.5 to 4.7)."

  use Photon.Case, async: true

  alias Photon.Signals.Text

  @ref %{
    "thread_id" => "c_123",
    "title" => "Fix the pump",
    "project_id" => "p_1",
    "slug" => "garden",
    "project" => "Garden"
  }

  @question Map.put(@ref, "question_id", "q_456")

  defp status(status), do: Map.put(@ref, "status", status)

  describe "update/2" do
    test "finished, asking and failed" do
      assert Text.update(status("finished"), "The pump runs again.") ==
               ~s{[Thread update] Garden / "Fix the pump" (c_123) finished. It said: The pump runs again.}

      assert Text.update(status("asking"), "Which zone first?") ==
               ~s{[Thread update] Garden / "Fix the pump" (c_123) is waiting on the user: Which zone first?}

      assert Text.update(status("failed"), "HTTP 500: the pump is unplugged") ==
               ~s{[Thread update] Garden / "Fix the pump" (c_123) failed: HTTP 500: the pump is unplugged}
    end

    test "without a note or reason" do
      assert Text.update(status("finished"), nil) ==
               ~s{[Thread update] Garden / "Fix the pump" (c_123) finished.}

      assert Text.update(status("asking"), "  ") ==
               ~s{[Thread update] Garden / "Fix the pump" (c_123) is waiting on the user.}

      assert Text.update(status("failed"), nil) ==
               ~s{[Thread update] Garden / "Fix the pump" (c_123) failed.}
    end

    test "puts the detail on one line and cuts it to 600 characters" do
      assert Text.update(status("failed"), "line one\n\n  line two") =~
               "failed: line one line two"

      long = String.duplicate("word ", 200)
      "[Thread update] " <> _ = text = Text.update(status("finished"), long)
      [_, note] = String.split(text, "It said: ")
      assert String.length(note) == 600
      assert String.ends_with?(note, "...")
    end

    test "is total over missing fields" do
      assert Text.update(%{}, nil) == ~s{[Thread update]  / "" () changed.}
      assert is_binary(Text.update(nil, 5))
    end
  end

  describe "question/2" do
    test "a header line naming the question and the thread, then the question" do
      assert Text.question(@question, "Which deploy branch?") ==
               ~s{[Question q_456 from Garden / "Fix the pump" (c_123)]\nWhich deploy branch?}
    end

    test "cuts the question to 2,000 characters, keeping its lines" do
      text = Text.question(@question, "a\nb " <> String.duplicate("x", 3_000))
      [_header, question] = String.split(text, "\n", parts: 2)
      assert String.length(question) == 2_000
      assert String.starts_with?(question, "a\nb ")
      assert String.ends_with?(question, "...")
    end

    test "with no question, only the header" do
      assert Text.question(@question, nil) ==
               ~s{[Question q_456 from Garden / "Fix the pump" (c_123)]}
    end
  end

  test "answer_note/1 says the answer went straight to the thread" do
    assert Text.answer_note(@question) ==
             ~s{[Your answer to q_456 from Garden / "Fix the pump" (c_123) went straight to the thread.]}
  end

  test "the notices name the thread by title, with no question ID" do
    assert Text.escalated(@question) ==
             ~s{Here's "Fix the pump"'s question as the thread asked it. } <>
               "Your answer goes straight to it."

    assert Text.withdrawn(@question) ==
             ~s{"Fix the pump" was stopped, so its question was withdrawn.}

    refute Text.escalated(@question) =~ "q_"
    refute Text.withdrawn(@question) =~ "q_"
  end
end
