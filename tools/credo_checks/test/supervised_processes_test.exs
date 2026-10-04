defmodule PhotonCredo.Check.SupervisedProcessesTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.SupervisedProcesses

  test "supervised processes pass" do
    ~S"""
    defmodule App.Jobs do
      def run(fun), do: Task.Supervisor.async_nolink(App.TaskSupervisor, fun)
      def start(id), do: DynamicSupervisor.start_child(App.Sup, {App.Worker, id})
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
    """
    |> to_source_file()
    |> run_check(SupervisedProcesses)
    |> refute_issues()
  end

  test "bare processes and agents are reported" do
    ~S"""
    defmodule App.Bare do
      use Agent

      def go(fun) do
        spawn(fun)
        spawn_link(fun)
        Task.start(fun)
        GenServer.start(App.Worker, [])
        Agent.start_link(fn -> %{} end)
      end
    end
    """
    |> to_source_file()
    |> run_check(SupervisedProcesses)
    |> assert_issues(fn issues -> assert length(issues) == 6 end)
  end

  test "an allow-listed module passes" do
    ~S"""
    defmodule App.Cache do
      def owner, do: spawn(fn -> :ok end)
    end
    """
    |> to_source_file()
    |> run_check(SupervisedProcesses, allowed: [{"App.Cache", "the table owner never exits"}])
    |> refute_issues()
  end
end
