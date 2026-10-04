defmodule PhotonCredo.Check.DynamicChildRestartTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.DynamicChildRestart

  @starter ~S"""
  defmodule App.Starter do
    def start(id), do: DynamicSupervisor.start_child(App.Sup, {App.Worker, id})

    def start_job(kind, id) do
      spec = if kind == :a, do: {App.JobA, id}, else: {App.JobB, id}
      DynamicSupervisor.start_child(App.Sup, spec)
    end
  end
  """

  test "children that choose a restart strategy pass" do
    [
      @starter,
      ~S"""
      defmodule App.Worker do
        use GenServer, restart: :transient
      end
      """,
      ~S"""
      defmodule App.JobA do
        use GenServer, restart: :temporary
      end
      """,
      ~S"""
      defmodule App.JobB do
        use GenServer
        def child_spec(arg), do: %{id: arg, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
      end
      """
    ]
    |> to_source_files()
    |> run_check(DynamicChildRestart)
    |> refute_issues()
  end

  test "a dynamic child without a restart strategy is reported, direct or computed" do
    [
      @starter,
      ~S"""
      defmodule App.Worker do
        use GenServer
      end
      """,
      ~S"""
      defmodule App.JobA do
        use GenServer
      end
      """,
      ~S"""
      defmodule App.JobB do
        use GenServer, restart: :temporary
      end
      """
    ]
    |> to_source_files()
    |> run_check(DynamicChildRestart)
    |> assert_issues(fn issues ->
      assert length(issues) == 2
      assert Enum.all?(issues, &(&1.message =~ ~r/App\.(Worker|JobA)/))
    end)
  end
end
