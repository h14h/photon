defmodule Photon.Assistant.MockAmbientTest do
  @moduledoc """
  The scripted Blip's replies to digests and daily reviews (section 8.1
  of the step 5 plan), on texts `Photon.Ambient.Text` writes, on their
  own and through `Photon.Assistant.MockScript`.
  """

  use Photon.Case, async: true

  alias Photon.Ambient.Text
  alias Photon.Assistant.{MockAmbient, MockCoordinator, MockScript, Notice}

  @now ~U[2026-10-07 15:00:00.000000Z]

  @doc_on %{"on_since" => "2026-10-01T08:00:00Z"}

  defp ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  defp system(memory), do: "You are Blip.\n\n## Memory\n\n#{memory}\n\n## Now\n\nIt's about noon."

  defp reply(text, memory \\ "(empty)"),
    do:
      MockScript.respond(%{
        system: system(memory),
        messages: [Message.user([Message.text(text)])]
      })

  defp row(kind, new?, fields) do
    Map.merge(
      %{
        kind: kind,
        new?: new?,
        at: ago(1),
        thread_id: nil,
        title: nil,
        project_id: "p_garden",
        slug: "garden",
        project: "Garden",
        note: nil,
        schedule_id: nil,
        prompt: nil,
        reason: nil,
        name: nil,
        writer: nil,
        writer_title: nil,
        deleted?: false
      },
      Map.new(fields)
    )
  end

  defp pump,
    do:
      row("finished", true,
        thread_id: "c_123",
        title: "Fix the pump",
        note: "Replaced the fuse and the pump runs again."
      )

  defp gutters,
    do:
      row("schedule_stopped", true,
        schedule_id: "sc_9",
        prompt: "check the gutters",
        reason: "the thread's project no longer exists."
      )

  defp seeds, do: row("finished", false, thread_id: "c_321", title: "Order seeds", note: "Done.")

  defp digest(new, smaller) do
    Text.digest(
      %{
        new: new,
        smaller: smaller,
        more_new: 0,
        more_smaller: 0,
        gone: [],
        snapshot: %{running: 1, waiting: 0, failed: 0}
      },
      @doc_on
    )
  end

  defp review_row({id, title, project}, state, hours, fields) do
    Map.merge(
      %{
        thread_id: id,
        title: title,
        project_id: "p_" <> String.downcase(project),
        slug: String.downcase(project),
        project: project,
        state: state,
        since: ago(hours),
        last_run_status: nil,
        detail: nil
      },
      Map.new(fields)
    )
  end

  defp review do
    Text.review(
      %{
        rows: [
          review_row({"c_123", "Fix the pump", "Garden"}, :quiet, 4 * 24 + 2,
            last_run_status: "stopped"
          ),
          review_row({"c_456", "Gutters", "House"}, :failed, 5 * 24,
            detail: "the ladder machine is offline."
          ),
          review_row({"c_789", "Paint", "House"}, :waiting, 3 * 24 + 5,
            detail: "Which white, Chalk or Linen?"
          )
        ],
        more: 1,
        quiet_after: 72 * 3600
      },
      %{"c_123" => "Draining the tank first."},
      @now
    )
  end

  describe "a digest" do
    test "the new lines become a list, and no tool is called" do
      text = digest([pump(), gutters()], [seeds()])
      message = reply(text)

      assert Message.tool_calls(message) == []

      assert Message.text_of(message) ==
               "- Fix the pump in Garden finished: Replaced the fuse and the pump runs again.\n" <>
                 ~s{- The schedule "check the gutters" in Garden stopped after an error.}

      # One block, so the bubble (its first block) shows every line.
      assert Notice.paragraph(Message.text_of(message)) == Message.text_of(message)
    end

    test "a finished thread with no note, and Blip's own schedule" do
      own = row("schedule_stopped", true, schedule_id: "sc_1", prompt: "water", project: nil)
      quiet = %{pump() | note: nil}

      assert Message.text_of(reply(digest([quiet, own], []))) ==
               "- Fix the pump in Garden finished.\n" <>
                 ~s{- Your schedule "water" stopped after an error.}
    end

    test "a line with a word to ignore is left out, ignoring case" do
      text = digest([pump(), gutters()], [])

      assert Message.text_of(reply(text, "- the NAS is mp1\n- ignore: PUMP")) ==
               ~s{The schedule "check the gutters" in Garden stopped after an error.}
    end

    test "with every line ignored, or only smaller ones, there is nothing to tell" do
      text = digest([pump(), gutters()], [])
      memory = "- ignore: pump\n- Ignore: gutters"

      assert Message.text_of(reply(text, memory)) == "[nothing to tell]"
      assert Message.text_of(reply(digest([], [seeds()]))) == "[nothing to tell]"
    end
  end

  describe "a daily review" do
    test "lists each thread with its ID, how long, and how to pick it up" do
      message = reply(review())

      assert Message.tool_calls(message) == []

      assert Message.text_of(message) == """
             These have sat for a while:
             - Fix the pump in Garden (c_123), stopped 4 days ago.
             - Gutters in House (c_456), failed 5 days ago.
             - Paint in House (c_789), waiting on you for 3 days.

             Say "tell <id>: ..." to pick one up, or press Resolve on it on Home to close it.\
             """
    end

    test "draws the list whole in the bubble, and the closing sentence as its own paragraph, not part of the last item" do
      html = review() |> reply() |> Message.text_of() |> Photon.Markdown.to_html()

      assert html =~ ~r{</ul>\s*<p>Say }
      assert Notice.paragraph(Message.text_of(reply(review()))) =~ "waiting on you for 3 days."
      refute html =~ ~r{days\.\s*Say }
    end

    test "leaves out the threads with a word to ignore, and with none left has nothing to tell" do
      assert Message.text_of(reply(review(), "- ignore: house")) == """
             These have sat for a while:
             - Fix the pump in Garden (c_123), stopped 4 days ago.

             Say "tell <id>: ..." to pick one up, or press Resolve on it on Home to close it.\
             """

      memory = "- ignore: house\n- ignore: tank"
      assert Message.text_of(reply(review(), memory)) == "[nothing to tell]"
    end
  end

  test "anything else is left to the other scripts, and the help names it" do
    assert MockAmbient.unasked([], %{}) == nil
    assert MockAmbient.unasked(["projects"], %{}) == nil
    assert MockAmbient.unasked([digest([pump()], []), "projects"], %{}) == nil

    assert %{} = MockAmbient.unasked([digest([pump()], [])], %{})
    assert MockCoordinator.unasked([review()], %{}) == MockAmbient.unasked([review()], %{})

    help = Message.text_of(reply("what can you do?"))
    assert help =~ MockAmbient.help()
    assert help =~ "`remember ignore: pump`"
  end
end
