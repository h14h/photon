defmodule PhotonCredo.Check.BoundedTaskConcurrencyTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.BoundedTaskConcurrency

  test "async_stream and a single task pass" do
    ~S"""
    defmodule App.Fetch do
      def all(urls), do: Task.async_stream(urls, &App.HTTP.get/1, timeout: :infinity)
      def one(url), do: url |> then(&Task.async(fn -> App.HTTP.get(&1) end)) |> Task.await()
    end
    """
    |> to_source_file()
    |> run_check(BoundedTaskConcurrency)
    |> refute_issues()
  end

  test "a task per element is reported" do
    ~S"""
    defmodule App.Fetch do
      def all(urls) do
        tasks = Enum.map(urls, fn url -> Task.async(fn -> App.HTTP.get(url) end) end)
        more = for url <- urls, do: Task.Supervisor.async_nolink(App.Sup, fn -> url end)
        piped = urls |> Enum.map(&Task.async(fn -> &1 end))
        {tasks, more, piped}
      end
    end
    """
    |> to_source_file()
    |> run_check(BoundedTaskConcurrency)
    |> assert_issues(fn issues -> assert length(issues) == 3 end)
  end
end
