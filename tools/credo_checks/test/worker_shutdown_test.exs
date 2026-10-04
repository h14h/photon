defmodule PhotonCredo.Check.WorkerShutdownTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.WorkerShutdown

  test "timeouts, and infinity for supervisors, pass" do
    ~S"""
    defmodule App.Sup do
      def children do
        [
          %{id: App.Worker, start: {App.Worker, :start_link, []}, shutdown: 5_000},
          %{id: App.Child, start: {App.Child, :start_link, []}, type: :supervisor, shutdown: :infinity},
          Supervisor.child_spec({App.Other, []}, shutdown: :brutal_kill)
        ]
      end
    end
    """
    |> to_source_file()
    |> run_check(WorkerShutdown)
    |> refute_issues()
  end

  test "infinity for a worker is reported" do
    ~S"""
    defmodule App.Worker do
      use GenServer, shutdown: :infinity

      def spec, do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, shutdown: :infinity}
    end
    """
    |> to_source_file()
    |> run_check(WorkerShutdown)
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end
end
