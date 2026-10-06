defmodule Photon.ToolTaskWorkdirTest do
  @moduledoc """
  The working directory a profile names reaches its tool calls, through
  `Photon.Durable.ToolAPI`, in `execute/2`, `resume/2` and `on_interrupt/2`
  alike. `Photon.TestProfile.Workdir` names `"garden"`; `Photon.TestProfile`
  names none. The `where` tool reports what it got.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  defp start(profile, attrs \\ %{}) do
    c = Durable.create_conversation(profile, attrs).id
    Durable.subscribe(c)
    {:ok, s} = Durable.submit(c, "where")
    {c, s}
  end

  defp await_waiting(c),
    do:
      await_change(
        c,
        &Enum.any?(&1.tasks, fn t -> t.kind == "tool" and t.status == "waiting" end)
      )

  test "a profile's workdir reaches execute/2 and resume/2" do
    {c, s} = start("test_workdir")
    await_waiting(c)
    Durable.signal("go")

    assert %{status: "done"} = await_settled(c, s.id)
    assert texts(c, "tool_result") == [~s(execute: "garden", resume: "garden")]
  end

  test "and on_interrupt/2, when the call is stopped" do
    {c, s} = start("test_workdir")
    await_waiting(c)
    Durable.abort(c)

    assert %{status: "unanswered"} = await_settled(c, s.id)
    assert texts(c, "notice") == [~s(interrupted in "garden")]
  end

  test "a profile without workdir/1 gives nil, as the assistant's does" do
    refute Durable.implements?(Photon.Assistant, :workdir, 1)

    {c, s} = start("test")
    await_waiting(c)
    Durable.signal("go")

    assert %{status: "done"} = await_settled(c, s.id)
    assert texts(c, "tool_result") == ["execute: nil, resume: nil"]
  end

  # The raise is logged.
  @tag :capture_log
  test "a profile that can't name it fails the call, and on_interrupt/2 still runs" do
    {c, s} = start("test_workdir", title: "gone")

    assert %{status: "done"} = await_settled(c, s.id)
    assert [result] = for(%{kind: "tool_result"} = e <- Durable.entries(c), do: e.data)
    assert result["status"] == "error"

    assert PhotonCore.Message.text_of(result["message"]) ==
             "Error: this thread's project is gone"

    assert texts(c, "notice") == ["interrupted in nil"]
  end
end
