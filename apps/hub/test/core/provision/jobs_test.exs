defmodule Photon.Provision.JobsTest do
  @moduledoc "The provisioning job table."

  use Photon.Case, async: true

  @opts %{machine: "box", host: "box.example.ts.net", node_id: "box", base_url: "http://h:1"}

  describe "a new job" do
    test "needs plain names for the host, SSH user and node" do
      assert Jobs.validate(@opts) == :ok
      assert Jobs.validate(Map.put(@opts, :ssh_user, "")) == :ok
      assert Jobs.validate(%{@opts | host: "box; rm -rf ~"}) == {:error, "invalid host"}
      assert Jobs.validate(Map.put(@opts, :ssh_user, "-oProxy")) == {:error, "invalid SSH user"}
      assert Jobs.validate(%{@opts | node_id: "a b"}) == {:error, "invalid node name"}
    end

    test "can't start while the machine has one running" do
      running = Jobs.new(:install, @opts, at())

      assert Jobs.idle(%{}, "box") == :ok
      assert Jobs.idle(%{"box" => running}, "box") == {:error, "already busy"}
      assert Jobs.idle(%{"box" => %{running | status: :ok}}, "box") == :ok
    end

    test "starts running with an empty log" do
      assert Jobs.new(:uninstall, @opts, at()) ==
               %{action: :uninstall, status: :running, log: [], node_id: "box", started_at: at()}
    end
  end

  describe "a running job" do
    setup do
      %{job: Jobs.new(:install, @opts, at())}
    end

    test "keeps the newest 300 log lines, newest first", %{job: job} do
      job = Enum.reduce(1..305, job, &Jobs.apply_event(&2, {:log, "line #{&1}"}))

      assert length(job.log) == 300
      assert hd(job.log) == "line 305"
    end

    test "ends with its last word", %{job: job} do
      assert %{status: :ok, log: ["done"]} = Jobs.apply_event(job, {:done, :ok, "done"})

      assert %{status: :error, log: ["Failed: x"]} =
               Jobs.apply_event(job, {:done, :error, "Failed: x"})
    end

    test "whose task dies without reporting fails, so the machine isn't stuck busy", %{
      job: job
    } do
      assert %{status: :error, log: [message]} = Jobs.task_down(job, :killed)
      assert message == "Failed: the job stopped unexpectedly (:killed)"

      finished = Jobs.apply_event(job, {:done, :ok, "done"})
      assert Jobs.task_down(finished, :killed) == finished
    end
  end
end
