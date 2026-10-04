defmodule Photon.Durable.ChangesTest do
  @moduledoc "What a stored commit announces."

  use Photon.Case, async: true

  alias Photon.Durable.Doc

  test "groups a commit's changes by conversation, each list in commit order" do
    e1 = user_entry("a", id: "e_1")
    e2 = assistant_entry("b", [], id: "e_2", seq: 2)
    other = user_entry("c", id: "e_3", conversation_id: "c_2")
    s = submission()
    t = task()

    summary =
      Changes.summarize([
        {:entry, e1},
        {:submission, s},
        {:entry, other},
        {:entry, e2},
        {:task, t}
      ])

    assert summary.scopes == %{
             "c_1" => %{entries: [e1, e2], docs: [], submissions: [s], tasks: [t]},
             "c_2" => %{entries: [other], docs: [], submissions: [], tasks: []}
           }
  end

  test "announces global docs under \"global\", and every task and signal on its own" do
    doc = %Doc{scope: "global", kind: "memory", data: %{"text" => ""}}
    t1 = task(id: "t_1")
    t2 = task(id: "t_2", conversation_id: nil)

    summary = Changes.summarize([{:doc, doc}, {:task, t1}, {:signal, "go"}, {:task, t2}])

    assert %{"global" => %{docs: [^doc]}, "c_1" => %{tasks: [^t1]}} = summary.scopes
    refute Map.has_key?(summary.scopes, nil)
    assert summary.tasks == [t1, t2]
    assert summary.signals == ["go"]
  end

  test "wakes the scheduler only when a task changed or a signal fired" do
    refute Changes.wakes_scheduler?(Changes.summarize([{:entry, user_entry("a")}]))
    assert Changes.wakes_scheduler?(Changes.summarize([{:signal, "go"}]))
    assert Changes.wakes_scheduler?(Changes.summarize([{:task, task()}]))
  end

  test "an empty commit announces nothing" do
    assert Changes.summarize([]) == %{scopes: %{}, tasks: [], signals: []}
  end
end
