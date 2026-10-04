defmodule PhotonCredo.Check.NoSleepTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.NoSleep

  test "waiting on messages passes" do
    ~S"""
    defmodule App.WaitTest do
      test "it answers" do
        assert_receive :done, 1_000
      end
    end
    """
    |> to_source_file()
    |> run_check(NoSleep)
    |> refute_issues()
  end

  test "Process.sleep and :timer.sleep are reported" do
    ~S"""
    defmodule App.Poller do
      def wait do
        Process.sleep(100)
        :timer.sleep(100)
      end
    end
    """
    |> to_source_file()
    |> run_check(NoSleep)
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end

  test "an allow-listed module with a reason passes" do
    ~S"""
    defmodule App.Retry do
      def backoff(ms), do: Process.sleep(ms)
    end
    """
    |> to_source_file()
    |> run_check(NoSleep, allowed: [{"App.Retry", "runs in the caller's task"}])
    |> refute_issues()
  end
end
